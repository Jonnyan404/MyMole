import AppKit
import ObjectiveC

/// Help text for a view in a list, shown as its tooltip only while the
/// pointer is over it. A tooltip on every cell is a tracking rect AppKit
/// recomputes whenever the cell's frame changes, which while a list is
/// resized is every visible cell on every frame. VoiceOver reads the text
/// as the view's help either way.
private nonisolated(unsafe) var hoverHelpKey: UInt8 = 0

extension NSView {
    var hoverHelp: String? {
        get { objc_getAssociatedObject(self, &hoverHelpKey) as? String }
        set {
            guard hoverHelp != newValue else { return }
            objc_setAssociatedObject(self, &hoverHelpKey, newValue, .OBJC_ASSOCIATION_COPY_NONATOMIC)
            if accessibilityHelp() != newValue { setAccessibilityHelp(newValue) }
            // Already under the pointer: the new text shows at once.
            if toolTip != nil, toolTip != newValue { toolTip = newValue }
        }
    }
}

/// Follows the pointer over one list with a single tracking area that
/// AppKit keeps to the visible rect, and gives the view under it, and only
/// that view, its `hoverHelp` as a tooltip.
@MainActor
final class HoverHelpTracker: NSResponder {
    private weak var view: NSView?
    private weak var shown: NSView?
    private var area: NSTrackingArea?

    /// Installs the tracker on `view`; kept alive by the view.
    @discardableResult
    static func install(on view: NSView) -> HoverHelpTracker {
        if let existing = objc_getAssociatedObject(view, &trackerKey) as? HoverHelpTracker { return existing }
        let tracker = HoverHelpTracker(view: view)
        objc_setAssociatedObject(view, &trackerKey, tracker, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return tracker
    }

    private init(view: NSView) {
        self.view = view
        super.init()
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        view.addTrackingArea(area)
        self.area = area
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseMoved(with event: NSEvent) { follow(event) }
    override func mouseEntered(with event: NSEvent) { follow(event) }
    override func mouseExited(with event: NSEvent) { show(nil) }

    private func follow(_ event: NSEvent) {
        guard let view, let superview = view.superview else { return }
        var hit = view.hitTest(superview.convert(event.locationInWindow, from: nil))
        while let candidate = hit, candidate !== view, candidate.hoverHelp == nil { hit = candidate.superview }
        show(hit === view ? nil : hit)
    }

    private func show(_ next: NSView?) {
        guard next !== shown else { return }
        shown?.toolTip = nil
        next?.toolTip = next?.hoverHelp
        shown = next
    }
}

private nonisolated(unsafe) var trackerKey: UInt8 = 0
