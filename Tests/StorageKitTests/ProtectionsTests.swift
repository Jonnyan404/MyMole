import Darwin
import Foundation
import Testing

@testable import StorageKit

/// What the user keeps by path, read together for the panes that move what
/// another pane's list protects.
@Suite struct UserProtectionsTests {
    @Test func aPathKeptInEitherPaneIsKeptWithWhatHoldsItAndWhatItHolds() throws {
        let box = try Sandbox()
        let p = UserProtections(root: box.url.appending(path: "support"))
        // No lists yet: nothing is kept.
        #expect(try !p.read()("/synthetic/Library/Caches/com.vendor.Editor"))

        try CleanKeepList(paths: ["/synthetic/Library/Caches/com.vendor.Editor"]).save(to: p.keepList)
        var rules = ProjectRules()
        rules.keepPaths = ["/synthetic/Workspace/app/node_modules/local-only"]
        rules.keepNames = ["notes"]
        try ProjectStore.saveRules(rules, base: p.projectBase)
        let keeps = try p.read()
        #expect(keeps("/synthetic/Library/Caches/com.vendor.Editor"))
        #expect(keeps("/synthetic/Library/Caches/com.vendor.Editor/blob") && keeps("/synthetic/Library/Caches"))
        #expect(keeps("/synthetic/Workspace/app/node_modules") && keeps("/synthetic/Workspace/app"))
        #expect(!keeps("/synthetic/Library/Caches/com.vendor.Player"))
        // A rule by name is Projects' own.
        #expect(!keeps("/synthetic/Downloads/notes"))
    }

    @Test func systemCleansListIsReadApart() throws {
        let box = try Sandbox()
        let p = UserProtections(root: box.url.appending(path: "support"))
        #expect(try !p.readSystem()("/Library/Caches/com.vendor.Editor"))
        try CleanKeepList(paths: ["/Library/Caches/com.vendor.Editor"]).save(to: p.systemKeepList)
        #expect(try p.readSystem()("/Library/Caches/com.vendor.Editor"))
        #expect(try !p.read()("/Library/Caches/com.vendor.Editor"))
    }

    @Test func aListThatCantBeReadThrows() throws {
        let box = try Sandbox()
        let p = UserProtections(root: box.url.appending(path: "support"))
        try FileManager.default.createDirectory(at: p.keepList.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: p.keepList)
        #expect(throws: (any Error).self) { _ = try p.read() }
        // Deep Clean's list reads again, the project rules don't.
        try CleanKeepList().save(to: p.keepList)
        try FileManager.default.createDirectory(at: p.projectBase, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: p.projectBase.appending(path: "rules.json"))
        #expect(throws: (any Error).self) { _ = try p.read() }
        try FileManager.default.createDirectory(at: p.systemKeepList.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: p.systemKeepList)
        #expect(throws: (any Error).self) { _ = try p.readSystem() }
    }

    @Test func aKeptItemStaysKeptThroughALinkToAFolderAboveIt() throws {
        let box = try Sandbox()
        let root = box.url.resolvingSymlinksInPath().path
        try box.file("real/folder/kept.txt", bytes: 8192)
        try box.folder("Trash")
        #expect(symlink(root + "/real", root + "/alias") == 0)
        let protections = UserProtections(root: box.url.appending(path: "protections"))
        try CleanKeepList(paths: [root + "/real/folder/kept.txt"]).save(to: protections.keepList)
        let candidate = root + "/alias/folder"
        #expect(StorageScanner.scan(path: candidate, workers: 1).root.fileCount == 1)
        let gate = TrashGate(still: { _ in true }, protections: { try protections.read() })
        let outcome = Trasher.moveToTrash([candidate], through: gate, backend: .folder(root + "/Trash"))
        #expect(outcome.moved.isEmpty)
        #expect(FileManager.default.fileExists(atPath: root + "/real/folder/kept.txt"))
        // Kept through the link, the item is kept where it is, and in any flow's own gate.
        try CleanKeepList(paths: [root + "/alias/folder/kept.txt"]).save(to: protections.keepList)
        #expect(try protections.read()(root + "/real/folder"))
        let real = try #require(Trasher.resolvingParent(root + "/real/folder/kept.txt"))
        let own = TrashGate(still: { _ in true }, protections: { { $0 == real } })
        #expect(Trasher.moveToTrash([root + "/alias/folder/kept.txt"], through: own, backend: .folder(root + "/Trash")).moved.isEmpty)
        // The link itself goes alone; what it points to stays.
        try CleanKeepList(paths: [root + "/real/folder/kept.txt"]).save(to: protections.keepList)
        let link = Trasher.moveToTrash([root + "/alias"], through: gate, backend: .folder(root + "/Trash"))
        #expect(link.moved.count == 1 && FileManager.default.fileExists(atPath: root + "/real/folder/kept.txt"))
    }
}
