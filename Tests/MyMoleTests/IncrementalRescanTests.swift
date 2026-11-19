import Darwin
import Foundation
import Testing

@testable import MyMole
@testable import StorageKit

/// Rescan Entire Map reads only the folders the event history says
/// changed, and the map it makes equals a full scan of the same folder.
@MainActor @Suite struct IncrementalRescanTests {
    private final class Box {
        let root = FileManager.default.temporaryDirectory.appending(path: "incremental-rescan-\(UUID().uuidString)")
        var home: String { root.appending(path: "home").path }

        init() throws { try FileManager.default.createDirectory(at: root.appending(path: "home"), withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(at: root) }

        func file(_ rel: String, bytes: Int) throws {
            let url = root.appending(path: "home/" + rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: bytes).write(to: url)
        }

        @MainActor func model() -> StorageModel {
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

    private func settle(_ model: StorageModel) async throws {
        for _ in 0..<2_000 {
            if !model.scanning { await model.scanJob?.value; if !model.scanning { return } }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NSError(domain: "RescanTimeout", code: 1)
    }

    @Test func onlyTheChangedFoldersAreReadAndTheMapEqualsAFullScan() async throws {
        let box = try Box()
        try box.file("Projects/app/src/main.bin", bytes: 2 << 20)
        try box.file("Projects/web/index.bin", bytes: 1 << 20)
        try box.file("Music/song.bin", bytes: 3 << 20)
        // The history numbers an event when it takes it in: the files are let settle first, or
        // their own events would come after the scan and make the whole map be read again.
        try await Task.sleep(for: .seconds(1))
        let model = box.model()
        model.scan(path: box.home)
        await model.scanJob?.value
        #expect(model.lastDuration != nil)
        try await Task.sleep(for: .milliseconds(300))
        try box.file("Projects/app/src/extra.bin", bytes: 4 << 20)
        try box.file("Projects/web/assets/logo.bin", bytes: 2 << 20)
        // The history is written a moment after the change.
        try await Task.sleep(for: .seconds(1))
        model.rescan()
        try await settle(model)
        let full = StorageScanner.scan(path: box.home, workers: 1).root
        #expect(model.root?.size == full.size && model.root?.fileCount == full.fileCount)
        #expect(model.root?.find(path: box.home + "/Projects/web/assets")?.size == full.find(path: box.home + "/Projects/web/assets")?.size)
        // Read folder by folder, not as a whole map: a whole scan records how long it took.
        #expect(model.lastDuration == nil)
    }
}
