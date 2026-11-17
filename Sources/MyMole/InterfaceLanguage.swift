import AppKit
import Foundation

/// The language the interface is drawn in.
///
/// A bundle's localization is settled once, when the process starts: `Bundle.main`
/// reads the `AppleLanguages` default, picks the first localization it ships for it,
/// and every `String(localized:)` and `Text("…")` in the app resolves against that.
/// Nothing supported changes it for a process that is already running, so a choice
/// made here is written to MyMole's defaults and applied by the next launch. This is
/// the same mechanism the per-app language in System Settings uses, which keeps the
/// two in step: picking a language here moves that entry, and picking one there is
/// what the app starts with when this choice is `system`.
enum InterfaceLanguage {
    /// What the reader picked, `system` when the choice is left to macOS.
    static let defaultsKey = "interfaceLanguage"
    static let system = "system"

    /// macOS's own key for a bundle's language. CFBundle consults it at launch.
    private static let appleLanguagesKey = "AppleLanguages"

    /// The language a choice names, for lists and messages.
    struct Option: Identifiable, Hashable {
        let id: String
        /// Named in the language itself, so the list reads the same whichever
        /// language is on screen.
        let name: String
    }

    /// Every language the bundle ships. A new translation adds a `.lproj` to the
    /// app and an entry to the catalog; it appears here with no code to change.
    static var options: [Option] {
        // A bundle can name a language twice — once as a `.lproj` folder, once in
        // CFBundleLocalizations — and `localizations` then lists it twice.
        Set(Bundle.main.localizations)
            .filter { $0 != "Base" }
            .map { code in Option(id: code, name: name(of: code)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The language named in itself, e.g. "English" or "中文（简体）".
    static func name(of code: String) -> String {
        let locale = Locale(identifier: code)
        return locale.localizedString(forIdentifier: code) ?? code
    }

    /// The stored choice, so this page shows what was picked rather than what
    /// macOS has already applied.
    static var choice: String {
        UserDefaults.standard.string(forKey: defaultsKey) ?? system
    }

    /// What the interface is showing now, whichever way it was chosen.
    static var running: String {
        Bundle.main.preferredLocalizations.first ?? "en"
    }

    /// The language the stored choice asks for, following macOS when the choice
    /// is `system` — which is also what that choice has to be told apart by.
    static var target: String {
        choice == system ? systemLanguage : choice
    }

    /// What macOS would settle on with no choice of ours in its way.
    private static var systemLanguage: String {
        guard let wanted = UserDefaults.standard.stringArray(forKey: appleLanguagesKey), !wanted.isEmpty else {
            return running
        }
        return Bundle.preferredLocalizations(from: Bundle.main.localizations, forPreferences: wanted).first ?? running
    }

    /// Whether the choice has not been taken up by the running process, either
    /// because it names another language or because it hands the decision back
    /// to macOS, which had been overruled.
    static var awaitingRestart: Bool {
        target != running
    }

    /// Records the choice and tells macOS to apply it the next time MyMole opens.
    static func choose(_ identifier: String) {
        let defaults = UserDefaults.standard
        defaults.set(identifier, forKey: defaultsKey)
        if identifier == system {
            // No key of its own: the system-wide languages, or a per-app choice
            // made in System Settings, decide again.
            defaults.removeObject(forKey: appleLanguagesKey)
        } else {
            defaults.set([identifier], forKey: appleLanguagesKey)
        }
    }

    /// A build directory has no app bundle to open again.
    static var canRelaunch: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Starts a second copy, which reads the new default, then quits this one.
    static func relaunch() {
        guard canRelaunch else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            Task { @MainActor in NSApplication.shared.terminate(nil) }
        }
    }
}
