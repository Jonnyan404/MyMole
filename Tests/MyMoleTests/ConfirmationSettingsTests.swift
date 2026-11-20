import Foundation
import Testing

@testable import MyMole

@MainActor @Suite struct ConfirmationSettingsTests {
    @Test func separateRuleAndCleanupControlsPreserveEachOthersPreferences() {
        let root = FileManager.default.temporaryDirectory.appending(path: "confirmations-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = testDefaults(in: root)
        let cleanup = ConfirmationSettings(defaults: defaults)
        let rules = ConfirmationSettings(defaults: defaults)
        cleanup.setAsking(false, for: .projects)
        rules.setAsking(false, for: .projectWhitelist)
        #expect(!cleanup.asks(.projects) && !cleanup.asks(.projectWhitelist))
        #expect(!rules.asks(.projects) && !rules.asks(.projectWhitelist))
        rules.setAsking(true, for: .projectWhitelist)
        #expect(!cleanup.asks(.projects) && cleanup.asks(.projectWhitelist))
    }
    @Test func skippingAQuestionIsScopedPersistentAndRestorable() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "confirmations-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = testDefaults(in: root)
        let settings = ConfirmationSettings(defaults: defaults)
        #expect(ConfirmationAction.allCases.allSatisfy { settings.asks($0) })
        settings.setAsking(false, for: .installers)
        #expect(!settings.asks(.installers))
        #expect(settings.asks(.projects))
        let restored = ConfirmationSettings(defaults: defaults)
        #expect(!restored.asks(.installers))
        restored.setAsking(true, for: .installers)
        #expect(restored.asks(.installers))
        restored.setAsking(false, for: .duplicates)
        restored.restore()
        #expect(restored.skipped.isEmpty)
        #expect(ConfirmationSettings(defaults: defaults).skipped.isEmpty)
    }

    @Test func bigMovesAskAgainOnlyWhenTurnedOnAndNeverAskLess() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "confirmations-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = testDefaults(in: root)
        let settings = ConfirmationSettings(defaults: defaults)
        #expect(!settings.asksBig)
        #expect(ConfirmationSettings.isBig(bytes: 10_000_000_000, count: 1) && ConfirmationSettings.isBig(bytes: 0, count: 1_000))
        #expect(!ConfirmationSettings.isBig(bytes: 9_999_999_999, count: 999))
        settings.setAsking(false, for: .deepClean)
        // Off: a skipped question stays skipped, big or not.
        #expect(!settings.asksOnlyBecauseBig(.deepClean, always: false, big: true))
        settings.asksBig = true
        #expect(ConfirmationSettings(defaults: defaults).asksBig)
        // On: a big move asks again; a small one stays as the user chose.
        #expect(settings.asksOnlyBecauseBig(.deepClean, always: false, big: true))
        #expect(!settings.asksOnlyBecauseBig(.deepClean, always: false, big: false))
        // A question that's asked anyway isn't said to be asked for its size.
        #expect(!settings.asksOnlyBecauseBig(.projects, always: false, big: true))
        #expect(!settings.asksOnlyBecauseBig(.deepClean, always: true, big: true))
        // Restoring the skipped questions leaves the extra one as it is.
        settings.restore()
        #expect(settings.asksBig && settings.asks(.deepClean))
    }

    @Test func everyRepeatedQuestionCanBeSkippedButSelfRemovalCannot() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "confirmations-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = testDefaults(in: root)
        defaults.set(ConfirmationAction.allCases.map(\.rawValue) + ["selfRemoval", "unknown"], forKey: ConfirmationSettings.key)
        let settings = ConfirmationSettings(defaults: defaults)
        #expect(settings.skipped.count == ConfirmationAction.allCases.count)
        // Uninstalling MyMole has no action to skip.
        #expect(settings.asks(nil))
        // The warning about unverified matches can be turned off too.
        #expect(!settings.shouldAsk(.reset, warning: .unverifiedMatches))
        // What can't be undone can be skipped too, each on its own.
        let permanent = ConfirmationAction.allCases.filter(\.isPermanent)
        #expect(Set(permanent) == [.uninstallSystem, .systemClean, .devTools, .emptyTrash])
        #expect(permanent.allSatisfy { !settings.shouldAsk($0) })
        settings.setAsking(true, for: .emptyTrash)
        #expect(settings.shouldAsk(.emptyTrash) && !settings.shouldAsk(.systemClean))
        // The question about a big move comes back when that's turned on, permanent or not.
        settings.asksBig = true
        #expect(settings.shouldAsk(.systemClean, big: true) && !settings.shouldAsk(.systemClean, big: false))
    }

    @Test func unverifiedMatchesWarnUntilTurnedOffWhateverTheQuestion() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "confirmations-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = ConfirmationSettings(defaults: testDefaults(in: root))
        // On from the start, and it asks even where the question itself is off.
        settings.setAsking(false, for: .reset)
        #expect(settings.warns(.unverifiedMatches))
        #expect(settings.shouldAsk(.reset, warning: .unverifiedMatches))
        #expect(!settings.shouldAsk(.reset))
        // Turned off, it leaves the question to its own choice.
        settings.setAsking(false, for: .unverifiedMatches)
        #expect(!settings.shouldAsk(.reset, warning: .unverifiedMatches))
        settings.setAsking(true, for: .reset)
        #expect(settings.shouldAsk(.reset, warning: .unverifiedMatches))
        // And Settings brings it back.
        settings.restore()
        #expect(settings.warns(.unverifiedMatches))
        #expect(!settings.warns(nil))
    }
}
