import Foundation

/// Files in iCloud Drive that are downloaded to this Mac. Removing a
/// download keeps the file in iCloud Drive and in Finder, with a cloud
/// icon; opening it downloads it again. Nothing goes to the Trash, and a
/// file that isn't uploaded yet is never offered.
public enum CloudDownloads {
    public struct Item: Sendable, Equatable, Identifiable {
        public let path: String
        public let bytes: Int64
        public let lastOpened: Date?
        /// Uploaded in full, so the copy in iCloud is the same as this one.
        public let uploaded: Bool
        public var id: String { path }
        public var name: String { (path as NSString).lastPathComponent }
    }

    /// Where iCloud Drive keeps its files: the Drive itself and each app's folder.
    public static func root(home: String = Home.path) -> String { home + "/Library/Mobile Documents" }

    public static let keys: Set<URLResourceKey> = [
        .isRegularFileKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsUploadedKey,
        .ubiquitousItemIsUploadingKey, .totalFileAllocatedSizeKey, .contentAccessDateKey,
    ]

    /// The downloaded files of at least `minimum` bytes, largest first.
    public static func list(root: String = root(), minimum: Int64 = 1 << 20, progress: ScanProgress = ScanProgress()) -> [Item] {
        guard let walk = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: Array(keys),
                                                       options: [.skipsPackageDescendants]) else { return [] }
        var out: [Item] = []
        for case let url as URL in walk {
            if progress.isCancelled { break }
            guard let v = try? url.resourceValues(forKeys: keys), v.isRegularFile == true, let item = item(url.path, State(v), minimum: minimum) else { continue }
            out.append(item)
        }
        return out.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path }
    }

    /// What iCloud says of a file, in plain fields.
    public struct State: Sendable, Equatable {
        public var inCloud: Bool
        public var downloaded: Bool
        public var uploaded: Bool
        public var bytes: Int64?
        public var lastOpened: Date?

        public init(inCloud: Bool, downloaded: Bool, uploaded: Bool, bytes: Int64?, lastOpened: Date? = nil) {
            (self.inCloud, self.downloaded, self.uploaded, self.bytes, self.lastOpened) = (inCloud, downloaded, uploaded, bytes, lastOpened)
        }

        public init(_ v: URLResourceValues) {
            self.init(inCloud: v.isUbiquitousItem == true, downloaded: v.ubiquitousItemDownloadingStatus == .current,
                      uploaded: v.ubiquitousItemIsUploaded == true && v.ubiquitousItemIsUploading != true,
                      bytes: v.totalFileAllocatedSize.map(Int64.init), lastOpened: v.contentAccessDate)
        }
    }

    static func item(_ path: String, _ s: State, minimum: Int64) -> Item? {
        guard s.inCloud, s.downloaded, let bytes = s.bytes, bytes >= minimum else { return nil }
        return Item(path: path, bytes: bytes, lastOpened: s.lastOpened, uploaded: s.uploaded)
    }

    /// Removes the chosen downloads, each checked again first: still in
    /// iCloud Drive, downloaded and uploaded. `evict` is iCloud's own way
    /// of doing it; tests pass one of their own.
    public static func remove(
        _ paths: [String], root: String = root(),
        evict: (URL) throws -> Void = { try FileManager.default.evictUbiquitousItem(at: $0) },
        state: (URL) -> State? = { (try? $0.resourceValues(forKeys: keys)).map(State.init) }
    ) -> (removed: [String], failed: [String: String]) {
        var removed: [String] = [], failed: [String: String] = [:]
        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard path.hasPrefix(root + "/"), Trasher.noLinksBetween(root, and: path),
                  let s = state(url), let now = item(path, s, minimum: 0), now.uploaded
            else {
                failed[path] = String(localized: "It changed since it was listed, or isn't uploaded in full yet.")
                continue
            }
            do {
                try evict(url)
                removed.append(path)
            } catch {
                failed[path] = error.localizedDescription
            }
        }
        return (removed, failed)
    }
}
