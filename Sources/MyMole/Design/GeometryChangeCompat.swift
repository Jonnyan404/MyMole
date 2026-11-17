// macOS 14 stand-in for SwiftUI's onGeometryChange(for:_:action:), which
// arrived in macOS 15. Call sites use onGeometryChangeCompat instead so the
// replacement is explicit rather than shadowing a SwiftUI symbol.
import SwiftUI

extension View {
    /// Reports a value derived from this view's geometry, every time it changes.
    func onGeometryChangeCompat<T: Equatable & Sendable>(
        for type: T.Type,
        _ transform: @escaping (GeometryProxy) -> T,
        action: @escaping (T) -> Void
    ) -> some View {
        modifier(GeometryChangeCompatModifier(transform: transform, action: action))
    }
}

private struct GeometryChangeCompatKey<T: Equatable & Sendable>: PreferenceKey {
    static var defaultValue: T? { nil }

    static func reduce(value: inout T?, nextValue: () -> T?) {
        if let next = nextValue() { value = next }
    }
}

private struct GeometryChangeCompatModifier<T: Equatable & Sendable>: ViewModifier {
    let transform: (GeometryProxy) -> T
    let action: (T) -> Void

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .preference(key: GeometryChangeCompatKey<T>.self, value: transform(proxy))
                }
            )
            .onPreferenceChange(GeometryChangeCompatKey<T>.self) { value in
                guard let value else { return }
                // onPreferenceChange's closure is @Sendable; it runs during
                // layout on the main thread, which is where the call sites'
                // state lives.
                MainActor.assumeIsolated { action(value) }
            }
    }
}
