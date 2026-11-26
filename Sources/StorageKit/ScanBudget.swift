import Foundation
import SynchronizationCompat

/// How many disk walks run at once, whichever pane started them. Smart
/// Scan, a launch's prefetch and a pane's own Rescan can each start
/// several; past `slots` the rest wait their turn, a foreground scan before
/// any background one, so the disk and the cores aren't split so finely
/// that nothing finishes. A scan stopped while it waits leaves the queue.
public final class ScanBudget: Sendable {
    /// The app's walks, as many at once as the scan speed allows; read as
    /// each walk asks for a slot, so a change applies to the next one.
    public static let shared = ScanBudget(slots: { PerformanceLevel.inEffect().scanSlots() })

    private final class Request: Sendable {
        let cancelled = Atomic<Bool>(false)
    }

    private struct Waiter {
        let request: Request
        let background: Bool
        let resume: CheckedContinuation<Bool, Never>
    }

    private struct State {
        var running = 0
        var waiting: [Waiter] = []
    }

    private let state = Mutex(State())
    private let slotCount: @Sendable () -> Int
    public var slots: Int { max(1, slotCount()) }

    public init(slots: Int) {
        let fixed = max(1, slots)
        slotCount = { fixed }
    }

    public init(slots: @escaping @Sendable () -> Int) { slotCount = slots }

    /// Scans running now, and waiting.
    public var running: Int { state.withLock { $0.running } }
    public var waiting: Int { state.withLock { $0.waiting.count } }

    /// Runs `work` once a slot is free. A foreground request goes ahead of
    /// every background one already waiting.
    /// A stopped request leaves the queue immediately, without starting `work`
    /// or borrowing a slot from a scan that is still running.
    public func run<T: Sendable>(background: Bool, progress: ScanProgress? = nil, _ work: () async -> T) async -> T? {
        let request = Request()
        let observer = progress?.onCancel { [self] in cancel(request) }
        defer { progress?.removeCancellationObserver(observer) }
        return await withTaskCancellationHandler {
            guard await enter(background: background, request: request) else { return nil }
            defer { leave() }
            guard !Task.isCancelled, progress?.isCancelled != true else { return nil }
            return await work()
        } onCancel: {
            progress?.cancel()
            self.cancel(request)
        }
    }

    /// A disk walk, which blocks until it's done, on a thread of its own
    /// once a slot is free. Swift's shared task threads are one per core:
    /// a walk waiting on the disk there would hold one for as long as it
    /// runs, and as many walks as cores would stop every other task of
    /// their priority from starting, a filter or a sort among them.
    public func walk<T: Sendable>(background: Bool, progress: ScanProgress? = nil, _ work: @escaping @Sendable () -> T) async -> T? {
        await run(background: background, progress: progress) { await Self.onOwnThread(work) }
    }

    /// Runs blocking `work` on a new thread at the calling task's priority.
    public static func onOwnThread<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        let quality: QualityOfService =
            switch Task.currentPriority.rawValue {
            case TaskPriority.userInitiated.rawValue...: .userInitiated
            case TaskPriority.medium.rawValue...: .default
            case TaskPriority.utility.rawValue...: .utility
            default: .background
            }
        return await withCheckedContinuation { continuation in
            let thread = Thread { continuation.resume(returning: work()) }
            thread.name = "mymole.walk"
            thread.qualityOfService = quality
            thread.start()
        }
    }

    private func enter(background: Bool, request: Request) async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            let (go, admitted) = state.withLock { s -> (Bool?, [Waiter]) in
                guard !request.cancelled.load(ordering: .relaxed) else { return (false, []) }
                if s.waiting.isEmpty, s.running < slots {
                    s.running += 1
                    return (true, [])
                }
                let w = Waiter(request: request, background: background, resume: c)
                if background {
                    s.waiting.append(w)
                } else {
                    // After the foreground ones already waiting, before any background one.
                    let at = s.waiting.firstIndex { $0.background } ?? s.waiting.count
                    s.waiting.insert(w, at: at)
                }
                // Room the limit gained while others waited goes to them in their order.
                return (nil, admit(&s))
            }
            for waiter in admitted { waiter.resume.resume(returning: true) }
            if let go { c.resume(returning: go) }
        }
    }

    /// Takes as many from the front of the line as the limit has room for
    /// now, and counts them as running.
    private func admit(_ s: inout State) -> [Waiter] {
        let room = min(max(0, slots - s.running), s.waiting.count)
        guard room > 0 else { return [] }
        let next = Array(s.waiting.prefix(room))
        s.waiting.removeFirst(room)
        s.running += room
        return next
    }

    private func cancel(_ request: Request) {
        let waiter = state.withLock { s -> Waiter? in
            request.cancelled.store(true, ordering: .relaxed)
            guard let index = s.waiting.firstIndex(where: { $0.request === request }) else { return nil }
            return s.waiting.remove(at: index)
        }
        waiter?.resume.resume(returning: false)
    }

    private func leave() {
        let admitted = state.withLock { s -> [Waiter] in
            // The limit as it is now decides who goes next: with fewer
            // slots than when this walk started its slot closes, so a
            // lowered scan speed applies to the scans already waiting, and
            // with more, every one there is room for starts at once.
            s.running -= 1
            return admit(&s)
        }
        for waiter in admitted { waiter.resume.resume(returning: true) }
    }
}
