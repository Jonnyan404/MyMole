import Darwin
import Foundation
import Testing

@testable import PrivilegedKit

/// The tool formats its texts as root, from translations in a bundle the
/// user can write: only a translation that reads the values the English
/// text reads, as the same kinds, may stand for it.
@Suite struct ToolLanguageTests {
    @Test func placeholdersAreReadByPlaceAndKind() {
        #expect(ToolLanguage.placeholders(of: "Plain text, 100%% of it.") == [:])
        #expect(ToolLanguage.placeholders(of: "Moved %lld items (%@)") == [1: "integer64", 2: "object"])
        #expect(ToolLanguage.placeholders(of: "%2$@: %1$lld") == [1: "integer64", 2: "object"])
        #expect(ToolLanguage.placeholders(of: "code %d, %5.2f seconds, %s") == [1: "integer32", 2: "double", 3: "cstring"])
        // The same value twice reads the same way; nothing else is vouched for.
        #expect(ToolLanguage.placeholders(of: "%1$lld and %1$lld") == [1: "integer64"])
        for unsafe in ["%n", "%*d", "%.*f", "%1$@ %lld", "%1$lld %1$@", "ends in %", "%y", "%65$@", "%0$@"] {
            #expect(ToolLanguage.placeholders(of: unsafe) == nil, "\(unsafe)")
        }
    }

    @Test func aTranslationStandsOnlyForATextThatReadsTheSameValues() {
        #expect(ToolLanguage.vouches(for: "Removed %lld of %@", "%2$@: %1$lld entfernt"))
        #expect(ToolLanguage.vouches(for: "The tool must run as root.", "Das Tool muss als root laufen."))
        #expect(ToolLanguage.vouches(for: "%lld%% full", "%1$lld%% voll"))
        // Another kind, another count, a value left unread, or a format that can't be read.
        for bad in ["%2$lld: %1$@", "%1$@ only", "%1$lld of %2$@ and %3$@", "%1$lld", "no values", "%1$lld of %2$@ %n", "%1$lld of %2$@ %"] {
            #expect(!ToolLanguage.vouches(for: "Removed %lld of %@", bad), "\(bad)")
        }
    }

    private static func rule(_ forms: [String: String], type: String = "lld") -> [String: Any] {
        var rule: [String: Any] = ["NSStringFormatSpecTypeKey": "NSStringPluralRuleType", "NSStringFormatValueTypeKey": type]
        forms.forEach { rule[$0.key] = $0.value }
        return rule
    }

