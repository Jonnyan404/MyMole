import Foundation
import Testing

@testable import StorageKit

@Suite struct VolumesTests {
    @Test func aDiskKeepsItsOwnHistoryWhateverItsName() {
        #expect(Volumes.historyKey(for: "/synthetic/home") { _ in (true, "A") } == "/synthetic/home")
        let first = Volumes.historyKey(for: "/Volumes/Backup") { _ in (false, "UUID-1") }
        let other = Volumes.historyKey(for: "/Volumes/Backup") { _ in (false, "UUID-2") }
        #expect(first == "/Volumes/Backup#UUID-1" && first != other)
        // A disk that doesn't say who it is shares with none.
        let a = Volumes.historyKey(for: "/Volumes/Stick") { _ in (false, nil) }
        let b = Volumes.historyKey(for: "/Volumes/Stick") { _ in (false, nil) }
        #expect(a != b && a.hasPrefix("/Volumes/Stick#unknown-"))
    }

    /// A WebDAV share gives no size and 0 for what's free for important use.
    @Test func aDiskThatGivesNoSizeHasNoKnownFreeSpace() {
        #expect(Volumes.free(total: nil, forImportantUsage: 0, plain: nil) == nil)
        #expect(Volumes.free(total: 0, forImportantUsage: 0, plain: 0) == nil)
        #expect(Volumes.free(total: 1_000, forImportantUsage: 400, plain: 300) == 400)
        #expect(Volumes.free(total: 1_000, forImportantUsage: nil, plain: 300) == 300)
    }

    /// A share connected again has the same address, so its history is kept; a password never is.
    @Test func aShareIsKnownByTheAddressItsMountedFrom() throws {
        let one = Volumes.shareIdentity(try #require(URL(string: "smb://anna:secret@nas.local/Media")))
        let again = Volumes.shareIdentity(try #require(URL(string: "smb://anna:secret@nas.local/Media")))
        #expect(one == again && one == "share:smb://anna@nas.local/Media")
        #expect(Volumes.shareIdentity(try #require(URL(string: "smb://anna@nas.local/Other"))) != one)
        #expect(Volumes.shareIdentity(URL(fileURLWithPath: "/Volumes/Stick")) == nil)
    }

    @Test func theStartupDiskIsListedFirst() {
        let all = Volumes.mounted()
        #expect(all.first?.path == "/")
    }

    @Test func aSnapshotSavedUnderAKeyIsFoundUnderIt() throws {
        let box = try Sandbox()
        let base = box.url.appending(path: "snapshots")
        let s = Snapshot(rootPath: "/Volumes/Backup", date: Date(), sizes: ["": 1])
        _ = SnapshotStore.save(s, key: "/Volumes/Backup#UUID-1", base: base)
        #expect(SnapshotStore.history(for: "/Volumes/Backup#UUID-1", base: base).count == 1)
        #expect(SnapshotStore.history(for: "/Volumes/Backup", base: base).isEmpty)
    }
}
