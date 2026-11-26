import Foundation
import SynchronizationCompat
import Testing

@testable import StorageKit

@Suite struct ScanBudgetTests {
    @Test func noMoreThanTheSlotsRunAtOnce() async {
        let budget = ScanBudget(slots: 2)
        let counts = RunningScans()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await budget.run(background: false) {
                        let n = counts.now.add(1, ordering: .relaxed).newValue
                        _ = counts.most.max(n, ordering: .relaxed)
                        try? await Task.sleep(for: .milliseconds(20))
                        counts.now.subtract(1, ordering: .relaxed)
                    }
                }
            }
        }
        #expect(counts.most.load(ordering: .relaxed) == 2)
        #expect(budget.running == 0 && budget.waiting == 0)
    }

    @Test func aForegroundScanGoesBeforeWaitingBackgroundOnes() async throws {
        let budget = ScanBudget(slots: 1)
        let order = ScanOrder()
        let (stream, release) = AsyncStream<Void>.makeStream()
        defer { release.yield(()); release.finish() }
        let hold = Task {
            await budget.run(background: false) { for await _ in stream { break } }
        }
        try #require(await waitUntil { budget.running == 1 })
        let first = Task { await budget.run(background: true) { order.entries.withLock { $0.append("background") } } }
        try #require(await waitUntil { budget.waiting == 1 })
        let second = Task { await budget.run(background: false) { order.entries.withLock { $0.append("foreground") } } }
        try #require(await waitUntil { budget.waiting == 2 })
        release.yield(())
        release.finish()
        _ = await (hold.value, first.value, second.value)
        #expect(order.entries.withLock { $0 } == ["foreground", "background"])
    }

    @Test func stoppingAQueuedScanDoesNotWaitForOrReleaseAnotherScansSlot() async throws {
        let budget = ScanBudget(slots: 1)
        let (stream, release) = AsyncStream<Void>.makeStream()
        defer { release.yield(()); release.finish() }
        let hold = Task { await budget.run(background: false) { for await _ in stream { break } } }
        try #require(await waitUntil { budget.running == 1 })
        let progress = ScanProgress()
        let worked = Atomic<Bool>(false)
        let finished = Atomic<Bool>(false)
        let queued = Task {
            let result = await budget.run(background: true, progress: progress) {
                worked.store(true, ordering: .relaxed)
                return 1
            }
            #expect(result == nil)
            finished.store(true, ordering: .relaxed)
        }
        try #require(await waitUntil { budget.waiting == 1 })
        progress.cancel()
        progress.cancel()
        try #require(await waitUntil { finished.load(ordering: .relaxed) })
        #expect(worked.load(ordering: .relaxed) == false)
        #expect(budget.waiting == 0 && budget.running == 1)
        release.yield(())
        release.finish()
        _ = await (hold.value, queued.value)
        #expect(budget.running == 0)
    }

    @Test func cancellingTheTaskAlsoRemovesItsQueuedScan() async throws {
        let budget = ScanBudget(slots: 1)
        let (stream, release) = AsyncStream<Void>.makeStream()
        defer { release.yield(()); release.finish() }
        let hold = Task { await budget.run(background: false) { for await _ in stream { break } } }
        try #require(await waitUntil { budget.running == 1 })
        let progress = ScanProgress()
        let finished = Atomic<Bool>(false)
        let queued = Task {
            let result = await budget.run(background: false, progress: progress) { 1 }
            #expect(result == nil)
            finished.store(true, ordering: .relaxed)
        }
        try #require(await waitUntil { budget.waiting == 1 })
        queued.cancel()
        try #require(await waitUntil { finished.load(ordering: .relaxed) })
        #expect(progress.isCancelled && budget.waiting == 0 && budget.running == 1)
        release.yield(())
        release.finish()
        _ = await (hold.value, queued.value)
        #expect(budget.running == 0)
    }

    @Test func aScanStoppedBeforeQueuingNeverStarts() async {
        let budget = ScanBudget(slots: 1)
        let progress = ScanProgress()
        progress.cancel()
        let result = await budget.run(background: false, progress: progress) { 1 }
        #expect(result == nil && budget.running == 0 && budget.waiting == 0)
    }

    @Test func aLoweredLimitAppliesToScansAlreadyWaiting() async throws {
        let limit = RunningScans()
        limit.now.store(2, ordering: .relaxed)
        let budget = ScanBudget(slots: { limit.now.load(ordering: .relaxed) })
        let gates = (0..<2).map { _ in AsyncStream<Void>.makeStream() }
        let holders = gates.map { gate in Task { await budget.run(background: false) { for await _ in gate.stream { break } } } }
        try #require(await waitUntil { budget.running == 2 })
        let counts = RunningScans()
        let queued = (0..<4).map { _ in
            Task {
                await budget.run(background: false) {
                    let n = counts.now.add(1, ordering: .relaxed).newValue
                    _ = counts.most.max(n, ordering: .relaxed)
                    try? await Task.sleep(for: .milliseconds(20))
                    counts.now.subtract(1, ordering: .relaxed)
                }
            }
        }
        try #require(await waitUntil { budget.waiting == 4 })
        limit.now.store(1, ordering: .relaxed)
        for gate in gates {
            gate.continuation.yield(())
            gate.continuation.finish()
        }
        for task in holders + queued { _ = await task.value }
        #expect(counts.most.load(ordering: .relaxed) == 1)
        #expect(budget.running == 0 && budget.waiting == 0)
    }

    /// A limit raised while scans wait, as when the Mac has cooled down or
    /// the scan speed is turned up, starts every one there is now room for.
    @Test func aRaisedLimitStartsTheScansAlreadyWaiting() async throws {
        let limit = RunningScans()
        limit.now.store(1, ordering: .relaxed)
        let budget = ScanBudget(slots: { limit.now.load(ordering: .relaxed) })
        let gate = AsyncStream<Void>.makeStream()
        let holder = Task { await budget.run(background: false) { for await _ in gate.stream { break } } }
        try #require(await waitUntil { budget.running == 1 })
        let counts = RunningScans()
        let queued = (0..<3).map { _ in
            Task {
                await budget.run(background: true) {
                    let n = counts.now.add(1, ordering: .relaxed).newValue
                    _ = counts.most.max(n, ordering: .relaxed)
                    // Stays until all three run together, or long enough to show they don't.
                    for _ in 0..<100 where counts.now.load(ordering: .relaxed) < 3 { try? await Task.sleep(for: .milliseconds(10)) }
                    counts.now.subtract(1, ordering: .relaxed)
                }
            }
        }
        try #require(await waitUntil { budget.waiting == 3 })
        limit.now.store(4, ordering: .relaxed)
        gate.continuation.yield(())
        gate.continuation.finish()
        for task in [holder] + queued { _ = await task.value }
        #expect(counts.most.load(ordering: .relaxed) == 3)
        #expect(budget.running == 0 && budget.waiting == 0)
    }

    /// A scan asked for after the limit was raised joins the line rather
    /// than passing it: those already waiting start with it.
    @Test func aNewScanAfterARaisedLimitStartsThoseWaitingToo() async throws {
        let limit = RunningScans()
        limit.now.store(1, ordering: .relaxed)
        let budget = ScanBudget(slots: { limit.now.load(ordering: .relaxed) })
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.yield(()); gate.continuation.finish() }
        let holder = Task { await budget.run(background: false) { for await _ in gate.stream { break } } }
        try #require(await waitUntil { budget.running == 1 })
        let started = RunningScans()
        let waiting = Task { await budget.run(background: true) { _ = started.now.add(1, ordering: .relaxed) } }
        try #require(await waitUntil { budget.waiting == 1 })
        limit.now.store(3, ordering: .relaxed)
        _ = await budget.run(background: false) { _ = started.now.add(1, ordering: .relaxed) }
        _ = await waiting.value
        #expect(started.now.load(ordering: .relaxed) == 2)
        gate.continuation.yield(())
        gate.continuation.finish()
        _ = await holder.value
        #expect(budget.running == 0 && budget.waiting == 0)
    }

    @Test func aWalkRunsOnAThreadOfItsOwnAndGivesItsResult() async {
        let budget = ScanBudget(slots: 1)
        let name = await budget.walk(background: false) { Thread.current.name ?? "" }
        #expect(name == "mymole.walk")
        let progress = ScanProgress()
        progress.cancel()
        #expect(await budget.walk(background: false, progress: progress) { 1 } == nil)
        #expect(budget.running == 0 && budget.waiting == 0)
    }

    /// As many blocked walks as cores once kept every other task of their
    /// priority from starting.
    @Test func blockedWalksLeaveTheSharedTaskThreadsFree() async throws {
        let walks = ProcessInfo.processInfo.activeProcessorCount + 2
        let budget = ScanBudget(slots: .max)
        let release = DispatchSemaphore(value: 0)
        let blocked = (0..<walks).map { _ in
            Task.detached(priority: .userInitiated) { await budget.walk(background: false) { release.wait() } }
        }
        defer { for _ in 0..<walks { release.signal() } }
        try #require(await waitUntil { budget.running == walks })
        let started = RunningScans()
        Task.detached(priority: .userInitiated) { started.now.store(1, ordering: .relaxed) }
        #expect(await waitUntil { started.now.load(ordering: .relaxed) == 1 })
        for _ in 0..<walks { release.signal() }
        for task in blocked { _ = await task.value }
        #expect(budget.running == 0)
    }

    private func waitUntil(_ ready: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if ready() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return ready()
    }

    // Share Sendable references instead of capturing local noncopyable values
    // across tasks, which Swift 6.3 rejects.
    private final class RunningScans: Sendable {
        let now = Atomic<Int>(0)
        let most = Atomic<Int>(0)
    }

    private final class ScanOrder: Sendable {
        let entries = Mutex<[String]>([])
    }
}
