import CoreServices
import Foundation

/// The folders under a map's root that changed since a moment, as the
/// file system's own event history (FSEvents) records them. A map can then
/// read those again instead of the whole disk. When the history can't say
/// for sure, the answer is nil and the whole map is read again: events
/// dropped, the root itself changed, a disk mounted or unmounted inside,
/// event numbers that started over, or a disk that isn't this Mac's own.
public enum ChangedFolders {
    public typealias EventID = UInt64

    /// The moment, as the event history counts it.
    public static func now() -> EventID { FSEventsGetCurrentEventId() }

    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Collects the folders that change under a map's root from a moment
    /// on, for as long as the map is shown. `flush` hands over every event
    /// the system holds first, so a change made a moment ago is in it.
    public final class Watcher: @unchecked Sendable {
        public let root: String
        private let real: String
        private let lock = NSLock()
        private var paths = Set<String>()
        private var unsure = false
        private var stream: FSEventStreamRef?
        private let queue = DispatchQueue(label: "mymole.changed-folders.watch")

        /// Watching `root` from `since`; nil when the system won't watch it.
        public init?(root: String, since: EventID) {
            let base = root.hasSuffix("/") && root.count > 1 ? String(root.dropLast()) : root
            self.root = base
            real = ChangedFolders.realPath(base) ?? base
            var context = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
            context.info = Unmanaged.passUnretained(self).toOpaque()
            let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
                guard let info else { return }
                let w = Unmanaged<Watcher>.fromOpaque(info).takeUnretainedValue()
                let names = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
                w.take(names, (0..<count).map { Int(flags[$0]) })
            }
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
            guard since > 0, let s = FSEventStreamCreate(nil, callback, &context, [base] as CFArray, since, 0.5, flags) else { return nil }
            FSEventStreamSetDispatchQueue(s, queue)
            guard FSEventStreamStart(s) else {
                FSEventStreamInvalidate(s)
                FSEventStreamRelease(s)
                return nil
            }
            stream = s
        }

        deinit { stop() }

        public func stop() {
            lock.lock()
            let s = stream
            stream = nil
            lock.unlock()
            guard let s else { return }
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }

        private func take(_ names: [String], _ flags: [Int]) {
            let notSure = kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped
                | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount
            lock.lock()
            defer { lock.unlock() }
            for (i, f) in flags.enumerated() {
                if f & kFSEventStreamEventFlagHistoryDone != 0 { continue }
                if f & notSure != 0 { unsure = true }
                guard i < names.count else { continue }
                let raw = names[i]
                let p = raw.hasSuffix("/") && raw.count > 1 ? String(raw.dropLast()) : raw
                if p == real { paths.insert(root) } else if p.hasPrefix(real + "/") { paths.insert(root + p.dropFirst(real.count)) }
                else if p == root || p.hasPrefix(root + "/") { paths.insert(p) }
            }
        }

        /// The folders changed so far, outermost first; nil when the
        /// system can't say for sure, or stopped watching.
        public func flush() -> [String]? {
            lock.lock()
            let s = stream
            lock.unlock()
            guard let s else { return nil }
            FSEventStreamFlushSync(s)
            // The flushed events are delivered on the watcher's queue; this waits for them.
            queue.sync {}
            lock.lock()
            defer { lock.unlock() }
            return unsure ? nil : outermost(Array(paths))
        }
    }

    /// Each path once, and none inside another.
    public static func outermost(_ paths: [String]) -> [String] {
        var out: [String] = []
        for p in Set(paths).sorted() where !out.contains(where: { p == $0 || p.hasPrefix($0 + "/") }) {
            out.append(p)
        }
        return out
    }

    /// The folders of `map` to read again for `changed`: each changed
    /// folder if the map has it, or else the nearest folder above it that
    /// it has (a folder made or removed since changes its parent).
    public static func toRead(_ changed: [String], in map: Folder) -> [String] {
        let rootPath = map.path
        var out: [String] = []
        for var p in changed {
            while map.find(path: p) == nil, p != rootPath, p.hasPrefix(rootPath) {
                p = (p as NSString).deletingLastPathComponent
            }
            if map.find(path: p) != nil { out.append(p) }
        }
        return outermost(out)
    }
}