    @Test func formsByNumberAreHeldToTheSameValues() {
        let key = "Moved %lld files (%@)"
        let good: [String: Any] = ["NSStringLocalizedFormatKey": "%1$#@count@", "count": Self.rule(["one": "%1$lld Datei (%2$@) bewegt", "other": "%1$lld Dateien (%2$@) bewegt"])]
        #expect(ToolLanguage.vouches(for: key, plural: good))
        // A form that leaves the number out is fine: the rule itself reads it.
        #expect(ToolLanguage.vouches(for: "%lld items start by themselves", plural: ["NSStringLocalizedFormatKey": "%1$#@count@", "count": Self.rule(["one": "item starts by itself", "other": "items start by themselves"])]))
        let bad: [[String: Any]] = [
            ["NSStringLocalizedFormatKey": "%1$#@count@", "count": Self.rule(["one": "%1$@ file (%2$@)", "other": "%1$lld files (%2$@)"])],
            ["NSStringLocalizedFormatKey": "%1$#@count@", "count": Self.rule(["one": "%1$lld file", "other": "%1$lld files"])],
            ["NSStringLocalizedFormatKey": "%1$#@count@", "count": Self.rule(["one": "%1$lld file (%2$@)"])],
            ["NSStringLocalizedFormatKey": "%1$#@count@", "count": Self.rule(["one": "%1$lld (%2$@)", "other": "%1$lld (%2$@)"], type: "@")],
            ["NSStringLocalizedFormatKey": "%1$#@count@ %3$@", "count": Self.rule(["one": "%1$lld (%2$@)", "other": "%1$lld (%2$@)"])],
            ["NSStringLocalizedFormatKey": "%1$#@count@", "count": Self.rule(["one": "%1$lld (%2$@)", "other": "%1$lld (%2$@) %n"])],
            ["NSStringLocalizedFormatKey": "%1$#@count@", "count": Self.rule(["one": "%1$lld (%2$@)", "other": "%1$lld (%2$@)"]), "extra": Self.rule(["other": "%3$@"])],
            ["NSStringLocalizedFormatKey": "%1$#@missing@"],
            ["NSStringLocalizedFormatKey": "%1$lld files (%2$@)"],
        ]
        for (index, entry) in bad.enumerated() { #expect(!ToolLanguage.vouches(for: key, plural: entry), "entry \(index)") }
    }

    /// The copy the tool answers from holds only what was vouched for, lies
    /// where nobody else can enter, and is gone when the request is answered.
    @Test func theToolAnswersFromACheckedCopyAndTakesItAway() throws {
        let box = try Box()
        let source = box.path + "/App/de.lproj"
        try FileManager.default.createDirectory(atPath: source, withIntermediateDirectories: true)
        let texts: [String: String] = [
            "Removed %lld of %@": "%2$@: %1$lld entfernt", "The tool must run as root.": "Das Tool muss als root laufen.",
            "Stopped after %lld seconds": "Nach %1$@ Sekunden gestoppt", "It printed %lld MB": "Es gab %1$lld MB aus %n",
        ]
        let plurals: [String: Any] = [
            "Moved %lld files": ["NSStringLocalizedFormatKey": "%1$#@count@", "count": Self.rule(["one": "%1$lld Datei bewegt", "other": "%1$lld Dateien bewegt"])],
            "Kept %lld files": ["NSStringLocalizedFormatKey": "%1$#@count@", "count": Self.rule(["one": "%1$@ Datei", "other": "%1$lld Dateien"])],
        ]
        try PropertyListSerialization.data(fromPropertyList: texts, format: .xml, options: 0).write(to: URL(fileURLWithPath: source + "/Localizable.strings"))
        try PropertyListSerialization.data(fromPropertyList: plurals, format: .xml, options: 0).write(to: URL(fileURLWithPath: source + "/Localizable.stringsdict"))
        let base = box.path + "/private"
        #expect(mkdir(base, 0o700) == 0)

        let checked = try #require(CheckedTexts(from: source, in: base))
        #expect(checked.kept == 3 && checked.dropped == 3)
        let name = "cache"
        #expect(String(localized: "Removed \(3) of \(name)", bundle: checked.bundle) == "cache: 3 entfernt")
        #expect(String(localized: "The tool must run as root.", bundle: checked.bundle) == "Das Tool muss als root laufen.")
        #expect(String(localized: "Moved \(1) files", bundle: checked.bundle) == "1 Datei bewegt")
        #expect(String(localized: "Moved \(4) files", bundle: checked.bundle) == "4 Dateien bewegt")
        // What wasn't vouched for reads as its English text.
        #expect(String(localized: "Stopped after \(9) seconds", bundle: checked.bundle) == "Stopped after 9 seconds")
        #expect(String(localized: "It printed \(32) MB", bundle: checked.bundle) == "It printed 32 MB")
        #expect(String(localized: "Kept \(1) files", bundle: checked.bundle) == "Kept 1 files")
        checked.remove()
        #expect(try FileManager.default.contentsOfDirectory(atPath: base).isEmpty)

        // No copy where others could reach it, and none of a file that isn't a catalog's.
        #expect(chmod(base, 0o755) == 0)
        #expect(CheckedTexts(from: source, in: base) == nil)
        #expect(chmod(base, 0o700) == 0)
        try Data("not a list of texts".utf8).write(to: URL(fileURLWithPath: source + "/Localizable.strings"))
        try FileManager.default.removeItem(atPath: source + "/Localizable.stringsdict")
        #expect(CheckedTexts(from: source, in: base) == nil)
        try FileManager.default.removeItem(atPath: source + "/Localizable.strings")
        try FileManager.default.createSymbolicLink(atPath: source + "/Localizable.strings", withDestinationPath: box.path + "/elsewhere")
        #expect(CheckedTexts(from: source, in: base) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: base).isEmpty)
    }

    /// Without a language to answer in, the texts are the ones compiled in.
    @Test func withoutACatalogTheToolAnswersInEnglish() {
        let seconds = 30
        let said = ToolLanguage.answering(in: ["xx"], base: nil) {
            String(localized: "Stopped after running for more than \(seconds) seconds.", bundle: ToolLanguage.bundle)
        }
        #expect(said == "Stopped after running for more than 30 seconds.")
        #expect(ToolLanguage.bundle == .main)
    }
}
