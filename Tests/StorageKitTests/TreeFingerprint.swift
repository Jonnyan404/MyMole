import CryptoKit
import Darwin
import Foundation

/// Everything a move or a restore must keep of a tree, item by item, by
/// path relative to its root ("" for the root itself): kind, length, a
/// SHA-256 of the bytes, permissions, the modification time to the
/// nanosecond, the flags a user can set (hidden, locked), every extended
/// attribute's bytes (tags, resource fork, Finder info), where a link
/// points, which names are one file, when it was made, its access rules
/// (ACL), and Finder's Date Added. Folders' times change whenever what's in
/// them does, so they're left out; the root's Date Added changes whenever
/// it moves, so it's left out too.
struct TreeFingerprint: Equatable {
    struct Item: Equatable {
        var kind = ""
        var length: Int64 = 0
        var sha256 = ""
        var mode: UInt16 = 0
        var modified: Int64 = 0
        var flags: UInt32 = 0
        var xattrs: [String: String] = [:]
        var linkTarget: String?
        var names: UInt16 = 1
        var sameFileAs: String?
        var created: Int64 = 0
        var acl = ""
        var added: Int64 = 0
    }

    private(set) var items: [String: Item] = [:]

    /// Attributes macOS itself adds or updates when a file is used.
    static let systemAttributes: Set<String> = ["com.apple.provenance", "com.apple.macl", "com.apple.lastuseddate#PS", "com.apple.quarantine"]
    static let userFlags = UInt32(UF_HIDDEN | UF_IMMUTABLE | UF_APPEND | UF_NODUMP)

    init(_ root: String, excluding excluded: [String] = []) throws {
        var paths = [""]
        if let all = FileManager.default.enumerator(atPath: root), Self.kind(root) == "folder" {
            while let rel = all.nextObject() as? String { paths.append(rel) }
        }
        var firstName: [String: String] = [:]
        for rel in paths.sorted() where !excluded.contains(where: { rel == $0 || rel.hasPrefix($0 + "/") }) {
            let path = rel.isEmpty ? root : root + "/" + rel
            var st = stat()
            guard lstat(path, &st) == 0 else { throw POSIXError(.ENOENT) }
            var item = Item()
            item.kind = Self.kind(path)
            item.mode = UInt16(st.st_mode) & 0o7777
            item.flags = st.st_flags & Self.userFlags
            item.xattrs = try Self.attributes(path)
            item.created = Int64(st.st_birthtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_birthtimespec.tv_nsec)
            item.acl = Self.accessRules(path)
            item.added = rel.isEmpty ? 0 : Self.dateAdded(path)
            switch item.kind {
            case "file":
                item.length = Int64(st.st_size)
                item.sha256 = try Self.hash(path)
                item.modified = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
                item.names = UInt16(st.st_nlink)
                let key = "\(st.st_dev):\(st.st_ino)"
                if st.st_nlink > 1 {
                    if let first = firstName[key] { item.sameFileAs = first } else { firstName[key] = rel }
                }
            case "link":
                item.linkTarget = try FileManager.default.destinationOfSymbolicLink(atPath: path)
                item.modified = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
            default:
                break
            }
            items[rel] = item
        }
    }

    static func kind(_ path: String) -> String {
        var st = stat()
        guard lstat(path, &st) == 0 else { return "missing" }
        switch st.st_mode & S_IFMT {
        case S_IFREG: return "file"
        case S_IFDIR: return "folder"
        case S_IFLNK: return "link"
        default: return "other"
        }
    }

    /// The ACL as text, "" when there is none.
    static func accessRules(_ path: String) -> String {
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return "" }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard let text = acl_to_text(acl, nil) else { return "?" }
        defer { acl_free(text) }
        return String(cString: text)
    }

    /// Finder's Date Added in nanoseconds, read here independently of the app's own reader.
    static func dateAdded(_ path: String) -> Int64 {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_ADDEDTIME)
        var buffer = [UInt8](repeating: 0, count: 32)
        guard getattrlist(path, &list, &buffer, buffer.count, UInt32(FSOPT_NOFOLLOW)) == 0 else { return -1 }
        let ts = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: timespec.self) }
        return Int64(ts.tv_sec) * 1_000_000_000 + Int64(ts.tv_nsec)
    }

    static func hash(_ path: String) throws -> String {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var sha = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { sha.update(data: chunk) }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func attributes(_ path: String) throws -> [String: String] {
        let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return [:] }
        var names = [CChar](repeating: 0, count: size)
        guard listxattr(path, &names, size, XATTR_NOFOLLOW) == size else { throw POSIXError(.EIO) }
        var out: [String: String] = [:]
        for raw in names.split(separator: 0) {
            let name = String(decoding: raw.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard !systemAttributes.contains(name) else { continue }
            let n = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard n >= 0 else { throw POSIXError(.EIO) }
            var value = [UInt8](repeating: 0, count: n)
            guard getxattr(path, name, &value, n, 0, XATTR_NOFOLLOW) == n else { throw POSIXError(.EIO) }
            out[name] = SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined()
        }
        return out
    }

    /// The same items under `prefix` ("" for all), with paths relative to it.
    func under(_ prefix: String) -> [String: Item] {
        guard !prefix.isEmpty else { return items }
        var out: [String: Item] = [:]
        for (rel, item) in items where rel == prefix || rel.hasPrefix(prefix + "/") {
            var item = item
            // A name that's one file with another outside the part compared says only how many names it has.
            if let same = item.sameFileAs { item.sameFileAs = same.hasPrefix(prefix + "/") ? String(same.dropFirst(prefix.count + 1)) : nil }
            if rel == prefix { item.added = 0 }
            out[rel == prefix ? "" : String(rel.dropFirst(prefix.count + 1))] = item
        }
        return out
    }

    /// The items not under any of `prefixes`.
    func outside(_ prefixes: [String]) -> [String: Item] {
        items.filter { rel, _ in !prefixes.contains { rel == $0 || rel.hasPrefix($0 + "/") } }
    }

    /// What differs, path by path, for a failure message.
    static func differences(_ a: [String: Item], _ b: [String: Item]) -> [String] {
        var out: [String] = []
        for key in Set(a.keys).union(b.keys).sorted() where a[key] != b[key] {
            switch (a[key], b[key]) {
            case (nil, _): out.append("+ \(key)")
            case (_, nil): out.append("- \(key)")
            case let (x?, y?): out.append("~ \(key): \(x) → \(y)")
            }
        }
        return out
    }
}
