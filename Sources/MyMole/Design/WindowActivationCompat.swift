// macOS 14 stand-in for `allowsWindowActivationEvents()`, which is macOS 15.
//
// On macOS 15 the modifier lets a control react to clicks without bringing its
// window forward — the status cards use it so reading a card does not activate
// the menu-bar panel. macOS 14 has no equivalent: the calls compile and keep
// their layout, but a click activates the window as usual.
import SwiftUI

extension View {
    func allowsWindowActivationEventsCompat() -> some View {
        self
    }
}
