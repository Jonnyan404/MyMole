import Foundation
import Synchronization
import Testing

@testable import StorageKit

/// iCloud downloads, with iCloud's answers and its eviction stood in for:
/// only a file that is downloaded and uploaded in full is offered or removed.
@Suite struct CloudDownloadsTests {
    @Test func onlyADownloadedFileOfTheSizeIsListed() {
        let ok = CloudDownloads.State(inCloud: true, downloaded: true, uploaded: true, bytes: 5 << 20)
        #expect(CloudDownloads.item("/synthetic/a", ok, minimum: 1 << 20)?.uploaded == true)
        #expect(CloudDownloads.item("/synthetic/a", .init(inCloud: true, downloaded: false, uploaded: true, bytes: 5 << 20), minimum: 0) == nil)
        #expect(CloudDownloads.item("/synthetic/a", .init(inCloud: false, downloaded: true, uploaded: true, bytes: 5 << 20), minimum: 0) == nil)
        #expect(CloudDownloads.item("/synthetic/a", ok, minimum: 10 << 20) == nil)
        // Not yet uploaded: listed, but not as safe to remove.
        #expect(CloudDownloads.item("/synthetic/a", .init(inCloud: true, downloaded: true, uploaded: false, bytes: 5 << 20), minimum: 0)?.uploaded == false)
    }

    @Test func removalChecksAgainAndEvictsOnlyWhatsSafe() throws {
        let box = try Sandbox()
        let root = box.path + "/Mobile Documents"
        try box.file("Mobile Documents/com~apple~CloudDocs/up.bin", bytes: 10)
        try box.file("Mobile Documents/com~apple~CloudDocs/pending.bin", bytes: 10)
        let up = root + "/com~apple~CloudDocs/up.bin", pending = root + "/com~apple~CloudDocs/pending.bin"
        let evicted = Mutex<[String]>([])
        let r = CloudDownloads.remove([up, pending, box.path + "/elsewhere.bin"], root: root,
                                      evict: { url in evicted.withLock { $0.append(url.path) } },
                                      state: { url in .init(inCloud: true, downloaded: true, uploaded: url.path == up, bytes: 10) })
        #expect(r.removed == [up] && evicted.withLock { $0 } == [up])
        #expect(Set(r.failed.keys) == [pending, box.path + "/elsewhere.bin"])
    }

    @Test func aFolderOutsideICloudListsNothing() throws {
        let box = try Sandbox()
        try box.file("plain/big.bin", bytes: 2 << 20)
        #expect(CloudDownloads.list(root: box.path + "/plain").isEmpty)
    }
}
