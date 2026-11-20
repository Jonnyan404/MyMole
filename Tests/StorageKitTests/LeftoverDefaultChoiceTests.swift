import Foundation
import Testing

@testable import StorageKit

/// Which leftovers start chosen, by how they're tied to the app and what
/// they hold. Synthetic folders of the test's own; nothing is moved.
@Suite struct LeftoverDefaultChoiceTests {
    let editor = AppBundle(
        path: "/synthetic/Applications/Editor.app", name: "Editor", bundleID: "com.vendor.Editor", version: nil, bytes: 1,
        fromAppStore: false)

    private func relative(_ found: [Leftover], in box: Sandbox) -> [String: Leftover] {
        Dictionary(uniqueKeysWithValues: found.map { (String($0.path.dropFirst(box.path.count + 1)), $0) })
    }

    @Test func anExactTieStartsChosenInEveryPlace() throws {
        let box = try Sandbox()
        let places = [
            "Library/Caches/com.vendor.Editor", "Library/Logs/com.vendor.Editor",
            "Library/Application Support/com.vendor.Editor", "Library/Containers/com.vendor.Editor",
            "Library/Group Containers/ABCDE12345.com.vendor.Editor", "Library/Preferences/com.vendor.Editor.plist",
            "Library/Preferences/ByHost/com.vendor.Editor.0A1B.plist", "Library/Saved Application State/com.vendor.Editor.savedState",
            "Library/HTTPStorages/com.vendor.Editor", "Library/WebKit/com.vendor.Editor",
            "Library/Cookies/com.vendor.Editor.binarycookies", "Library/LaunchAgents/com.vendor.Editor.agent.plist",
            "Library/Application Scripts/com.vendor.Editor", "Library/Caches/com.vendor.Editor.Helper",
        ]
        for place in places {
            try box.file(place.hasSuffix(".plist") || place.hasSuffix(".binarycookies") ? place : place + "/x", bytes: 500)
        }
        let identity = AppIdentity(helperIDs: ["com.vendor.Editor.Helper"], groups: ["ABCDE12345.com.vendor.Editor"])
        let by = relative(AppLeftovers.find(for: editor, home: box.path, installed: [editor], identity: identity), in: box)
        #expect(Set(by.keys) == Set(places))
        for (path, item) in by {
            #expect(item.chosenByDefault && item.review == nil, "\(path) is certainly the app's")
            #expect([.bundleID, .helper, .group].contains(item.evidence))
        }
        #expect(by["Library/Caches/com.vendor.Editor.Helper"]?.evidence == .helper)
        #expect(by["Library/Group Containers/ABCDE12345.com.vendor.Editor"]?.evidence == .group)
    }

