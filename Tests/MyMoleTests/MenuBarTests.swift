import Foundation
import Testing

@testable import MyMole

@Suite struct MenuBarTests {
    @Test func freeSpaceIsShortEnoughForAMenuBar() {
        // Whole gigabytes from ten up, one decimal below, the smaller units as everywhere else.
        #expect(MenuBarText.free(103_120_000_000).filter(\.isNumber) == "103")
        let english = Locale(identifier: "en_US"), french = Locale(identifier: "fr_FR")
        #expect(MenuBarText.free(103_120_000_000, locale: english) == "103 GB" && MenuBarText.free(8_440_000_000, locale: english) == "8.4 GB")
        // The unit is the language's own, as in the sizes everywhere else.
        #expect(MenuBarText.free(103_120_000_000, locale: french).hasSuffix("Go") && MenuBarText.free(8_440_000_000, locale: french).hasPrefix("8,4"))
        #expect(MenuBarText.free(8_440_000_000).filter(\.isNumber) == "84")
        #expect(MenuBarText.free(1_000_000_000).filter(\.isNumber) == "10")
        #expect(MenuBarText.free(512_000_000).contains("MB"))
        #expect(MenuBarText.free(0).filter(\.isNumber).allSatisfy { $0 == "0" })
    }

    @Test func theIconWarnsOnlyWhenTheDiskIsNearlyFull() {
        #expect(MenuBarText.symbol(usedPercent: nil) == "internaldrive")
        #expect(MenuBarText.symbol(usedPercent: 89.9) == "internaldrive")
        #expect(MenuBarText.symbol(usedPercent: 90) != "internaldrive")
    }
}

@Suite struct MenuBarQuestionTests {
    private func defaults() -> UserDefaults {
        testDefaults(in: FileManager.default.temporaryDirectory.appending(path: "mymole-menubar-\(UUID().uuidString)"))
    }

    @Test func theFirstStartAsksOnceAnsweredOrNot() {
        let d = defaults()
        #expect(MenuBarSettings.shouldAsk(in: d) == MenuBarSettings.showStandard)
        MenuBarSettings.markAsked(in: d)
        #expect(!MenuBarSettings.shouldAsk(in: d))
    }

    @Test func aChoiceMadeInSettingsIsNotAskedAbout() {
        for choice in [true, false] {
            let d = defaults()
            d.set(choice, forKey: MenuBarSettings.showKey)
            #expect(!MenuBarSettings.shouldAsk(in: d))
        }
    }
}
