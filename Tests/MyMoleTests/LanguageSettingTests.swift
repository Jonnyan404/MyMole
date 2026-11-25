import Foundation
import Testing

@testable import MyMole

@Suite struct LanguageSettingTests {
    /// Choosing a language stores it as the app's own AppleLanguages, and
    /// following the Mac again removes it, so the system's choice applies.
    @Test func aChosenLanguageIsTheAppsOwnAndFollowingTheMacRemovesIt() {
        var stored: [String]?? = .none
        LanguageSetting.choose("fr") { stored = .some($0) }
        #expect(stored == .some(["fr"]))
        LanguageSetting.choose(nil) { stored = .some($0) }
        #expect(stored == .some(nil))

        #expect(LanguageSetting.chosen(in: [LanguageSetting.key: ["de", "en"]]) == "de")
        #expect(LanguageSetting.chosen(in: [:]) == nil)
        #expect(LanguageSetting.chosen(in: nil) == nil)
    }

    @Test func eachLanguageIsNamedInItself() {
        #expect(LanguageSetting.name(of: "fr") == "Français")
        #expect(LanguageSetting.name(of: "de") == "Deutsch")
        #expect(LanguageSetting.name(of: "en") == "English")
        #expect(LanguageSetting.name(of: "pt-BR") == "Português (Brasil)")
        #expect(LanguageSetting.name(of: "zh-Hans") == "简体中文")
        #expect(LanguageSetting.name(of: "zh-Hant") == "繁體中文")
        #expect(LanguageSetting.name(of: "ja") == "日本語")
        #expect(LanguageSetting.name(of: "sv") == "Svenska")
    }
}
