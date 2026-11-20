import Darwin
import Foundation
import Testing

import PrivilegedKit
@testable import MyMole
@testable import StorageKit

/// Each panel's move and its Undo, checked byte for byte: what was chosen
/// is in the Trash exactly as it was, nothing else in the home folder
/// changed, the sizes shown are the blocks the items take, and Undo puts
/// back exactly what was there.
@MainActor @Suite(.serialized) struct CommandIntegrityTests {
    private final class Box {
        let root = FileManager.default.temporaryDirectory.appending(path: "integrity-\(UUID().uuidString)")
        var home: String { root.appending(path: "home").path }
        var bin: String { root.appending(path: "Bin").path }

        init() throws { try FileManager.default.createDirectory(atPath: root.path + "/home", withIntermediateDirectories: true) }
        deinit {
            let all = FileManager.default.enumerator(atPath: root.path)
            while let rel = all?.nextObject() as? String { chflags(root.path + "/" + rel, 0) }
            try? FileManager.default.removeItem(at: root)
        }

        func file(_ rel: String, bytes: Int) throws {
            let path = home + "/" + rel
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            var data = Data(count: bytes)
            data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, bytes) }
            try data.write(to: URL(fileURLWithPath: path))
        }

        /// Content, tags, a resource fork, a hidden flag, permissions, a time
        /// to the nanosecond, a link and a file with two names.
        func richFolder(_ rel: String) throws {
            try file(rel + "/random.bin", bytes: 300_000)
            try file(rel + "/deep/deeper/note.txt", bytes: 2_000)
            try file(rel + "/tagged.txt", bytes: 1_500)
            try file(rel + "/Cafe\u{301}.txt", bytes: 900)
            let base = home + "/" + rel
            for (name, size) in [("com.apple.metadata:_kMDItemUserTags", 50), ("com.apple.ResourceFork", 3_000)] {
                var value = [UInt8](repeating: 0, count: size)
                arc4random_buf(&value, size)
                #expect(setxattr(base + "/tagged.txt", name, value, size, 0, XATTR_NOFOLLOW) == 0)
            }
            #expect(chflags(base + "/Cafe\u{301}.txt", UInt32(UF_HIDDEN)) == 0 && chmod(base + "/deep/deeper/note.txt", 0o600) == 0)
            var times = [timespec(tv_sec: 1_000_000_000, tv_nsec: 111_222_333), timespec(tv_sec: 1_000_000_000, tv_nsec: 111_222_333)]
            #expect(utimensat(AT_FDCWD, base + "/random.bin", &times, 0) == 0)
            try FileManager.default.createSymbolicLink(atPath: base + "/to random", withDestinationPath: "random.bin")
            #expect(link(base + "/random.bin", base + "/deep/random again.bin") == 0)
        }

        @MainActor func storageModel() -> StorageModel {
            let model = StorageModel()
            model.snapshotBase = root.appending(path: "snapshots")
            model.protections = UserProtections(root: root.appending(path: "support"))
            model.logURL = root.appending(path: "history.json")
            model.trashBackend = testBin(root)
            model.jobs = TrashJobs()
            model.scanBudget = ScanBudget(slots: 1)
            return model
        }
    }

    private func wait(_ check: @MainActor () -> Bool) async throws {
        for _ in 0..<2_000 {
            if check() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NSError(domain: "IntegrityTimeout", code: 1)
    }

    /// Blocks each file takes, once for a file with several names.
    private func allocated(_ root: String) -> Int64 {
        var seen = Set<String>(), bytes: Int64 = 0
        var paths = [root]
        if let all = FileManager.default.enumerator(atPath: root) { while let rel = all.nextObject() as? String { paths.append(root + "/" + rel) } }
        for p in paths {
            var st = stat()
            if lstat(p, &st) == 0, st.st_mode & S_IFMT == S_IFREG, seen.insert("\(st.st_dev):\(st.st_ino)").inserted { bytes += Int64(st.st_blocks) * 512 }
        }
        return bytes
    }

    /// What's in the Trash, by its name there, compared with what left.
    private func expectInBin(_ box: Box, _ before: TreeFingerprint, moved rels: [String]) throws {
        let there = try FileManager.default.contentsOfDirectory(atPath: box.bin)
        for rel in rels {
            let name = (rel as NSString).lastPathComponent
            // The test's Trash puts a number of its own before each name.
            let match = try there.filter { $0 == name || $0.hasSuffix("-" + name) }
                .map { try TreeFingerprint(box.bin + "/" + $0).items }
            #expect(match.contains(before.under(rel)), "\(rel) isn't in the Trash as it was: \(there) \(match.map { TreeFingerprint.differences(before.under(rel), $0) })")
        }
    }

    @Test func diskMapMovesExactlyWhatsMarkedAndUndoPutsItBack() async throws {
        let box = try Box()
        try box.richFolder("Projects/build")
        try box.richFolder("Projects/keep")
        try box.file("Downloads/movie.bin", bytes: 12_000_000)
        try box.file("Downloads/notes.txt", bytes: 1_000)
        let model = box.storageModel()
        model.scan(path: box.home)
        await model.scanJob?.value
        try await wait { !model.scanning }
        let before = try TreeFingerprint(box.home)
        let chosen = ["Projects/build", "Downloads/movie.bin"]
        for rel in chosen {
            let path = box.home + "/" + rel
            let folder = model.root?.find(path: path)
            let size = folder?.size ?? model.root?.find(path: box.home + "/Downloads")?.listedFiles.first { $0.name == "movie.bin" }?.size ?? -1
            // The size shown is the blocks it takes.
            #expect(size == allocated(path), "\(rel): shown \(size), blocks \(allocated(path))")
            model.mark([Marked(path: path, name: (rel as NSString).lastPathComponent, size: size, isFolder: folder != nil)])
        }
        model.beginTrashReview()
        model.showReview = false
        model.trashMarked()
        try await wait { !model.trashing }
        try expectInBin(box, before, moved: chosen)
        let during = try TreeFingerprint(box.home)
        #expect(during.outside(chosen) == before.outside(chosen), "\(TreeFingerprint.differences(before.outside(chosen), during.outside(chosen)))")
        model.undoTrash()
        try await wait { !model.trashing }
        await model.scanJob?.value
        let after = try TreeFingerprint(box.home)
        #expect(after == before, "\(TreeFingerprint.differences(before.items, after.items))")
        #expect(try FileManager.default.contentsOfDirectory(atPath: box.bin).isEmpty)
    }

    @Test func uninstallMovesTheAppAndItsLeftoversWholeAndUndoPutsThemBack() async throws {
        let box = try Box()
        try box.richFolder("Applications/Editor.app/Contents/Resources")
        try box.file("Applications/Editor.app/Contents/MacOS/Editor", bytes: 80_000)
        let info: NSDictionary = ["CFBundleIdentifier": "com.vendor.Editor", "CFBundleName": "Editor"]
        try info.write(to: URL(fileURLWithPath: box.home + "/Applications/Editor.app/Contents/Info.plist"))
        try box.richFolder("Library/Application Support/com.vendor.Editor")
        try box.file("Library/Caches/com.vendor.Editor/cache.db", bytes: 40_000)
        try box.file("Library/Preferences/com.vendor.Editor.plist", bytes: 700)
        // Locked in Finder: unlocked to move, and locked again by Undo.
        #expect(chflags(box.home + "/Library/Preferences/com.vendor.Editor.plist", UInt32(UF_IMMUTABLE)) == 0)
        try box.richFolder("Library/Application Support/com.other.Viewer")
        try box.file("Documents/mine.txt", bytes: 5_000)
        let root = box.root
        let model = AppsModel(
            home: box.home, folders: [box.home + "/Applications"], base: root.appending(path: "store"),
            logURL: root.appending(path: "history.json"),
            recycle: { [bin = testBin(root)] in Trasher.moveToTrash($0, through: TrashGate(still: { _ in true }, protections: TrashGate.keepsNothing), backend: bin) },
            isRunning: { _ in false }, otherCopies: { _ in [] },
            system: AppsModel.SystemSide(base: box.root.path + "/system", isReady: { false }, remove: { _, _, _, _ in RemovalReport() }),
            trash: testBin(root), protections: UserProtections(root: root.appending(path: "support")),
            imageOf: { _ in nil }, eject: { _ in "Not in tests" }, identityReaders: .init(groups: { _ in [] }), runtimeRoots: [])
        model.load()
        await model.loadJob?.value
        let app = try #require(model.apps.first { $0.bundleID == "com.vendor.Editor" })
        let report = try #require(await model.leftoverReport(for: app))
        let leftovers = report.items.filter { $0.chosenByDefault }
        let before = try TreeFingerprint(box.home)
        let gone = ["Applications/Editor.app"] + leftovers.map { String($0.path.dropFirst(box.home.count + 1)) }
        #expect(Set(gone) == ["Applications/Editor.app", "Library/Application Support/com.vendor.Editor", "Library/Caches/com.vendor.Editor",
                              "Library/Preferences/com.vendor.Editor.plist"])
        // The sizes shown are the blocks each takes.
        for l in leftovers { #expect(l.bytes == allocated(l.path), "\(l.path)") }
        #expect(await model.uninstall(app, leftovers: leftovers) == .done)
        let during = try TreeFingerprint(box.home)
        #expect(during.outside(gone) == before.outside(gone), "\(TreeFingerprint.differences(before.outside(gone), during.outside(gone)))")
        model.undoUninstall()
        try await wait { !model.uninstalling }
        try await wait { FileManager.default.fileExists(atPath: box.home + "/Applications/Editor.app") }
        let after = try TreeFingerprint(box.home)
        #expect(after == before, "\(TreeFingerprint.differences(before.items, after.items))")
    }
}
