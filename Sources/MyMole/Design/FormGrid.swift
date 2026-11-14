import SwiftUI

/// A settings form: labels in a trailing-aligned column of one fixed width,
/// controls in the column beside it and help under its control. Every row
/// has the same control height and the same gap to the next, so sections
/// built from it line up with each other.
struct DSFormGrid<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One row of a `DSFormGrid`. A row without a label continues the group
/// above it, as the second checkbox under "Notifications" does. When the
/// width can't hold both columns, the label goes above its control.
struct DSFormRow<Control: View, Help: View>: View {
    var label: Phrase?
    /// Indents the help to a checkbox's title rather than its box.
    var checkbox = false
    @ViewBuilder var control: Control
    @ViewBuilder var help: Help

    var body: some View {
        FormRowLayout(labelWidth: DS.Size.formLabel, gap: DS.Space.md, stackGap: DS.Space.xs,
                      controlMinimum: DS.Size.formControlMinimum, controlHeight: DS.Size.formControlHeight) {
            Group {
                if let label {
                    label.text
                        .font(TextRole.body.font)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Color.clear.frame(width: 0, height: 0)
                }
            }
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                control
                    .frame(minHeight: DS.Size.formControlHeight, alignment: .leading)
                help
                    .font(TextRole.metadata.font)
                    .foregroundStyle(TextRole.metadata.style)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: DS.Size.formHelpWidth, alignment: .leading)
                    .padding(.leading, checkbox ? DS.Size.checkboxIndent : 0)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

extension DSFormRow {
    init(_ label: LocalizedStringResource?, checkbox: Bool = false,
         @ViewBuilder control: () -> Control, @ViewBuilder help: () -> Help) {
        self.init(label: label.map(Phrase.init), checkbox: checkbox, control: control, help: help)
    }
}

extension DSFormRow where Help == EmptyView {
    init(_ label: LocalizedStringResource?, checkbox: Bool = false, @ViewBuilder control: () -> Control) {
        self.init(label: label.map(Phrase.init), checkbox: checkbox, control: control, help: { EmptyView() })
    }
}

extension DSFormRow where Help == Text {
    /// Help that is a phrase of the interface.
    init(_ label: LocalizedStringResource?, checkbox: Bool = false, help: LocalizedStringResource,
         @ViewBuilder control: () -> Control) {
        self.init(label: label.map(Phrase.init), checkbox: checkbox, control: control, help: { Text(help) })
    }

    /// Help made elsewhere, shown as it is.
    @_disfavoredOverload
    init(_ label: LocalizedStringResource?, checkbox: Bool = false, help: String,
         @ViewBuilder control: () -> Control) {
        self.init(label: label.map(Phrase.init), checkbox: checkbox, control: control, help: { Text(verbatim: help) })
    }
}

/// A label column of a fixed width beside a control column, the label on
/// the control's first baseline; stacked when the row is too narrow. It
/// decides from the width it is offered, so a resize writes no state.
private struct FormRowLayout: Layout {
    let labelWidth: CGFloat
    let gap: CGFloat
    let stackGap: CGFloat
    let controlMinimum: CGFloat
    let controlHeight: CGFloat

    private func sideBySide(_ width: CGFloat) -> Bool { width >= labelWidth + gap + controlMinimum }

    private func width(_ proposal: ProposedViewSize) -> CGFloat {
        proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil } ?? labelWidth + gap + controlMinimum * 2
    }

    private func hasLabel(_ subviews: Subviews) -> Bool {
        subviews[0].sizeThatFits(.init(width: labelWidth, height: nil)).width > 0
    }

    /// Where the label's top sits below the row's top, and the control's.
    private func offsets(_ subviews: Subviews, label: CGSize, control: CGSize, controlWidth: CGFloat) -> (label: CGFloat, control: CGFloat) {
        let labelBaseline = subviews[0].dimensions(in: .init(width: labelWidth, height: nil))[.firstTextBaseline]
        let controlDimensions = subviews[1].dimensions(in: .init(width: controlWidth, height: nil))
        var controlBaseline = controlDimensions[.firstTextBaseline]
        // A control without text, such as a slider, reports a baseline at
        // or near its bottom: the label then centres on the control line.
        if controlBaseline >= min(controlDimensions.height - 0.5, controlHeight - 5) {
            controlBaseline = controlHeight / 2 + labelBaseline - label.height / 2
        }
        let shift = controlBaseline - labelBaseline
        return shift >= 0 ? (shift, 0) : (0, -shift)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let total = width(proposal)
        if sideBySide(total) {
            let controlWidth = total - labelWidth - gap
            let label = subviews[0].sizeThatFits(.init(width: labelWidth, height: nil))
            let control = subviews[1].sizeThatFits(.init(width: controlWidth, height: nil))
            let o = offsets(subviews, label: label, control: control, controlWidth: controlWidth)
            return CGSize(width: total, height: max(o.label + label.height, o.control + control.height))
        }
        let label = subviews[0].sizeThatFits(.init(width: total, height: nil))
        let control = subviews[1].sizeThatFits(.init(width: total, height: nil))
        let spacing = hasLabel(subviews) ? stackGap : 0
        return CGSize(width: total, height: label.height + spacing + control.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        if sideBySide(bounds.width) {
            let controlWidth = bounds.width - labelWidth - gap
            let label = subviews[0].sizeThatFits(.init(width: labelWidth, height: nil))
            let control = subviews[1].sizeThatFits(.init(width: controlWidth, height: nil))
            let o = offsets(subviews, label: label, control: control, controlWidth: controlWidth)
            subviews[0].place(at: CGPoint(x: bounds.minX + labelWidth - label.width, y: bounds.minY + o.label),
                              anchor: .topLeading, proposal: .init(width: labelWidth, height: nil))
            subviews[1].place(at: CGPoint(x: bounds.minX + labelWidth + gap, y: bounds.minY + o.control),
                              anchor: .topLeading, proposal: .init(width: controlWidth, height: nil))
            return
        }
        let label = subviews[0].sizeThatFits(.init(width: bounds.width, height: nil))
        let spacing = hasLabel(subviews) ? stackGap : 0
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: .init(width: bounds.width, height: nil))
        subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + label.height + spacing),
                          anchor: .topLeading, proposal: .init(width: bounds.width, height: nil))
    }
}
