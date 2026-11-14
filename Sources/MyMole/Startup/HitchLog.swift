#if SMOKE
import Foundation
import StorageKit

/// The UI smoke build's record of every time the main thread was held up
/// for longer than a frame, for the resize checks in scripts/ui-smoke.sh.
/// A run-loop timer in the common modes ticks every 2 ms; a tick that
/// arrives late means the main thread was busy for that long, whatever kept
/// it busy. It is a run-loop timer rather than one on the main queue: while
/// AppKit tracks a drag in `NSWindow.trackEvents`, the run loop goes on
/// taking events and timers but the main queue waits, so a main-queue timer
/// counted an idle drag as stalls. Each stall is appended to `hitches.log`
/// in the run folder as "<wall-clock ms> <stall ms>". Only the smoke build
/// has it.
@MainActor
enum HitchLog {
    private static var timer: Timer?
    private static var out: FileHandle?
    private static var last: UInt64 = 0

    static func start() {
        guard timer == nil, let run = try? SyntheticRun.current() else { return }
        let url = URL(fileURLWithPath: run.root).appending(path: "hitches.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: url.path) else { return }
        out = handle
        last = DispatchTime.now().uptimeNanoseconds
        let timer = Timer(timeInterval: 0.002, repeats: true) { _ in MainActor.assumeIsolated { tick() } }
        timer.tolerance = 0.000_2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private static func tick() {
        let now = DispatchTime.now().uptimeNanoseconds
        let late = Double(now - last) / 1_000_000 - 2
        last = now
        guard late > 12 else { return }
        let line = String(format: "%.0f %.1f\n", Date().timeIntervalSince1970 * 1_000, late)
        out?.write(Data(line.utf8))
    }
}
#endif
