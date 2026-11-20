import Darwin
import Foundation

/// Cheap path metadata for a read-only first frame, never an ownership claim.
public struct LeftoverPreview: Sendable {
    public let path: String
    public let place: String
    public let bytes: Int64?
}

public struct LeftoverScanLimits: Sendable {
    public var entries: Int
    public var seconds: TimeInterval
    public init(entries: Int = 100_000, seconds: TimeInterval = 15) {
        self.entries = max(0, entries)
        self.seconds = max(0, seconds)
    }
}

public struct LeftoverListing: Sendable {
    public let items: [Leftover]
    public let unreadable: [String]
    public let limited: Bool
    public let cancelled: Bool
    public var ownershipVerified: Bool = true
    /// A snapshot is not consent: the UI must obtain explicit manual approval.
    public var manualReview: ManualLeftoverReview?

    public init(items: [Leftover], unreadable: [String], limited: Bool, cancelled: Bool, ownershipVerified: Bool = true) {
        self.items = items
        self.unreadable = unreadable
        self.limited = limited
        self.cancelled = cancelled
        self.ownershipVerified = ownershipVerified
    }
}

/// One synchronous search, including shared directory metadata and a total
/// budget. Unknown or partial measurements never become complete candidates.
final class LeftoverScan {
    let progress: ScanProgress
    private let deadline: ContinuousClock.Instant
    private var remaining: Int
    private var directories: [String: [String]] = [:]
    private(set) var unreadable = Set<String>()
    private(set) var limited = false
    /// Measured folders holding what looks like the user's own work.
    private(set) var userWork = Set<String>()

    init(progress: ScanProgress, limits: LeftoverScanLimits = .init()) {
        self.progress = progress
        remaining = limits.entries
        deadline = .now.advanced(by: .seconds(limits.seconds))
    }

    var shouldStop: Bool {
        if progress.isCancelled { return true }
        if limited || ContinuousClock.now >= deadline { limited = true; return true }
        return false
    }

    func noteUnreadable(_ path: String) { unreadable.insert(path) }

    func names(_ path: String, within base: String, hidden: Bool = false) -> [String] {
        guard !shouldStop else { return [] }
        var st = stat()
        if lstat(path, &st) != 0 {
            if errno != ENOENT && errno != ENOTDIR { unreadable.insert(path) }
            return []
        }
        guard st.st_mode & S_IFMT == S_IFDIR, Trasher.noLinksBetween(base, and: path) else {
            unreadable.insert(path)
            return []
        }
        if let cached = directories[path] { return hidden ? cached : cached.filter { !$0.hasPrefix(".") } }
        var names: [String] = []
        let outcome = DirectoryReader.read(path, isCancelled: {
            if self.remaining == 0 { self.limited = true }
            return self.shouldStop
        }) { entry in
            remaining -= 1
            names.append(entry.name)
        }
        if outcome == .denied || outcome == .failed { unreadable.insert(path) }
        directories[path] = names
        return hidden ? names : names.filter { !$0.hasPrefix(".") }
    }

    func measure(_ path: String) -> Int64? {
        guard !shouldStop else { return nil }
        var st = stat()
        guard lstat(path, &st) == 0 else { unreadable.insert(path); return nil }
        if st.st_mode & S_IFMT == S_IFREG { return Int64(st.st_blocks) * 512 }
        guard st.st_mode & S_IFMT == S_IFDIR else { return nil }
        let parts = ContinuousClock.now.duration(to: deadline).components
        let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        guard seconds > 0 else { limited = true; return nil }
        let walker = ScanProgress()
        let relay = progress.onCancel { walker.cancel() }
        let timeout = DispatchWorkItem { walker.cancel() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: timeout)
        defer { timeout.cancel(); progress.removeCancellationObserver(relay) }
        let result = StorageScanner.scan(path: path, progress: walker, workers: 1)
        if result.cancelled {
            if !progress.isCancelled { limited = true }
            return nil
        }
        unreadable.formUnion(result.deniedPaths)
        guard result.deniedPaths.isEmpty, !result.root.unreadable else { unreadable.insert(path); return nil }
        if UserWork.isIn(result.root) { userWork.insert(path) }
        return result.root.size
    }
}

/// Signs that a folder holds the user's own work rather than what an app
/// keeps for itself: a filled Documents, Desktop or Projects folder (as in a
/// sandboxed app's container), a version-control repository, a document
/// package, or a large document. Read from the measured tree, without
/// another walk; smaller loose files aren't listed there.
enum UserWork {
    static let folders: Set<String> = ["documents", "desktop", "projects"]
    static let repositories: Set<String> = [".git", ".hg", ".svn"]
    static let packages: Set<String> = [
        "pages", "key", "numbers", "rtfd", "logicx", "band", "fcpbundle", "photoslibrary", "sketch",
        "xcodeproj", "xcworkspace", "playground", "scriv",
    ]
    static let documents: Set<String> = [
        "pdf", "doc", "docx", "pages", "key", "numbers", "xls", "xlsx", "ppt", "pptx", "rtf", "odt", "ods", "odp",
        "psd", "sketch", "epub",
    ]

    static func isIn(_ root: Folder) -> Bool {
        var stack = [root]
        while let folder = stack.popLast() {
            if folder.listedFiles.contains(where: { documents.contains(ending($0.name)) }) { return true }
            for sub in folder.subfolders {
                let name = sub.name.lowercased()
                if repositories.contains(name) || packages.contains(ending(name)) { return true }
                if folders.contains(name) && sub.size > 0 { return true }
                stack.append(sub)
            }
        }
        return false
    }

    private static func ending(_ name: String) -> String { (name as NSString).pathExtension.lowercased() }
}
