import AppKit
import SwiftUI
import Testing

@testable import MyMole

/// A pane opened while the app is in front reads at once and then on its
/// interval, in a window made by AppKit as the app's are.
@MainActor @Suite(.serialized) struct LiveRefreshWindowTests {
    final class Count { var reads = 0 }

    private func show(active: Bool, count: Count) -> NSWindow {
        let view = Text("Synthetic pane").modifier(LiveRefreshModifier(
            interval: .milliseconds(50), events: [], active: { active }, shown: { true }, update: { count.reads += 1 }))
        let host = NSHostingController(rootView: view)
        host.sceneBridgingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.orderBack(nil)
        return window
    }

    @Test func aPaneShownWhileTheAppIsInFrontReadsAndKeepsReading() async throws {
        let count = Count()
        let window = show(active: true, count: count)
        defer { window.close() }
        for _ in 0..<100 where count.reads < 3 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(count.reads >= 3)
    }

    @Test func aPaneShownWhileTheAppIsBehindWaitsUntilItComesForward() async throws {
        let count = Count()
        let window = show(active: false, count: count)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(300))
        #expect(count.reads == 0)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        for _ in 0..<100 where count.reads == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(count.reads > 0)
    }
}
