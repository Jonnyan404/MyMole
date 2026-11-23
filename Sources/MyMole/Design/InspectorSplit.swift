import AppKit
import SwiftUI

struct InspectorSplit<Content: View, Inspector: View>: NSViewControllerRepresentable {
    @ViewBuilder var content: () -> Content
    @ViewBuilder var inspector: () -> Inspector

    func makeNSViewController(context: Context) -> InspectorSplitController {
        InspectorSplitController(content: AnyView(content().environment(\.self, context.environment)),
                                 inspector: AnyView(inspector().environment(\.self, context.environment)))
    }

    func updateNSViewController(_ controller: InspectorSplitController, context: Context) {
        controller.content.rootView = AnyView(content().environment(\.self, context.environment))
        controller.inspector.rootView = AnyView(inspector().environment(\.self, context.environment))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: InspectorSplitController, context: Context) -> CGSize? {
        CGSize(width: proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil } ?? 1_000,
               height: proposal.height.flatMap { $0.isFinite ? max(0, $0) : nil } ?? 600)
    }
}

final class InspectorSplitController: NSViewController, NSSplitViewDelegate {
    let splitView = NSSplitView()
    let content: NSHostingController<AnyView>
    let inspector: NSHostingController<AnyView>
    private var inspectorWidth: CGFloat = 440
    private var arranging = false

    /// The narrowest each pane may be. The inspector may take the rest.
    static let minContent: CGFloat = 380
    static let minInspector: CGFloat = 340

    init(content: AnyView, inspector: AnyView) {
        self.content = NSHostingController(rootView: content)
        self.inspector = NSHostingController(rootView: inspector)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() { view = splitView }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        // The split owns its frames. SwiftUI intrinsic sizing
        // would otherwise remeasure both entire panes during every drag.
        content.sizingOptions = []
        inspector.sizingOptions = []
        addChild(content)
        addChild(inspector)
        splitView.addSubview(content.view)
        splitView.addSubview(inspector.view)
    }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        arranging = true
        defer { arranging = false }
        let divider = min(splitView.dividerThickness, splitView.bounds.width)
        let available = max(0, splitView.bounds.width - divider)
        let width = min(available, inspectorWidth, max(Self.minInspector, available - Self.minContent))
        let main = available - width
        content.view.frame = NSRect(x: 0, y: 0, width: main, height: splitView.bounds.height)
        inspector.view.frame = NSRect(x: main + divider, y: 0,
                                      width: width, height: splitView.bounds.height)
    }

    func splitView(_ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        let available = splitView.bounds.width - splitView.dividerThickness
        let position = min(max(Self.minContent, available - Self.minInspector), max(Self.minContent, proposedPosition))
        if !arranging { inspectorWidth = max(Self.minInspector, available - position) }
        return position
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        Self.minContent
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(Self.minContent, splitView.bounds.width - splitView.dividerThickness - Self.minInspector)
    }
}
