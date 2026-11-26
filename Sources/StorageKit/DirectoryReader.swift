import Darwin
import Foundation

/// One directory entry with exactly the metadata the scanner needs.
struct Entry: Sendable {
    enum Kind: Sendable { case file, folder, symlink, other }
    let name: String
    let kind: Kind
    /// Bytes actually allocated on disk (not the logical length), so sparse
    /// and compressed files count what they really cost.
    var allocated: Int64
    /// The file's length, which Finder shows: more than `allocated` when
    /// the file is stored compressed, as App Store installs are.
    var length: Int64 = 0
    let linkCount: UInt32
    let fileID: UInt64
    let device: Int32
    let modified: TimeInterval
    /// How a file shares its blocks; nil where it shares none or the volume doesn't say.
    var sharing: FileSpace.Sharing? = nil
    /// Another volume is mounted on this folder. `getattrlistbulk` reports
    /// a mount point with the device of the folder holding it, so its
    /// device alone can't tell.
    var isMountPoint = false
    /// A file with content whose allocated size came back as 0, which the
    /// FAT driver reports for every file: its blocks are read on their own.
    var needsBlocks = false

    /// What removing this file alone frees.
    var reclaim: Reclaim { .file(allocated: allocated, device: device, sharing: sharing, inode: fileID, links: linkCount) }
}

enum ReadOutcome { case ok, denied, failed, cancelled }

/// Reads whole directories with `getattrlistbulk(2)`: one system call
/// returns a batch of entries with their attributes, instead of a `readdir`
/// plus a `stat` per entry. On file systems that don't support it, falls
/// back to `readdir` + `fstatat`.
enum DirectoryReader {
    // attr.h bit values, spelled out as UInt32 (the macros don't all import
    // with a usable type).
    static let cmnReturned: UInt32 = 0x8000_0000
    static let cmnName: UInt32 = 0x0000_0001
    static let cmnDevID: UInt32 = 0x0000_0002
    static let cmnObjType: UInt32 = 0x0000_0008
    static let cmnModTime: UInt32 = 0x0000_0400
    static let cmnFileID: UInt32 = 0x0200_0000
    private static let cmnError: UInt32 = 0x2000_0000
    static let dirMountStatus: UInt32 = 0x0000_0004
    private static let dirIsMountPoint: UInt32 = 0x0000_0001
    static let fileLinkCount: UInt32 = 0x0000_0001
    static let fileAllocSize: UInt32 = 0x0000_0004
    static let fileDataLength: UInt32 = 0x0000_0200
    /// FSOPT_PACK_INVAL_ATTRS: every requested attribute gets its slot even
    /// when invalid, so each record has a fixed layout to walk.
    static let packInvalid: UInt64 = 0x0000_0008
    /// FSOPT_ATTR_CMN_EXTENDED: `forkattr` asks for extended common
    /// attributes; the walk asks only for the flags that say a file may
    /// share blocks. Private size and clone count cost the kernel far more
    /// per file, so they are read only for the files flagged.
    static let commonExtended: UInt64 = 0x0000_0020
    static let cmnExtFlags = attrgroup_t(ATTR_CMNEXT_EXT_FLAGS)
    private static let bufferSize = 256 * 1024

    /// When a folder is worth reading with several threads: it has many
    /// entries left and the bulk read is slow per entry, as in a large folder
    /// whose records aren't in memory. A fast bulk read always stays: there,
    /// reading names first and then each entry costs more than it saves.
    struct Split: Sendable {
        /// Entries read in bulk before the rate is judged.
        var after = 4_096
        /// Bulk time per entry that makes a switch worth it.
        var slowerThan: TimeInterval = 5e-6
        /// Entries that must still be unread.
        var remaining = 16_384
        static let standard = Split()
    }

    /// `readers` above 1 lets a large, slow folder be read by that many
    /// threads (`Split`); the entries come to `body` on this thread either way.
    static func read(
        _ path: String, readers: Int = 1, split: Split = .standard, isCancelled: () -> Bool = { false },
        _ body: (Entry) -> Void
    ) -> ReadOutcome {
        guard !isCancelled() else { return .cancelled }
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return errno == EACCES || errno == EPERM ? .denied : .failed }
        defer { close(fd) }

        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = cmnReturned | cmnName | cmnDevID | cmnObjType | cmnModTime | cmnFileID | cmnError
        list.dirattr = dirMountStatus
        list.fileattr = fileLinkCount | fileAllocSize | fileDataLength
        list.forkattr = cmnExtFlags

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
        defer { buffer.deallocate() }

