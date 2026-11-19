import Darwin
import Foundation

/// Identical copies made to share their storage: each chosen copy is
/// replaced, in one step, by an APFS clone of the copy that stays, with
/// the chosen copy's own name, place, dates, permissions, tags and other
/// metadata. Both still hold the same contents; they take the space of one
/// until either is changed, which gives the changed one blocks of its own.
/// The copy that was replaced goes to the Trash, so nothing is deleted
/// here; its space is free once the Trash is emptied.
public enum CloneSharing {
    /// Why a chosen copy can't share with the copy that stays.
    public enum Skip: Error, Sendable, Equatable {
        case otherDisk, noClones, alreadyShared, otherNames, locked, notYours, changed, noCopyStays
        case failed(String)

        public var text: String {
            switch self {
            case .otherDisk: String(localized: "On another disk than the copy that stays; clones share only on one disk.")
            case .noClones: String(localized: "Its disk can't make clones. Only APFS disks can.")
            case .alreadyShared: String(localized: "Already shares its storage with the copy that stays.")
            case .otherNames: String(localized: "The file has other names (hard links), which would no longer be the same file.")
            case .locked: String(localized: "Locked in Finder, or protected by macOS.")
            case .notYours: String(localized: "It belongs to another user.")
            case .changed: String(localized: "Changed since it was compared, so it isn't known to be the same any more.")
            case .noCopyStays: String(localized: "Every copy in its group is chosen, so none is left to share with.")
            case .failed(let why): why
            }
        }
    }

    public struct Share: Sendable, Equatable {
        /// The chosen copy, which becomes a clone.
        public let copy: String
        /// The copy that stays and is cloned.
        public let source: String
        /// What sharing frees once the replaced copy is gone from the Trash.
        public let bytes: Int64
    }

    public struct Plan: Sendable, Equatable {
        public var shares: [Share] = []
        public var skipped: [String: Skip] = [:]
        public var bytes: Int64 { shares.reduce(0) { $0 + $1.bytes } }
    }

    public struct Outcome: Sendable {
        /// Copies that now share their storage.
        public var shared: [String] = []
        /// The replaced copies, now in the Trash.
        public var trashed: [TrashRecord] = []
        /// A replaced copy that couldn't go to the Trash and stays beside the clone, by the clone's path.
        public var leftBeside: [String: String] = [:]
        public var skipped: [String: Skip] = [:]
        public var bytes: Int64 = 0
    }

    /// What sharing the chosen copies would do: for each group, the copy
    /// that stays first (the oldest not chosen) is the one cloned.
    public static func plan(_ groups: [DuplicateGroup], chosen: Set<String>,
                            supportsClones: (String) -> Bool = volumeClones) -> Plan {
        var plan = Plan()
        for g in groups {
            let picked = g.files.filter { chosen.contains($0.path) }
            guard !picked.isEmpty else { continue }
            guard let source = g.files.first(where: { !chosen.contains($0.path) }) else {
                for f in picked { plan.skipped[f.path] = .noCopyStays }
                continue
            }
            for f in picked {
                if let why = skip(f, source: source, supportsClones: supportsClones) {
                    plan.skipped[f.path] = why
                } else {
                    plan.shares.append(Share(copy: f.path, source: source.path, bytes: f.privateBytes ?? g.bytes))
                }
            }
        }
        return plan
    }

