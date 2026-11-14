import AppKit
import SwiftUI
import Testing

@testable import MyMole

@MainActor @Suite struct StatusCardStabilityTests {
    @Test func expandingAndMissingReadingsKeepEveryCardInPlace() async throws {
        let previous = Density.current
        defer { Density.current = previous }
        for density in Density.allCases {
            Density.current = density
            for editing in [false, true] {
                try await checkCardFrames(compact: density == .compact, spacing: density == .compact ? 12 : 15, editing: editing)
            }
        }
    }

    /// A wider or narrower window moves and sizes the cards; it doesn't make
    /// their contents again or measure each card more than once.
    @Test func resizingTheGridLaysEachCardOutOnceAndMakesNothingAgain() async throws {
        let counts = GridCounts()
        let host = NSHostingView(rootView: CountingPanel(counts: counts))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        func settle() async throws {
            for _ in 0..<4 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        }
        try await settle()
        let cards = StatusLayout().visible.count
        counts.made = 0
        counts.measured = 0
        var steps = 0
        // Across one, two and three columns.
        for width in stride(from: CGFloat(1_100), through: 520, by: -20) {
            window.setContentSize(NSSize(width: width, height: 600))
            host.layoutSubtreeIfNeeded()
            steps += 1
        }
        #expect(counts.made == 0, "card contents made again \(counts.made) times in \(steps) steps")
        #expect(counts.measured <= steps * cards, "cards measured \(counts.measured) times in \(steps) steps of \(cards) cards")
    }

    @Test func aResizedScrollableGridReportsAndReachesItsLastCard() async throws {
        let host = NSHostingView(rootView: ScrollPanel())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        for width in [CGFloat(720), 1120, 560, 900] {
            window.setContentSize(NSSize(width: width, height: 400))
            host.frame = NSRect(x: 0, y: 0, width: width, height: 400)
            for _ in 0..<6 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            var views = [NSView](), pending = [host as NSView]
            while let view = pending.popLast() { views.append(view); pending += view.subviews }
            let probes = views.compactMap { $0 as? ProbeView }
            #expect(probes.count == StatusCardID.allCases.count)
            let scroll = try #require(views.compactMap { $0 as? NSScrollView }.first)
            let document = try #require(scroll.documentView)
            let last = try #require(probes.first { $0.card == .processes })
            let bottom = last.convert(last.bounds, to: document).maxY
            #expect(bottom <= document.bounds.maxY + 1)
            #expect(document.bounds.height > scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.maxY - scroll.contentView.bounds.height))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(for: .milliseconds(20))
            let reached = last.convert(last.bounds, to: scroll.contentView)
            #expect(reached.maxY <= scroll.contentView.bounds.maxY + 1)
            #expect(reached.minY >= scroll.contentView.bounds.minY - 1)
        }
    }

    private func checkCardFrames(compact: Bool, spacing: CGFloat, editing: Bool) async throws {
        let host = NSHostingView(rootView: Panel(expanded: false, compact: compact, spacing: spacing, editing: editing))
        host.frame = NSRect(x: 0, y: 0, width: 720, height: 1800)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        host.layoutSubtreeIfNeeded()
        let before = frames(in: host)
        #expect(before.count == StatusCardID.allCases.count)
        host.rootView = Panel(expanded: true, compact: compact, spacing: spacing, editing: editing)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        host.layoutSubtreeIfNeeded()
        #expect(frames(in: host) == before)
        for card in StatusLayout().visible {
            #expect((before[card.id]?.height ?? 0) >= card.height(compactDensity: compact) - 1)
        }
        for row in Dictionary(grouping: Array(before.values), by: \.minY).values {
            #expect(row.allSatisfy { abs($0.height - row[0].height) < 1 })
        }
    }

    private func frames(in host: NSView) -> [StatusCardID: CGRect] {
        var result: [StatusCardID: CGRect] = [:]
        var remaining = [host]
        while let view = remaining.popLast() {
            if let probe = view as? ProbeView, let frame = probe.measuredFrame {
                result[probe.card] = frame
            }
            remaining += view.subviews
        }
        return result
    }
}

@MainActor private final class GridCounts {
    var made = 0
    var measured = 0
}

/// Counts how often its content is measured.
private struct MeasureCount: Layout {
    let counts: GridCounts
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        MainActor.assumeIsolated { counts.measured += 1 }
        return subviews.first?.sizeThatFits(proposal) ?? .zero
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews { subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size)) }
    }
}

private struct CountingPanel: View {
    let counts: GridCounts
    private let cards = StatusLayout().visible
    var body: some View {
        DSPage {
            StatusGridView(cards: cards, spacing: 15) { card in
                let _ = MainActor.assumeIsolated { counts.made += 1 }
                MeasureCount(counts: counts) {
                    StatusCard(card: card.id) {
                        Text("Synthetic reading for \(card.id.title)")
                    } actions: {
                        Button("Example action") {}
                    }
                }
            }
        }
    }
}

private struct ScrollPanel: View {
    private let cards = StatusLayout().visible
    var body: some View {
        DSPage {
            StatusGridView(cards: cards, spacing: 15) { card in
                Color.clear.background(Probe(card: card.id))
            }
        }
    }
}

private struct Panel: View {
    private static let coordinateSpace = "status-card-stability"
    let expanded: Bool
    let compact: Bool
    let spacing: CGFloat
    let editing: Bool
    private let layout = StatusLayout()
    var body: some View {
        StatusGridView(cards: layout.visible, compactDensity: compact, editing: editing, spacing: spacing) { card in
                StatusCard(card: card.id, editing: editing, drag: StatusCardDrag(card: card.id, session: UUID())) {
                    if expanded {
                        ForEach(0..<30) { index in
                            Text("Synthetic reading \(index): details that wrap and change with a new sample.")
                        }
                    } else {
                        Text("No reading available right now.")
                    }
                } actions: {
                    Button("Example action") {}
                }
                .background {
                    GeometryReader { geometry in
                        Probe(card: card.id, measuredFrame: geometry.frame(in: .named(Self.coordinateSpace)))
                    }
                }
        }
        .frame(width: 720)
        .coordinateSpace(name: Self.coordinateSpace)
    }
}

private final class ProbeView: NSView {
    let card: StatusCardID
    var measuredFrame: CGRect?
    init(card: StatusCardID) {
        self.card = card
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }
}

private struct Probe: NSViewRepresentable {
    let card: StatusCardID
    var measuredFrame: CGRect? = nil
    func makeNSView(context: Context) -> ProbeView { ProbeView(card: card) }
    func updateNSView(_ view: ProbeView, context: Context) { view.measuredFrame = measuredFrame }
}