        var outcome = ReadOutcome.ok
        let started = readers > 1 ? Date() : nil
        var delivered: [String] = []
        while true {
            guard !isCancelled() else { return .cancelled }
            if let started, delivered.count >= split.after,
               Date().timeIntervalSince(started) > split.slowerThan * Double(delivered.count),
               let total = entryCount(fd), total - delivered.count >= split.remaining
            {
                let rest = ParallelRead.rest(fd: fd, skipping: delivered, readers: readers, isCancelled: isCancelled)
                guard let rest else { return .cancelled }
                for e in rest.entries { body(e) }
                return outcome == .ok ? rest.outcome : outcome
            }
            var count = getattrlistbulk(fd, &list, buffer, bufferSize, packInvalid | commonExtended)
            if count < 0, errno == EINVAL || errno == ENOTSUP, list.forkattr != 0 {
                // A file system that won't say how files share blocks is read without it.
                list.forkattr = 0
                count = getattrlistbulk(fd, &list, buffer, bufferSize, packInvalid)
            }
            if count < 0 {
                if errno == ENOTSUP || errno == EINVAL { return readFallback(fd: fd, isCancelled: isCancelled, body) }
                return errno == EACCES || errno == EPERM ? .denied : .failed
            }
            if count == 0 { return outcome }
            var record = buffer
            for _ in 0..<count {
                guard !isCancelled() else { return .cancelled }
                let length = Int(record.loadUnaligned(as: UInt32.self))
                if var e = parse(record + 4, flags: list.forkattr != 0) {
                    if e.sharing != nil { e.sharing = FileSpace.sharing(at: fd, e.name) }
                    if e.needsBlocks, let blocks = blocks(at: fd, e.name) { e.allocated = blocks }
                    if started != nil { delivered.append(e.name) }
                    body(e)
                } else {
                    // A record without a usable name can't be told apart in a later switch.
                    if started != nil { delivered.append("") }
                    outcome = .failed
                }
                record += length
            }
        }
    }

    /// Walks one record. With PACK_INVAL every requested attribute is present.
    /// Order: the returned-set, then the error code (getattrlistbulk(2) puts
    /// it right after the returned-set, not in bit order), then the rest in
    /// attr.h bit order: name, devid, objtype, modtime, fileid, then a
    /// folder's mount status or a file's attributes and extended flags.
    /// Neither kind gets slots for the other's attributes. A file flagged
    /// as maybe sharing blocks comes back with an empty `sharing`, to be read.
    /// `hasError`: the record has the error slot, which only the bulk read gives.
    static func parse(_ start: UnsafeMutableRawPointer, flags requested: Bool, hasError: Bool = true) -> Entry? {
        var p = start
        let returned = p.loadUnaligned(as: attribute_set_t.self)
        p += MemoryLayout<attribute_set_t>.size
        var error: UInt32 = 0
        if hasError {
            error = p.loadUnaligned(as: UInt32.self)
            p += 4
        }
        let required = cmnName | cmnDevID | cmnObjType | cmnModTime | cmnFileID
        guard error == 0, returned.commonattr & required == required else { return nil }

        let nameRef = p.loadUnaligned(as: attrreference_t.self)
        let name = String(cString: (p + Int(nameRef.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
        p += MemoryLayout<attrreference_t>.size
        let device = p.loadUnaligned(as: Int32.self)
        p += 4
        let objType = p.loadUnaligned(as: UInt32.self)
        p += 4
        let mod = p.loadUnaligned(as: timespec.self)
        p += MemoryLayout<timespec>.size
        let fileID = p.loadUnaligned(as: UInt64.self)
        p += 8
        if objType == 2 {
            let mounted = returned.dirattr & dirMountStatus != 0 && p.loadUnaligned(as: UInt32.self) & dirIsMountPoint != 0
            guard !name.isEmpty else { return nil }
            return Entry(
                name: name, kind: .folder, allocated: 0, linkCount: 1, fileID: fileID, device: device,
                modified: TimeInterval(mod.tv_sec) + TimeInterval(mod.tv_nsec) / 1e9, isMountPoint: mounted)
        }
        let links = p.loadUnaligned(as: UInt32.self)
        p += 4
        let alloc = p.loadUnaligned(as: Int64.self)
        p += 8
        let length = p.loadUnaligned(as: Int64.self)
        p += 8
        let flags = requested && returned.forkattr & cmnExtFlags != 0 ? p.loadUnaligned(as: UInt64.self) : 0
        let sharing = objType == 1 && flags & UInt64(EF_MAY_SHARE_BLOCKS) != 0 ? FileSpace.Sharing() : nil

        if name.isEmpty { return nil }
        let kind: Entry.Kind =
            switch objType {
            case 1: .file  // VREG
            case 2: .folder  // VDIR
            case 5: .symlink  // VLNK
            default: .other
            }
        let hasAlloc = returned.fileattr & fileAllocSize != 0
        let hasLength = returned.fileattr & fileDataLength != 0
        return Entry(
            name: name, kind: kind, allocated: hasAlloc ? alloc : 0, length: kind == .file && hasLength ? length : 0,
            linkCount: returned.fileattr & fileLinkCount != 0 ? links : 1,
            fileID: fileID, device: device,
            modified: TimeInterval(mod.tv_sec) + TimeInterval(mod.tv_nsec) / 1e9,
            sharing: sharing, needsBlocks: kind == .file && (!hasAlloc || alloc == 0) && (!hasLength || length > 0))
    }

    /// How many entries the open folder holds, without reading them.
    static func entryCount(_ fd: Int32) -> Int? {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.dirattr = attrgroup_t(ATTR_DIR_ENTRYCOUNT)
        var reply = (UInt32(0), UInt32(0))
        let ok = withUnsafeMutableBytes(of: &reply) { fgetattrlist(fd, &list, $0.baseAddress, $0.count, 0) == 0 }
        return ok ? Int(reply.1) : nil
    }

    /// What `name` in the open folder `dir` has allocated, as `stat` says.
    static func blocks(at dir: Int32, _ name: String) -> Int64? {
        var st = stat()
        guard fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
        return allocated(st)
    }

    /// What a file takes here: nothing for a cloud file that isn't downloaded.
    static func allocated(_ st: stat) -> Int64 {
        DuplicateFinder.holdsContent(st) ? Int64(st.st_blocks) * 512 : 0
    }

    static func readFallback(fd: Int32, isCancelled: () -> Bool = { false }, _ body: (Entry) -> Void) -> ReadOutcome {
        let dupFD = dup(fd)
        guard dupFD >= 0 else { return .failed }
        guard let dir = fdopendir(dupFD) else {
            close(dupFD)
            return .failed
        }
        defer { closedir(dir) }
        var outcome = ReadOutcome.ok
        while true {
            guard !isCancelled() else { return .cancelled }
            // readdir's nil means either EOF or an error; another system
            // call's errno mustn't turn a complete directory into a failure.
            errno = 0
            guard let ent = readdir(dir) else { return errno == 0 ? outcome : .failed }
            let name = withUnsafeBytes(of: ent.pointee.d_name) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            if name == "." || name == ".." { continue }
            var st = stat()
            guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
                outcome = .failed
                continue
            }
            let type = st.st_mode & S_IFMT
            let kind: Entry.Kind =
                type == S_IFREG ? .file : type == S_IFDIR ? .folder : type == S_IFLNK ? .symlink : .other
            body(
                Entry(
                    name: name, kind: kind, allocated: allocated(st), length: kind == .file ? Int64(st.st_size) : 0,
                    linkCount: UInt32(st.st_nlink), fileID: UInt64(st.st_ino), device: st.st_dev,
                    modified: TimeInterval(st.st_mtimespec.tv_sec)))
        }
    }

    /// Device of a path, to keep the walk on one volume.
    static func device(of path: String) -> Int32? {
        var st = stat()
        return lstat(path, &st) == 0 ? st.st_dev : nil
    }
}

/// A folder's names for the searches that list a few known folders.
public enum DirectoryListing {
    /// The names in `dir`; empty when it isn't there, which is normal for
    /// a folder that's only sometimes present, and nil when it is there
    /// but can't be read, so a search knows it didn't see everything.
    public static func names(_ dir: String) -> [String]? {
        if let names = try? FileManager.default.contentsOfDirectory(atPath: dir) { return names }
        var st = stat()
        return lstat(dir, &st) != 0 && errno == ENOENT ? [] : nil
    }
}
