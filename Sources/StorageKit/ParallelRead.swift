import Darwin
import Foundation
import SynchronizationCompat

/// The rest of one large folder, read by several threads: the names in one
/// pass of `readdir`, then each entry's attributes with `getattrlistat`,
/// a share of the names per thread. In a folder of a quarter million
/// entries whose records aren't in memory this takes a third of the time a
/// single bulk read does, which waits on one record after another.
///
/// The threads are their own, not `concurrentPerform`'s: a scan's walkers
/// already fill that pool, and an apply nested inside one runs serially.
enum ParallelRead {
    struct Rest {
        let entries: [Entry]
        let outcome: ReadOutcome
    }

    /// Nil when stopped. Entries that went away since the names were read
    /// are left out, as a later bulk read would; any other failure makes the
    /// folder incomplete.
    static func rest(fd: Int32, skipping delivered: [String], readers: Int, isCancelled: () -> Bool) -> Rest? {
        guard let listed = names(fd, isCancelled: isCancelled) else { return nil }
        guard listed.complete else { return Rest(entries: [], outcome: .failed) }
        let seen = Set(delivered)
        let todo = listed.names.filter { !seen.contains($0.name) }
        let threads = max(1, min(readers, todo.count / 1_024 + 1))
        let shared = Shared(count: threads)
        let finished = DispatchSemaphore(value: 0)
        let chunk = (todo.count + threads - 1) / max(threads, 1)
        let qos = Thread.current.qualityOfService
        for t in 0..<threads {
            let part = Array(todo[min(t * chunk, todo.count)..<min((t + 1) * chunk, todo.count)])
            let thread = Thread {
                shared.set(t, read(fd: fd, part, stop: shared))
                finished.signal()
            }
            thread.qualityOfService = qos
            thread.start()
        }
        var waiting = threads
        while waiting > 0 {
            if finished.wait(timeout: .now() + .milliseconds(50)) == .success {
                waiting -= 1
            } else if isCancelled() {
                shared.stop()
            }
        }
        // The threads read `fd`; the caller closes it only after this returns.
        if shared.stopped || isCancelled() { return nil }
        let parts = shared.all
        let failed = parts.contains { $0.failed }
        return Rest(entries: parts.flatMap(\.entries), outcome: failed ? .failed : .ok)
    }

    struct Name: Sendable {
        let name: String
        let type: UInt8
    }

    /// Every name in the folder, from its start.
    static func names(_ fd: Int32, isCancelled: () -> Bool) -> (names: [Name], complete: Bool)? {
        let copy = dup(fd)
        guard copy >= 0 else { return ([], false) }
        guard let dir = fdopendir(copy) else {
            close(copy)
            return ([], false)
        }
        defer { closedir(dir) }
        rewinddir(dir)
        var names: [Name] = []
        while true {
            if names.count & 4_095 == 0, isCancelled() { return nil }
            errno = 0
            guard let ent = readdir(dir) else { return (names, errno == 0) }
            let name = withUnsafeBytes(of: ent.pointee.d_name) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            if name == "." || name == ".." { continue }
            names.append(Name(name: name, type: ent.pointee.d_type))
        }
    }

    struct Part: Sendable {
        var entries: [Entry] = []
        var failed = false
    }

    /// One thread's share: the same attributes the bulk read asks for, so
    /// each entry comes out as the bulk read would have made it.
    static func read(fd: Int32, _ names: [Name], stop: Shared) -> Part {
        let size = 2_048
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { buffer.deallocate() }
        let common = DirectoryReader.cmnReturned | DirectoryReader.cmnName | DirectoryReader.cmnDevID
            | DirectoryReader.cmnObjType | DirectoryReader.cmnModTime | DirectoryReader.cmnFileID
        var part = Part()
        part.entries.reserveCapacity(names.count)
        for (i, n) in names.enumerated() {
            if i & 255 == 0, stop.stopped { break }
            var type = n.type
            if type == UInt8(DT_UNKNOWN) {
                var st = stat()
                guard fstatat(fd, n.name, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
                    if errno != ENOENT { part.failed = true }
                    continue
                }
                type = st.st_mode & S_IFMT == S_IFDIR ? UInt8(DT_DIR) : UInt8(DT_REG)
            }
            // A folder's record holds the folder attributes and a file's the
            // file ones, as in a bulk read; asking one for the other's would
            // give it slots the parser doesn't expect.
            var list = attrlist()
            list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
            list.commonattr = common
            var options = UInt64(FSOPT_NOFOLLOW) | DirectoryReader.packInvalid
            if type == UInt8(DT_DIR) {
                list.dirattr = DirectoryReader.dirMountStatus
            } else {
                list.fileattr = DirectoryReader.fileLinkCount | DirectoryReader.fileAllocSize | DirectoryReader.fileDataLength
                list.forkattr = DirectoryReader.cmnExtFlags
                options |= DirectoryReader.commonExtended
            }
            var result = getattrlistat(fd, n.name, &list, buffer, size, UInt(options))
            if result != 0, errno == EINVAL || errno == ENOTSUP, list.forkattr != 0 {
                list.forkattr = 0
                result = getattrlistat(fd, n.name, &list, buffer, size, UInt(options & ~DirectoryReader.commonExtended))
            }
            guard result == 0 else {
                if errno != ENOENT { part.failed = true }
                continue
            }
            guard var e = DirectoryReader.parse(buffer + 4, flags: list.forkattr != 0, hasError: false) else {
                part.failed = true
                continue
            }
            // The type changed between the listing and the read: what's there now is read again.
            if (e.kind == .folder) != (type == UInt8(DT_DIR)) {
                part.entries += read(fd: fd, [Name(name: n.name, type: UInt8(DT_UNKNOWN))], stop: stop).entries
                continue
            }
            if e.sharing != nil { e.sharing = FileSpace.sharing(at: fd, e.name) }
            if e.needsBlocks, let blocks = DirectoryReader.blocks(at: fd, e.name) { e.allocated = blocks }
            part.entries.append(e)
        }
        return part
    }

    /// What the threads share: a stop, and each thread's result, written once by that thread.
    final class Shared: Sendable {
        private let halted = Atomic<Bool>(false)
        private let parts: Mutex<[Part]>
        init(count: Int) { parts = Mutex(Array(repeating: Part(), count: count)) }
        func stop() { halted.store(true, ordering: .relaxed) }
        var stopped: Bool { halted.load(ordering: .relaxed) }
        func set(_ i: Int, _ part: Part) { parts.withLock { $0[i] = part } }
        var all: [Part] { parts.withLock { $0 } }
    }
}