    static func skip(_ f: DuplicateFile, source: DuplicateFile, supportsClones: (String) -> Bool) -> Skip? {
        if f.device != 0, source.device != 0, f.device != source.device { return .otherDisk }
        if let a = f.cloneID, let b = source.cloneID, a == b, f.device == source.device { return .alreadyShared }
        if !supportsClones(f.path) { return .noClones }
        var st = stat()
        guard lstat(f.path, &st) == 0 else { return .changed }
        if st.st_nlink > 1 { return .otherNames }
        if st.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND) != 0 { return .locked }
        if st.st_uid != getuid() { return .notYours }
        return nil
    }

    public static func volumeClones(_ path: String) -> Bool {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeSupportsFileCloningKey]))?.volumeSupportsFileCloning == true
    }

    /// Shares each planned copy in turn. Before a copy is replaced it and
    /// the copy that stays are checked again: unchanged since they were
    /// compared, with no link on the way, and the same byte for byte; the
    /// clone is checked to hold the same bytes too. The swap is one step:
    /// at no moment is the copy's name missing or holding anything else.
    public static func share(
        _ plan: Plan, groups: [DuplicateGroup], home: String = Home.path, backend: TrashBackend = .system,
        protections: @escaping @Sendable () throws -> @Sendable (String) -> Bool = TrashGate.keepsNothing,
        stop: @escaping @Sendable () -> Bool = { false }
    ) -> Outcome {
        var out = Outcome()
        out.skipped = plan.skipped
        let byPath = Dictionary(groups.flatMap { g in g.files.map { ($0.path, ($0, g)) } }, uniquingKeysWith: { a, _ in a })
        for s in plan.shares {
            guard !stop() else { break }
            guard let (file, group) = byPath[s.copy], let (source, _) = byPath[s.source] else { out.skipped[s.copy] = .changed; continue }
            switch shareOne(file, with: source, of: group, home: home, backend: backend, protections: protections, stop: stop) {
            case .success(let r):
                out.shared.append(s.copy)
                out.bytes += s.bytes
                if let record = r.trashed { out.trashed.append(record) } else if let beside = r.beside { out.leftBeside[s.copy] = beside }
            case .failure(let why):
                out.skipped[s.copy] = why
            }
        }
        return out
    }

    struct Done {
        var trashed: TrashRecord?
        var beside: String?
    }


    static func shareOne(
        _ file: DuplicateFile, with source: DuplicateFile, of group: DuplicateGroup, home: String, backend: TrashBackend,
        protections: @escaping @Sendable () throws -> @Sendable (String) -> Bool, stop: @escaping @Sendable () -> Bool
    ) -> Result<Done, Skip> {
        func noLinks(_ p: String) -> Bool { !p.hasPrefix(home + "/") || Trasher.noLinksBetween(home, and: p) }
        func found(_ f: DuplicateFile) -> DuplicateFinder.Found {
            .init(path: f.path, length: group.length, bytes: group.bytes, modified: f.modified, inode: f.inode, device: f.device, version: f.version)
        }
        guard Trasher.isPlainPath(file.path), !Trasher.isProtected(file.path, home: home), noLinks(file.path), noLinks(source.path) else {
            return .failure(.failed(String(localized: "Its place has changed since it was found.")))
        }
        if let why = skip(file, source: source, supportsClones: volumeClones) { return .failure(why) }
        if (try? protections())?(file.path) ?? true { return .failure(.failed(String(localized: "Kept, or the keep lists couldn't be read."))) }
        guard DuplicateFinder.isUnchanged(file, length: group.length), DuplicateFinder.isUnchanged(source, length: group.length),
              FileSpace.withoutDownloading({ DuplicateFinder.identical(found(file), found(source), digest: group.digest, stop: stop) })
        else { return .failure(.changed) }

        let folder = file.folder, name = file.name
        guard let clone = freeName(in: folder, for: name, marker: String(localized: "shared")),
              let before = freeName(in: folder, for: name, marker: String(localized: "before sharing"))
        else { return .failure(.failed(String(localized: "No free name for the clone beside it."))) }
        guard clonefile(source.path, clone, UInt32(CLONE_NOFOLLOW)) == 0 else {
            return .failure(.failed(String(localized: "The clone couldn't be made: \(String(cString: strerror(errno))).")))
        }
        // From here, a clone that isn't used goes to the Trash; it takes no space of its own.
        func giveUp(_ why: Skip) -> Result<Done, Skip> {
            _ = Trasher.moveToTrash([clone], through: TrashGate(still: { $0 == clone }, protections: TrashGate.keepsNothing), backend: backend)
            return .failure(why)
        }
        guard takeMetadata(from: file.path, to: clone) else {
            return giveUp(.failed(String(localized: "The copy's dates, permissions and tags couldn't be given to the clone.")))
        }
        var cst = stat()
        guard lstat(clone, &cst) == 0,
              FileSpace.withoutDownloading({
                  DuplicateFinder.identical(found(file), .init(path: clone, length: group.length, bytes: group.bytes, modified: file.modified,
                                                               inode: UInt64(cst.st_ino), device: cst.st_dev), digest: group.digest, stop: stop)
              }),
              DuplicateFinder.isUnchanged(file, length: group.length)
        else { return giveUp(.changed) }
        // The swap: the copy's name now holds the clone, and the clone's the copy.
        let swapped = Trasher.swapNames(clone, file.path)
        guard swapped == 0 else {
            return giveUp(.failed(String(localized: "The copy couldn't be replaced: \(String(cString: strerror(swapped))).")))
        }
        // The replaced copy, under a name that says what it is, to the Trash.
        let old = Trasher.renameIfFree(clone, to: before) ? before : clone
        let inode = file.inode
        let outcome = Trasher.moveToTrash([old], through: TrashGate(still: { p in
            var st = stat()
            return p == old && lstat(p, &st) == 0 && UInt64(st.st_ino) == inode
        }, protections: TrashGate.keepsNothing), backend: backend)
        return .success(Done(trashed: outcome.moved.first, beside: outcome.moved.isEmpty ? old : nil))
    }

    /// "Report (shared).pdf", then "Report (shared 2).pdf": a name in the
    /// folder that nothing has.
    static func freeName(in folder: String, for name: String, marker: String) -> String? {
        let ext = (name as NSString).pathExtension, base = (name as NSString).deletingPathExtension
        for n in 1...50 {
            let label = n == 1 ? marker : "\(marker) \(n)"
            let candidate = folder + "/" + base + " (" + label + ")" + (ext.isEmpty ? "" : "." + ext)
            var st = stat()
            if lstat(candidate, &st) != 0, errno == ENOENT { return candidate }
        }
        return nil
    }

    /// The clone takes the copy's metadata and none of the source's:
    /// extended attributes (tags, comments, where it was downloaded from),
    /// access lists, permissions, flags, and the dates it was made and changed.
    static func takeMetadata(from copy: String, to clone: String) -> Bool {
        // The clone came with the source's attributes; they go first.
        let size = listxattr(clone, nil, 0, XATTR_NOFOLLOW)
        if size > 0 {
            var names = [CChar](repeating: 0, count: size)
            guard listxattr(clone, &names, size, XATTR_NOFOLLOW) == size else { return false }
            for name in names.split(separator: 0, omittingEmptySubsequences: true) {
                let n = String(decoding: name.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                guard removexattr(clone, n, XATTR_NOFOLLOW) == 0 else { return false }
            }
        }
        guard copyfile(copy, clone, nil, copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW)) == 0 else { return false }
        // copyfile keeps the clone's own creation date; the copy's goes on it.
        guard let made = (try? URL(fileURLWithPath: copy).resourceValues(forKeys: [.creationDateKey]))?.creationDate else { return false }
        var url = URL(fileURLWithPath: clone)
        var values = URLResourceValues()
        values.creationDate = made
        guard (try? url.setResourceValues(values)) != nil else { return false }
        var a = stat(), b = stat()
        return lstat(copy, &a) == 0 && lstat(clone, &b) == 0 && a.st_mode == b.st_mode && a.st_uid == b.st_uid
            && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
    }
}