    @Test func uncertainTiesStartUnchosenWithTheirReason() throws {
        let box = try Sandbox()
        for rel in [
            "Library/Application Support/Editor/db", "Library/Application Support/Vendor/Editor/profile",
            "Library/Caches/Vendor/Editor/c", "Library/LaunchAgents/com.vendor.updater.plist",
            "Library/Application Support/EditorSync/x",
        ] {
            try box.file(rel, bytes: 500)
        }
        let by = relative(AppLeftovers.find(for: editor, home: box.path, installed: [editor], deep: true), in: box)
        #expect(by["Library/Application Support/Editor"]?.review == .nameOnly)
        #expect(by["Library/Application Support/Vendor/Editor"]?.review == .nameInMakerFolder)
        #expect(by["Library/LaunchAgents/com.vendor.updater.plist"]?.review == .maker)
        #expect(by["Library/Application Support/EditorSync"]?.review == .looseMatch)
        // A cache in the maker's folder is rebuilt, so its name is enough.
        #expect(by["Library/Caches/Vendor/Editor"]?.chosenByDefault == true)
        for item in by.values where item.review != nil { #expect(!item.chosenByDefault) }
    }

    @Test func unverifiedOwnershipNeverStartsChosen() {
        var item = Leftover(path: "/synthetic/Library/Caches/com.vendor.Editor", bytes: 1, place: "Caches")
        #expect(item.chosenByDefault)
        item.evidence = .unverified
        #expect(!item.chosenByDefault && item.review == .unverified)
    }

    @Test func foldersThatLookLikeTheUsersWorkStartUnchosen() throws {
        let box = try Sandbox()
        try box.file("Library/Containers/com.vendor.Editor/Data/Documents/Draft.txt", bytes: 500)
        try box.file("Library/Application Support/com.vendor.Editor/Repo/.git/HEAD", bytes: 100)
        try box.file("Library/WebKit/com.vendor.Editor/Report.pdf", bytes: 2_000_000)
        try box.file("Library/HTTPStorages/com.vendor.Editor/Letter.pages/Index.zip", bytes: 500)
        // An empty Documents folder holds no work.
        try box.folder("Library/Saved Application State/com.vendor.Editor.savedState/Documents")
        try box.file("Library/Saved Application State/com.vendor.Editor.savedState/windows.plist", bytes: 100)
        // Caches are rebuilt whatever they hold.
        try box.file("Library/Caches/com.vendor.Editor/Documents/preview.pdf", bytes: 2_000_000)
        let by = relative(AppLeftovers.find(for: editor, home: box.path, installed: [editor]), in: box)
        for path in [
            "Library/Containers/com.vendor.Editor", "Library/Application Support/com.vendor.Editor",
            "Library/WebKit/com.vendor.Editor", "Library/HTTPStorages/com.vendor.Editor",
        ] {
            #expect(by[path]?.evidence == .bundleID && by[path]?.review == .userWork, "\(path) looks like the user's work")
        }
        #expect(by["Library/Saved Application State/com.vendor.Editor.savedState"]?.chosenByDefault == true)
        #expect(by["Library/Caches/com.vendor.Editor"]?.chosenByDefault == true)
    }

    @Test func runtimeCachesStartChosenAndTemporaryDataDoesNot() throws {
        let box = try Sandbox()
        try box.file("Runtime/C/com.vendor.Editor/shader", bytes: 500)
        try box.file("Runtime/T/com.vendor.Editor/draft", bytes: 500)
        let roots = [
            RuntimeLeftovers.Root(path: box.path + "/Runtime/C", kind: .caches),
            RuntimeLeftovers.Root(path: box.path + "/Runtime/T", kind: .temporary),
        ]
        let by = relative(AppLeftovers.find(for: editor, home: box.path, installed: [editor], deep: true, runtimeRoots: roots), in: box)
        let caches = try #require(by["Runtime/C/com.vendor.Editor"])
        let temporary = try #require(by["Runtime/T/com.vendor.Editor"])
        #expect(caches.evidence == .runtimeID && caches.kind == .rebuildable && caches.chosenByDefault)
        #expect(temporary.evidence == .runtimeID && temporary.kind == .data && temporary.review == .temporary)
    }

    @Test func aMacOSAppsResetChoosesOnlyWhatItRebuilds() throws {
        let box = try Sandbox()
        try box.file("Library/Caches/com.apple.Safari/c", bytes: 500)
        try box.file("Library/Preferences/com.apple.Safari.plist", bytes: 500)
        let safari = AppBundle(path: "/Applications/Safari.app", name: "Safari", bundleID: "com.apple.Safari", version: nil, bytes: 1, fromAppStore: false)
        let by = relative(AppLeftovers.find(for: safari, home: box.path, installed: [safari]), in: box)
        #expect(by["Library/Caches/com.apple.Safari"]?.chosenByDefault == true)
        #expect(by["Library/Preferences/com.apple.Safari.plist"]?.review == .macOSApp)
    }

    @Test func everyReasonHasItsOwnPhrase() {
        let titles = Leftover.Review.allCases.map(\.title)
        #expect(Set(titles).count == titles.count && titles.allSatisfy { !$0.isEmpty })
        let chosen = Leftover(path: "/synthetic/Library/Caches/com.vendor.Editor", bytes: 1, place: "Caches")
        #expect(!titles.contains(chosen.choiceTitle))
    }
}
