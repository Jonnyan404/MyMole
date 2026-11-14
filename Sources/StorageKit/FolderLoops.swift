import Darwin
import Foundation

/// A file server that follows links itself, as Samba does unless told not
/// to, shows a link to a folder above it as a real folder. The Mac makes up
/// a file number for it from its path, so nothing says it's a folder already
/// met: walked as it's shown, it holds itself without end, and its files are
/// counted again at every level. Such a folder has the times and the names
/// of the folder it leads to. A folder further down with all three times
/// equal to the nanosecond and the same names is that folder again.
///
/// Only disks reached over the network are checked: on a local disk a
/// folder's file number tells it apart, and links are never followed.
enum FolderLoops {
    struct Signature: Hashable, Sendable {
        let created: Int
        let createdNanoseconds: Int
        let modified: Int
        let modifiedNanoseconds: Int
        let changed: Int
        let changedNanoseconds: Int
        let count: Int
        let names: Int
    }

    /// Whether folders under `path` need the check.
    static func apply(to path: String) -> Bool {
        var fs = statfs()
        return statfs(path, &fs) == 0 && fs.f_flags & UInt32(MNT_LOCAL) == 0
    }

    /// The folder at `path` as `names` lists it; nil when it can't be read.
    static func signature(of path: String, names: [String]) -> Signature? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        var hasher = Hasher()
        for name in names.sorted() { hasher.combine(name) }
        return Signature(
            created: st.st_birthtimespec.tv_sec, createdNanoseconds: st.st_birthtimespec.tv_nsec,
            modified: st.st_mtimespec.tv_sec, modifiedNanoseconds: st.st_mtimespec.tv_nsec,
            changed: st.st_ctimespec.tv_sec, changedNanoseconds: st.st_ctimespec.tv_nsec,
            count: names.count, names: hasher.finalize())
    }

    /// The signatures of the folders read so far in one walk.
    final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var byFolder: [ObjectIdentifier: Signature] = [:]
        private var byPath: [String: Signature] = [:]
        private var loops: [String] = []

        /// The folders found to lead back to one above them (first 500).
        var found: [String] { lock.withLock { loops } }

        /// Records `folder`, and whether one of the folders holding it has
        /// its signature: the folder is then that one again.
        func isLoop(_ folder: Folder, path: String, names: [String]) -> Bool {
            guard let signature = FolderLoops.signature(of: path, names: names) else { return false }
            return lock.withLock {
                byFolder[ObjectIdentifier(folder)] = signature
                var above = folder.parent
                while let a = above {
                    if byFolder[ObjectIdentifier(a)] == signature { return note(path) }
                    above = a.parent
                }
                return false
            }
        }

        /// The same, for a walk that knows folders by path below `root`.
        func isLoop(_ path: String, below root: String, names: [String]) -> Bool {
            guard let signature = FolderLoops.signature(of: path, names: names) else { return false }
            return lock.withLock {
                byPath[path] = signature
                var above = path
                while above.count > root.count {
                    above = (above as NSString).deletingLastPathComponent
                    if byPath[above] == signature { return note(path) }
                }
                return false
            }
        }

        private func note(_ path: String) -> Bool {
            if loops.count < 500 { loops.append(path) }
            return true
        }
    }
}
