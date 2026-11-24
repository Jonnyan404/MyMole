import Foundation
import Synchronization
import Testing

@testable import MyMole
@testable import StorageKit

/// Stop on a disk that doesn't answer: one read the system can't interrupt
/// is left to end on its own, and the map stops waiting for it.
@MainActor @Suite struct SlowDiskStopTests {
    private final class Box {
        let root = FileManager.default.temporaryDirectory.appending(path: "slow-disk-stop-\(UUID().uuidString)")
        var home: String { root.appending(path: "home").path }

        init() throws {
            try FileManager.default.createDirectory(at: root.appending(path: "home/a"), withIntermediateDirectories: true)
            try Data(repeating: 1, count: 4_000).write(to: root.appending(path: "home/a/f.bin"))
        }
        deinit { try? FileManager.default.removeItem(at: root) }

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

    @Test func stopLetsGoOfADiskThatDoesntAnswer() async throws {
        let box = try Box()
        let model = box.model()
        model.stopWait = .milliseconds(200)
        let held = DispatchSemaphore(value: 0)
        let reading = Atomic(false)
        model.scanFolder = { path, progress, workers, root, subtree, skip in
            reading.store(true, ordering: .relaxed)
            // A read in the kernel: it ends when the disk answers, whatever Stop says.
            held.wait()
            return StorageScanner.scan(path: path, progress: progress, workers: workers, onRoot: root, onSubtree: subtree, skip: skip)
        }
        model.scan(path: box.home)
        for _ in 0..<500 where !reading.load(ordering: .relaxed) { try await Task.sleep(for: .milliseconds(5)) }
        model.cancelScan()
        for _ in 0..<400 where model.scanning { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!model.scanning && model.root == nil)
        #expect(model.notice?.text.contains("slow to answer") == true)
        // The disk answers at last: what it read is never shown.
        held.signal()
        await model.scanJob?.value
        try await Task.sleep(for: .milliseconds(100))
        #expect(!model.scanning && model.root == nil)
        // A new scan works as before.
        model.scanFolder = { path, progress, workers, root, subtree, skip in
            StorageScanner.scan(path: path, progress: progress, workers: workers, onRoot: root, onSubtree: subtree, skip: skip)
        }
        model.scan(path: box.home)
        await model.scanJob?.value
        for _ in 0..<400 where model.scanning { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.root?.fileCount == 1)
    }

    /// Only a stop seen to end within the wait says something: a busy Mac can
    /// hold it up past a short one, and then the notice is right. It's tried
    /// again with a longer wait.
    @Test func aDiskThatStopsAtOnceShowsNoNotice() async throws {
        for wait in [Duration.milliseconds(300), .seconds(1), .seconds(3), .seconds(10)] {
            let box = try Box()
            let model = box.model()
            model.stopWait = wait
            let reading = Atomic(false)
            model.scanFolder = { path, progress, workers, root, subtree, skip in
                reading.store(true, ordering: .relaxed)
                while !progress.isCancelled { usleep(2_000) }
                return StorageScanner.scan(path: path, progress: progress, workers: workers, onRoot: root, onSubtree: subtree, skip: skip)
            }
            model.scan(path: box.home)
            for _ in 0..<500 where !reading.load(ordering: .relaxed) { try await Task.sleep(for: .milliseconds(5)) }
            let asked = ContinuousClock.now
            model.cancelScan()
            await model.scanJob?.value
            let inTime = !model.scanning && ContinuousClock.now - asked < wait
            guard inTime else { continue }
            #expect(model.notice == nil)
            // The wait runs out after the stop, and still says nothing.
            try await Task.sleep(until: asked + wait + .milliseconds(200), clock: .continuous)
            #expect(!model.scanning && model.notice == nil)
            return
        }
        Issue.record("No stop ended within its wait")
    }
}
