import Darwin
import Foundation

/// The installer's records of what each package put on the Mac, read from
/// the files macOS keeps them in and never by running a tool. A record ties
/// to an app only through its own file list: the package installed exactly
/// that app bundle and no other. Its name, or when it was installed, is
/// never evidence.
public enum InstallerReceipts {
    public static let folder = "/private/var/db/receipts"

    public struct Receipt: Sendable, Equatable {
        public let id: String
        /// Where the package installed, relative to the volume ("Applications").
        public let location: String
        public let plist: String
        public let bom: String
    }

    /// Package records are named by a reverse-DNS ID; Apple's are the system's.
    public static func isUsableID(_ id: String) -> Bool {
        AppLeftovers.isWellFormed(id) && !id.lowercased().hasPrefix("com.apple.")
    }

    /// The record of `id` under `base`, when both its files are there as plain files.
    public static func receipt(_ id: String, base: String = "") -> Receipt? {
        guard isUsableID(id) else { return nil }
        let dir = base + folder
        let plist = dir + "/" + id + ".plist", bom = dir + "/" + id + ".bom"
        guard isPlainFile(plist), isPlainFile(bom), Trasher.noLinksBetween(base.isEmpty ? "/" : base, and: plist),
              let info = readPlist(plist) else { return nil }
        let raw = (info["InstallPrefixPath"] as? String) ?? (info["install-location"] as? String) ?? ""
        return Receipt(id: id, location: normalized(raw), plist: plist, bom: bom)
    }

    /// Every non-Apple record under `base`. Nil when the folder can't be read.
    public static func all(base: String = "") -> [Receipt]? {
        guard let names = DirectoryListing.names(base + folder) else { return nil }
        let ids = Set(names.filter { $0.hasSuffix(".plist") }.map { String($0.dropLast(6)) })
        return ids.sorted().compactMap { receipt($0, base: base) }
    }

    /// What a record installed, as absolute paths without the base. Nil when
    /// its file list can't be read whole.
    public static func installed(_ r: Receipt, limit: Int = 200_000) -> [String]? {
        guard let paths = BOM.paths(r.bom, limit: limit) else { return nil }
        let prefix = r.location.isEmpty ? "" : "/" + r.location
        return paths.compactMap { p in
            let rel = normalized(p)
            return rel.isEmpty ? nil : prefix + "/" + rel
        }
    }

    /// The app bundles a record installed: `.app` folders not inside another one.
    public static func apps(in paths: [String]) -> [String] {
        paths.filter { p in
            p.lowercased().hasSuffix(".app") && !p.dropLast(4).lowercased().contains(".app/")
        }
    }

    /// Whether the record installed `appPath` (absolute, without the base)
    /// and no other app.
    public static func installsOnly(_ r: Receipt, app appPath: String) -> Bool {
        guard let paths = installed(r) else { return false }
        let apps = apps(in: paths)
        return apps.count == 1 && apps[0].caseInsensitiveCompare(appPath) == .orderedSame
    }

    /// "Applications", "Library/Audio/Plug-Ins/HAL": no "./", no slashes at the ends.
    static func normalized(_ p: String) -> String {
        var s = p
        while s.hasPrefix("./") { s.removeFirst(2) }
        if s == "." { return "" }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func isPlainFile(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFREG
    }

    static func readPlist(_ path: String) -> [String: Any]? {
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size <= 1 << 20,
              let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}

/// The installer's bill of materials: a block store whose "Paths" tree
/// lists every file a package installed, each as a name and its parent.
enum BOM {
    /// Every path in the file list ("./App.app/Contents"), in list order.
    /// Nil when the file isn't a well-formed list or has more than `limit` entries.
    static func paths(_ path: String, limit: Int = 200_000) -> [String]? {
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size <= 256 << 20,
              let data = FileManager.default.contents(atPath: path) else { return nil }
        return paths(data: data, limit: limit)
    }

    static func paths(data: Data, limit: Int = 200_000) -> [String]? {
        let bytes = [UInt8](data)
        func u32(_ at: Int) -> Int? {
            guard at >= 0, at + 4 <= bytes.count else { return nil }
            return Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3])
        }
        func u16(_ at: Int) -> Int? {
            guard at >= 0, at + 2 <= bytes.count else { return nil }
            return Int(bytes[at]) << 8 | Int(bytes[at + 1])
        }
        guard bytes.count >= 32, Array(bytes[0..<8]) == Array("BOMStore".utf8),
              let indexOffset = u32(16), let varsOffset = u32(24), let blocks = u32(indexOffset), blocks <= 10_000_000
        else { return nil }
        func block(_ i: Int) -> (start: Int, length: Int)? {
            guard i >= 0, i < blocks, let start = u32(indexOffset + 4 + 8 * i), let length = u32(indexOffset + 8 + 8 * i),
                  start + length <= bytes.count else { return nil }
            return (start, length)
        }
        guard let varCount = u32(varsOffset), varCount <= 64 else { return nil }
        var at = varsOffset + 4
        var pathsBlock: Int?
        for _ in 0..<varCount {
            guard let index = u32(at), at + 4 < bytes.count else { return nil }
            let length = Int(bytes[at + 4])
            guard at + 5 + length <= bytes.count else { return nil }
            if String(decoding: bytes[(at + 5)..<(at + 5 + length)], as: UTF8.self) == "Paths" { pathsBlock = index }
            at += 5 + length
        }
        guard let treeIndex = pathsBlock, let tree = block(treeIndex), tree.length >= 20,
              Array(bytes[tree.start..<(tree.start + 4)]) == Array("tree".utf8), var node = u32(tree.start + 8)
        else { return nil }
        // Down the leftmost branch to the first leaf, then along the leaves.
        var depth = 0
        while true {
            guard let b = block(node), let isLeaf = u16(b.start), let count = u16(b.start + 2) else { return nil }
            if isLeaf != 0 { break }
            guard count > 0, depth < 64, let child = u32(b.start + 12) else { return nil }
            node = child
            depth += 1
        }
        var entries: [(id: Int, parent: Int, name: String)] = []
        var visited = Set<Int>()
        while node != 0 {
            guard visited.insert(node).inserted, let b = block(node), let count = u16(b.start + 2), let next = u32(b.start + 4),
                  b.length >= 12 + 8 * count else { return nil }
            for i in 0..<count {
                guard let infoIndex = u32(b.start + 12 + 8 * i), let fileIndex = u32(b.start + 16 + 8 * i),
                      let info = block(infoIndex), info.length >= 4, let id = u32(info.start),
                      let file = block(fileIndex), file.length > 4, let parent = u32(file.start) else { return nil }
                let nameBytes = bytes[(file.start + 4)..<(file.start + file.length)].prefix { $0 != 0 }
                let name = String(decoding: nameBytes, as: UTF8.self)
                guard !name.isEmpty, !name.contains("/") || name == "." else { return nil }
                entries.append((id, parent, name))
                guard entries.count <= limit else { return nil }
            }
            node = next
        }
        var byID: [Int: (parent: Int, name: String)] = [:]
        for e in entries { byID[e.id] = (e.parent, e.name) }
        var out: [String] = []
        out.reserveCapacity(entries.count)
        for e in entries {
            var parts = [e.name]
            var parent = e.parent
            var hops = 0
            while parent != 0 {
                guard let p = byID[parent], hops < 512 else { return nil }
                parts.append(p.name)
                parent = p.parent
                hops += 1
            }
            let joined = parts.reversed().joined(separator: "/")
            guard !joined.split(separator: "/").contains("..") else { return nil }
            out.append(joined)
        }
        return out
    }
}
