import Foundation
import Testing

@testable import StorageKit

/// Reading only what changed: the folders FSEvents names, mapped onto the
/// map, and a map patched folder by folder that equals a full scan.
@Suite struct ChangedFoldersTests {
    @Test func outermostKeepsEachPathOnceAndNoneInsideAnother() {
        #expect(ChangedFolders.outermost(["/s/a/b", "/s/a", "/s/ab", "/s/a/b/c", "/s/a"]) == ["/s/a", "/s/ab"])
    }

    @Test func aFolderMadeOrRemovedSinceIsReadThroughItsParent() throws {
        let box = try Sandbox()
        try box.file("A/x/one.bin", bytes: 10)
        try box.file("B/two.bin", bytes: 10)
        let map = StorageScanner.scan(path: box.path, workers: 1).root
        let read = ChangedFolders.toRead([box.path + "/A/x", box.path + "/A/new/deeper", box.path + "/C/gone"], in: map)
        // /A/new isn't in the map: its parent /A is read, which holds /A/x too. /C isn't either: the root.
        #expect(read == [box.path])
        #expect(ChangedFolders.toRead([box.path + "/A/x", box.path + "/B"], in: map) == [box.path + "/A/x", box.path + "/B"])
    }

    @Test func aMapPatchedFolderByFolderEqualsAFullScan() throws {
        let box = try Sandbox()
        try box.file("Docs/a/one.bin", bytes: 2 << 20)
        try box.file("Docs/b/two.bin", bytes: 3 << 20)
        try box.file("Other/three.bin", bytes: 1 << 20)
        var map = StorageScanner.scan(path: box.path, workers: 1).root
        // Changes in two folders: a file added in one, one removed and a folder made in the other.
        try box.file("Docs/a/four.bin", bytes: 4 << 20)
        try FileManager.default.removeItem(atPath: box.path + "/Docs/b/two.bin")
        try box.file("Docs/b/new/five.bin", bytes: 5 << 20)
        for path in ChangedFolders.toRead([box.path + "/Docs/a", box.path + "/Docs/b/new"], in: map) {
            let part = StorageScanner.scan(path: path, workers: 1).root
            map = try #require(map.replacingSubtree(at: path, with: part))
        }
        let full = StorageScanner.scan(path: box.path, workers: 1).root
        #expect(map.size == full.size && map.fileCount == full.fileCount)
        #expect(map.find(path: box.path + "/Docs/b/new")?.size == full.find(path: box.path + "/Docs/b/new")?.size)
        #expect(map.find(path: box.path + "/Docs/b")?.listedFiles.isEmpty == true)
    }

    /// The watcher names the folder a file was made in, by the path the
    /// map uses even through /var's link, and nothing outside its root.
    @Test func theWatcherNamesTheChangedFolder() async throws {
        let box = try Sandbox()
        try box.file("Watched/keep.bin", bytes: 10)
        try box.file("Outside/keep.bin", bytes: 10)
        try await Task.sleep(for: .seconds(1))
        let watcher = try #require(ChangedFolders.Watcher(root: box.path + "/Watched", since: ChangedFolders.now()))
        try box.file("Watched/inner/new.bin", bytes: 10)
        try box.file("Outside/new.bin", bytes: 10)
        var changed: [String] = []
        for _ in 0..<20 {
            changed = try #require(watcher.flush())
            if !changed.isEmpty { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        #expect(!changed.isEmpty && changed.allSatisfy { $0.hasPrefix(box.path + "/Watched") })
        watcher.stop()
        #expect(watcher.flush() == nil)
        #expect(ChangedFolders.Watcher(root: box.path, since: 0) == nil)
    }
}
