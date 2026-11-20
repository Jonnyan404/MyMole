import Foundation
import Observation
import SwiftUI

enum ConfirmationAction: String, CaseIterable, Identifiable {
    case deepClean, installers, projects, duplicates, orphans, uninstall, reset, unverifiedMatches
    case similar, startup, ejectImage, cloudDownloads, quitApp, optimize, savedResults
    case projectWhitelist, projectBlacklist
    // What can't be undone.
    case uninstallSystem, systemClean, devTools, emptyTrash
    var id: String { rawValue }

    /// Deletes for good: there's nothing to undo or put back.
    var isPermanent: Bool { [.uninstallSystem, .systemClean, .devTools, .emptyTrash].contains(self) }

    var title: String {
        switch self {
        case .deepClean: String(localized: "Deep Clean")
        case .installers: String(localized: "Installers")
        case .projects: String(localized: "Projects")
        case .duplicates: String(localized: "Identical duplicates")
        case .orphans: String(localized: "Left by removed apps")
        case .uninstall: String(localized: "App uninstallation to the Trash")
        case .reset: String(localized: "Reset app data to the Trash")
        case .unverifiedMatches: String(localized: "Warn about unverified leftovers you chose")
        case .similar: String(localized: "Similar photos to the Trash")
        case .startup: String(localized: "Startup items to the Trash")
        case .ejectImage: String(localized: "Eject and move a disk image to the Trash")
        case .cloudDownloads: String(localized: "Remove iCloud downloads from this Mac")
        case .quitApp: String(localized: "Quit an app")
        case .optimize: String(localized: "Run maintenance tasks")
        case .uninstallSystem: String(localized: "Uninstall with system-wide parts, deleted for good")
        case .systemClean: String(localized: "Delete system items for good")
        case .devTools: String(localized: "Remove developer items for good")
        case .emptyTrash: String(localized: "Empty the Trash")
        case .savedResults: String(localized: "Clear saved scan results")
        case .projectWhitelist: String(localized: "Whitelist project folders")
        case .projectBlacklist: String(localized: "Blacklist project folders")
        }
    }
}

/// Skipping a repeated question never changes file selection or removal rules.
@MainActor @Observable
final class ConfirmationSettings {
    static let shared = ConfirmationSettings()
    static let key = "confirmations.skipped.v1"
    static let bigKey = "confirmations.askBigMoves.v1"
    /// A big move: this much or more, or this many items or more.
    static let bigBytes: Int64 = 10_000_000_000
    static let bigCount = 1_000
    private let defaults: UserDefaults
    private(set) var skipped: Set<ConfirmationAction>
    /// Asks before a big move even where the question is turned off. Off
    /// unless the user turns it on; it only ever adds a question.
    var asksBig: Bool { didSet { defaults.set(asksBig, forKey: Self.bigKey) } }
    var notice: ConfirmationAction?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        skipped = Set((defaults.stringArray(forKey: Self.key) ?? []).compactMap(ConfirmationAction.init(rawValue:)))
        asksBig = defaults.bool(forKey: Self.bigKey)
    }

    static func isBig(bytes: Int64, count: Int) -> Bool { bytes >= bigBytes || count >= bigCount }

    /// Whether to ask: the user's choice for the action, a warning that
    /// comes with it this time, and a big move when that's turned on.
    func shouldAsk(_ action: ConfirmationAction?, always: Bool = false, big: Bool = false, warning: ConfirmationAction? = nil) -> Bool {
        warns(warning) || asksOnlyBecauseBig(action, always: always, big: big) || asks(action, always: always)
    }

    /// Whether a warning that comes with the question this time is still turned on.
    func warns(_ warning: ConfirmationAction?) -> Bool { warning.map { asks($0) } ?? false }

    /// Whether the question is asked only because the move is big.
    func asksOnlyBecauseBig(_ action: ConfirmationAction?, always: Bool, big: Bool) -> Bool {
        big && asksBig && !asks(action, always: always)
    }

    func asks(_ action: ConfirmationAction?, always: Bool = false) -> Bool {
        _ = skipped // Keep the local view's observation dependency.
        let current = Set((defaults.stringArray(forKey: Self.key) ?? []).compactMap(ConfirmationAction.init(rawValue:)))
        return always || (action.map { !current.contains($0) } ?? true)
    }

    func setAsking(_ asks: Bool, for action: ConfirmationAction) {
        skipped = Set((defaults.stringArray(forKey: Self.key) ?? []).compactMap(ConfirmationAction.init(rawValue:)))
        if asks { skipped.remove(action) } else { skipped.insert(action) }
        defaults.set(skipped.map(\.rawValue).sorted(), forKey: Self.key)
    }

    func restore() {
        skipped = []
        defaults.removeObject(forKey: Self.key)
        notice = nil
    }
}

private struct ActionConfirmation: ViewModifier {
    let title: String
    @Binding var requested: Bool
    let action: ConfirmationAction?
    let always: Bool
    let big: Bool
    let warning: ConfirmationAction?
    let button: String
    let message: String
    let perform: () -> Void
    @State private var settings = ConfirmationSettings.shared

