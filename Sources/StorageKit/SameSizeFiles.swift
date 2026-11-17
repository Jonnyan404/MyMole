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

    /// Files a test makes findable without waiting for Spotlight's index.
    static let indexedForTests = Mutex<Set<String>>([])

    /// Files sharing some of their blocks, not all, on the given volume of
    /// each length (`lengths`, length to devices), passing over the paths
    /// `skip` covers; at most `limit`.
    static func holders(lengths: [Int64: Set<Int32>], skip: (String) -> Bool, limit: Int) -> [CloneOverlaps.Holder] {
        guard !lengths.isEmpty, limit > 0 else { return [] }
        let paths = Set(spotlight(lengths: Set(lengths.keys)) + indexedForTests.withLock { Array($0) })
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
