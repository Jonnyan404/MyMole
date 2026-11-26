import CoreServices
import Darwin
import Foundation
import SynchronizationCompat

/// Clones no scan or search read that may still hold blocks of a whole
/// clone family. A clone rewritten in part keeps its length, and the
/// volume names it in no family, so its length is all that ties it to the
/// family: Spotlight's index of file sizes finds the files of that length.
/// A folder Spotlight leaves out, or a clone whose length changed, stays
/// unknown.
enum SameSizeFiles {
    /// Most lengths looked up at once; the largest copies go first.
    static let lengthLimit = 256
    /// Most files Spotlight returns for one lookup.
    static let resultLimit = 2_048

    /// Longest wait for Spotlight's answer. Its server can stall, as on a
    /// machine that is busy indexing; the lookup then finds nothing rather
    /// than holding up the search.
    static let answerLimit: Duration = .seconds(10)

    /// Files a test makes findable without waiting for Spotlight's index.
    static let indexedForTests = Mutex<Set<String>>([])

    /// Guarded test runs ask Spotlight nothing: its index names the Mac's
    /// own files, outside the tests' folders, and on a build machine its
    /// server may not answer at all. Tests name their files in
    /// `indexedForTests` instead.
    static let asksSpotlight = ProcessInfo.processInfo.environment["MYMOLE_GUARDED_TEST"] != "1"

    /// Files sharing some of their blocks, not all, on the given volume of
    /// each length (`lengths`, length to devices), passing over the paths
    /// `skip` covers; at most `limit`. `stop` ends the wait for Spotlight.
    static func holders(
        lengths: [Int64: Set<Int32>], skip: (String) -> Bool, limit: Int, stop: () -> Bool = { false }
    ) -> [CloneOverlaps.Holder] {
        guard !lengths.isEmpty, limit > 0 else { return [] }
        let found = asksSpotlight
            ? answer(within: answerLimit, stop: stop) { [lengths = Set(lengths.keys)] in spotlight(lengths: lengths) } : nil
        let paths = Set((found ?? []) + indexedForTests.withLock { Array($0) })
        var out: [CloneOverlaps.Holder] = []
        FileSpace.withoutDownloading {
            for path in paths.sorted() where !skip(path) {
                guard out.count < limit else { break }
                var st = stat()
                guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_nlink <= 1,
                      lengths[Int64(st.st_size)]?.contains(Int32(st.st_dev)) == true,
                      let sharing = FileSpace.sharing(path), let privateBytes = sharing.privateBytes,
                      !sharing.sharesAllBlocks else { continue }
                let allocated = Int64(st.st_blocks) * 512
                guard allocated - min(privateBytes, allocated) >= Reclaim.checkedCopy else { continue }
                out.append(.init(device: Int32(st.st_dev), path: path, privateBytes: privateBytes))
            }
        }
        return out
    }

    /// What `ask` answers within `limit`, or nil when it takes longer or
    /// `stop` turns true first. `ask` runs on a thread of its own, so a
    /// lookup that never returns holds no thread of the caller's; its late
    /// answer is dropped.
    static func answer<T: Sendable>(
        within limit: Duration, stop: () -> Bool = { false }, _ ask: @escaping @Sendable () -> T
    ) -> T? {
        let box = Answer<T>()
        Thread.detachNewThread { box.give(ask()) }
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline, !stop() {
            if let value = box.take() { return value }
        }
        return nil
    }

    private final class Answer<T: Sendable>: Sendable {
        private let value = Mutex<T?>(nil)
        private let ready = DispatchSemaphore(value: 0)

        func give(_ v: T) {
            value.withLock { $0 = v }
            ready.signal()
        }

        /// The answer, waiting a tenth of a second for it at most.
        func take() -> T? {
            guard ready.wait(timeout: .now() + .milliseconds(100)) == .success else { return nil }
            return value.withLock { $0 }
        }
    }

    /// Paths of the files Spotlight indexed with one of `lengths`.
    private static func spotlight(lengths: Set<Int64>) -> [String] {
        let text = lengths.sorted().map { "kMDItemFSSize == \($0)" }.joined(separator: " || ")
        guard let query = MDQueryCreate(kCFAllocatorDefault, text as CFString, nil, nil) else { return [] }
        MDQuerySetMaxCount(query, resultLimit)
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
        var out: [String] = []
        for i in 0..<MDQueryGetResultCount(query) {
            guard let raw = MDQueryGetResultAtIndex(query, i) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            if let path = MDItemCopyAttribute(item, kMDItemPath) as? String { out.append(path) }
        }
        return out
    }
}