    private var warns: Bool { settings.warns(warning) }
    private var forced: Bool { !warns && settings.asksOnlyBecauseBig(action, always: always, big: big) }
    private var asks: Bool { settings.shouldAsk(action, always: always, big: big, warning: warning) }
    /// What Don't Ask Again turns off: the warning when it's shown, else the question.
    private var skippable: ConfirmationAction? { warns ? warning : always ? nil : action }

    func body(content: Content) -> some View {
        content
            .confirmationDialog(title, isPresented: Binding(
                get: { requested && asks }, set: { requested = $0 }
            ), titleVisibility: .visible) {
                Button(button, role: .destructive) { run(skip: false) }
                    .accessibilityIdentifier("confirmation.accept")
                if skippable != nil, !forced {
                    Button(String(localized: "\(button) and Don't Ask Again"), role: .destructive) { run(skip: true) }
                }
                Button("Cancel", role: .cancel) { requested = false }
                    .accessibilityIdentifier("confirmation.cancel")
            } message: {
                Text(message + (forced
                     ? "\n\n" + String(localized: "Asked because it's a big move. Settings → Confirmations → Always ask before big moves.")
                     : warns
                     ? "\n\n" + String(localized: "Don't Ask Again turns off only this warning. Turn it on again in Settings → Confirmations.")
                     : skippable != nil
                     ? "\n\n" + String(localized: "Don't Ask Again applies only to this action. Turn the question on again in Settings → Confirmations.") : ""))
            }
            .confirmationKeyboard(isPresented: Binding(get: { requested && asks }, set: { requested = $0 }))
            .onChange(of: requested, initial: true) { _, asked in
                if asked, !asks { run(skip: false) }
            }
    }

    private func run(skip: Bool) {
        requested = false
        if skip, let skippable {
            settings.setAsking(false, for: skippable)
            settings.notice = skippable
        }
        perform()
    }
}

extension View {
    func actionConfirmation(
        _ title: String, isPresented: Binding<Bool>, action: ConfirmationAction? = nil,
        always: Bool = false, big: Bool = false, warning: ConfirmationAction? = nil,
        button: String = String(localized: "Move to Trash"), message: String,
        perform: @escaping () -> Void
    ) -> some View {
        modifier(ActionConfirmation(title: title, requested: isPresented, action: action, always: always, big: big,
                                    warning: warning, button: button, message: message, perform: perform))
    }
}

/// Global feedback survives the sheet that just accepted the user's choice.
struct ConfirmationToast: View {
    @State private var settings = ConfirmationSettings.shared
    let openSettings: () -> Void

    var body: some View {
        if let action = settings.notice {
            HStack(spacing: DS.Space.md) {
                Image(systemName: "checkmark.circle")
                Text("Confirmation turned off for \(action.title). Turn it on again in Settings → Confirmations.")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Settings") { settings.notice = nil; openSettings() }
                Button { settings.notice = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Dismiss")
            }
            .padding(DS.Space.md)
            .frame(maxWidth: 680)
            .background(.regularMaterial, in: .rect(cornerRadius: DS.Radius.card))
            .shadow(radius: 8, y: 2)
            .padding(DS.Space.lg)
            .task(id: action) {
                try? await Task.sleep(for: .seconds(8))
                if !Task.isCancelled, settings.notice == action { settings.notice = nil }
            }
        }
    }
}

struct ConfirmationsSection: View {
    @State private var settings = ConfirmationSettings.shared
    var projectRules: ConfirmationSettings? = nil

    /// Each group's first row says what the group is.
    private func label(_ action: ConfirmationAction) -> LocalizedStringResource? {
        let all = ConfirmationAction.allCases
        if action == all.first { return "Ask before" }
        if action == all.first(where: \.isPermanent) { return "Ask before, can't be undone" }
        return nil
    }

    private func owner(_ action: ConfirmationAction) -> ConfirmationSettings {
        (action == .projectWhitelist || action == .projectBlacklist) ? (projectRules ?? settings) : settings
    }

    var body: some View {
        DSSection("Confirmations", footer: "Turning a question off applies only to that action. Your choices, Keep rules and all file checks still apply. Uninstalling MyMole always asks.", rows: false) {
            DSFormGrid {
                ForEach(ConfirmationAction.allCases) { action in
                    DSFormRow(label(action), checkbox: true) {
                        Toggle(action.title, isOn: Binding(get: { owner(action).asks(action) }, set: { owner(action).setAsking($0, for: action) }))
                    } help: {
                        if !owner(action).asks(action) {
                            Text("Question turned off; turn this on to ask again")
                        }
                    }
                }
                DSFormRow(nil, checkbox: true) {
                    Toggle("Always ask before big moves", isOn: Binding(get: { settings.asksBig }, set: { settings.asksBig = $0 }))
                } help: {
                    Text("Over 10 GB or 1,000 items, even where the question is turned off. Adds a question; never removes one.")
                }
                DSFormRow(nil) {
                    Button("Restore All Confirmations") { settings.restore(); projectRules?.restore() }
                        .disabled(settings.skipped.isEmpty && (projectRules?.skipped.isEmpty ?? true))
                }
            }
        }
    }
}
