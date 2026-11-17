// macOS 14 stand-in for `Group(subviews:transform:)`, which is macOS 15 only.
//
// That initialiser hands a ViewBuilder's children back one by one so each can
// be styled as a row — the row separators and padding in DSRows and
// DSFilterBody depend on it. SwiftUI implements it on _VariadicView, which has
// been present since the first release, so the same mechanism is used here.
// Being an underscore API it is not covered by Apple's compatibility promise;
// if it ever stops working the fallback is to have these containers take an
// explicit array of rows instead.
import SwiftUI

/// The children of a ViewBuilder, in order.
typealias SubviewsCollection = _VariadicView.Children

/// Reads a ViewBuilder's children and transforms them as a group.
struct SubviewsGroup<Content: View, Result: View>: View {
    private let content: Content
    private let transform: (SubviewsCollection) -> Result

    init(_ content: Content, @ViewBuilder transform: @escaping (SubviewsCollection) -> Result) {
        self.content = content
        self.transform = transform
    }

    var body: some View {
        _VariadicView.Tree(SubviewsRoot(transform: transform)) {
            content
        }
    }
}

private struct SubviewsRoot<Result: View>: _VariadicView_MultiViewRoot {
    let transform: (SubviewsCollection) -> Result

    func body(children: SubviewsCollection) -> Result {
        transform(children)
    }
}
