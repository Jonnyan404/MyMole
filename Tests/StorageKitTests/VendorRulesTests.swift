import Foundation
import Testing

@testable import StorageKit

/// Bills of materials made by macOS's own `mkbom` from synthetic file lists,
/// stored compressed. "big" holds 700 entries, so its path tree has branches.
enum ReceiptFixture {
    static func bom(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "Receipts", withExtension: "json"))
        let all = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        let text = try #require(all[name])
        let packed = try #require(Data(base64Encoded: text))
        return try (packed as NSData).decompressed(using: .zlib) as Data
    }

    /// A record of `id` under `box`, installing at `location`.
    static func install(_ name: String, id: String, location: String, in box: Sandbox) throws {
        try box.folder("private/var/db/receipts")
        let dir = box.url.appending(path: "private/var/db/receipts")
        try bom(name).write(to: dir.appending(path: id + ".bom"))
        try PropertyListSerialization.data(fromPropertyList: ["PackageIdentifier": id, "InstallPrefixPath": location],
                                           format: .xml, options: 0).write(to: dir.appending(path: id + ".plist"))
    }
}

@Suite struct InstallerReceiptsTests {
    @Test func readsEveryPathOfABillOfMaterials() throws {
        #expect(BOM.paths(data: try ReceiptFixture.bom("single")) == [
            ".", "./Fixture Tool.app", "./Fixture Tool.app/Contents", "./Fixture Tool.app/Contents/Info.plist",
        ])
        let big = try #require(BOM.paths(data: try ReceiptFixture.bom("big")))
        #expect(big.count == 702)
        #expect(big.last == "./Fixture Tool.app/f700")
        #expect(Set(big).count == 702)
    }

    @Test func malformedOrOversizedListsAreUnknown() throws {
        var data = try ReceiptFixture.bom("single")
        #expect(BOM.paths(data: data, limit: 3) == nil)
        data[0] = 0x41
        #expect(BOM.paths(data: data) == nil)
        #expect(BOM.paths(data: Data("BOMStore".utf8)) == nil)
        let truncated = try ReceiptFixture.bom("big").prefix(9_000)
        #expect(BOM.paths(data: Data(truncated)) == nil)
    }

    @Test func aRecordTiesOnlyToTheOneAppItInstalled() throws {
        let box = try Sandbox()
        try ReceiptFixture.install("single", id: "com.vendor.pkg.tool", location: "Applications", in: box)
        try ReceiptFixture.install("twoapps", id: "com.vendor.pkg.suite", location: "Applications", in: box)
        try ReceiptFixture.install("combo", id: "com.vendor.pkg.combo", location: "/", in: box)
        try ReceiptFixture.install("single", id: "com.apple.pkg.Thing", location: "Applications", in: box)

        let tool = try #require(InstallerReceipts.receipt("com.vendor.pkg.tool", base: box.path))
        #expect(tool.location == "Applications")
        #expect(InstallerReceipts.installsOnly(tool, app: "/Applications/Fixture Tool.app"))
        #expect(InstallerReceipts.installsOnly(tool, app: "/applications/fixture tool.app"))
        #expect(!InstallerReceipts.installsOnly(tool, app: "/Applications/Fixture Other.app"))
        #expect(!InstallerReceipts.installsOnly(tool, app: "/Users/synthetic/Applications/Fixture Tool.app"))

        // A suite's record names two apps: neither may claim it alone.
        let suite = try #require(InstallerReceipts.receipt("com.vendor.pkg.suite", base: box.path))
        #expect(!InstallerReceipts.installsOnly(suite, app: "/Applications/Fixture Tool.app"))

        let combo = try #require(InstallerReceipts.receipt("com.vendor.pkg.combo", base: box.path))
        #expect(combo.location == "")
        #expect(InstallerReceipts.installsOnly(combo, app: "/Applications/Fixture Tool.app"))
        #expect(InstallerReceipts.installed(combo)?.contains("/Library/Audio/Plug-Ins/HAL/FixtureAudio.driver") == true)

        // Apple's records are the system's and never read.
        #expect(InstallerReceipts.receipt("com.apple.pkg.Thing", base: box.path) == nil)
        #expect(InstallerReceipts.all(base: box.path)?.map(\.id) == ["com.vendor.pkg.combo", "com.vendor.pkg.suite", "com.vendor.pkg.tool"])
    }

    @Test func aRecordBehindALinkIsNotRead() throws {
        let box = try Sandbox()
        try ReceiptFixture.install("single", id: "com.vendor.pkg.tool", location: "Applications", in: box)
        let dir = box.path + "/private/var/db/receipts"
        try FileManager.default.moveItem(atPath: dir + "/com.vendor.pkg.tool.bom", toPath: box.path + "/elsewhere.bom")
        try FileManager.default.createSymbolicLink(atPath: dir + "/com.vendor.pkg.tool.bom", withDestinationPath: box.path + "/elsewhere.bom")
        #expect(InstallerReceipts.receipt("com.vendor.pkg.tool", base: box.path) == nil)
    }
}

@Suite struct VendorRulesTests {
    let home = "/Users/synthetic"

    @Test func noOfferedPartIsTheUsersFilesOrWhatAFamilyShares() {
        for rule in VendorRules.rules {
            for part in rule.parts where part.handling == .offer {
                let path = part.resolved(home: home)
                #expect(!VendorRules.isNever(path, home: home), "\(rule.vendor): \(part.path)")
                #expect(part.path.hasPrefix("/") || part.path.hasPrefix("~/"), "\(rule.vendor): \(part.path)")
                #expect(!part.path.contains("*") && !part.path.contains(".."), "\(rule.vendor): \(part.path)")
            }
        }
        // The examples users lose data to when a cleaner zaps by a list.
        for never in ["~/Documents/Zoom", "~/Desktop/Zoom", "~/Dropbox", "~/Library/CloudStorage/Dropbox", "~/Creative Cloud Files",
                      "~/Library/Application Support/Microsoft", "~/Library/Group Containers/UBF8T346G9.Office", "~/Parallels",
                      "/Library/Extensions/LittleSnitch.kext", "/Library/Audio/Plug-Ins/Components/Synth.component"] {
            #expect(VendorRules.isNever(never.hasPrefix("~/") ? home + never.dropFirst(1) : never, home: home), "\(never)")
        }
        // What every user shares is only ever shown.
        let games = VendorRules.parts(for: "com.epicgames.epicgameslauncher")
        #expect(!games.isEmpty && games.allSatisfy { $0.handling == .show && VendorRules.isNever($0.path, home: home) })
    }

    @Test func partsAreFoundByExactIDOrMaker() {
        #expect(VendorRules.parts(for: "us.zoom.xos").contains { $0.path == "/Library/Internet Plug-Ins/ZoomUsPlugIn.plugin" })
        #expect(VendorRules.parts(for: "US.ZOOM.XOS").count == VendorRules.parts(for: "us.zoom.xos").count)
        // A longer ID of another app is not the same app.
        #expect(VendorRules.parts(for: "us.zoom.xosx").isEmpty)
        #expect(VendorRules.parts(for: "com.google.Chrome").contains { $0.path == "/Library/Google/GoogleSoftwareUpdate" })
        #expect(VendorRules.parts(for: "com.google.drivefs").contains { $0.path == "/Library/Google/GoogleSoftwareUpdate" })
        #expect(!VendorRules.parts(for: "com.google.drivefs").contains { $0.path.hasSuffix("Google Chrome Brand.plist") })
        #expect(VendorRules.parts(for: "com.example.App").isEmpty)
    }

    @Test func makerNamespacesNeverIncludeSharedProjects() {
        #expect(VendorRules.makerNamespaces(for: "us.zoom.xos") == ["us.zoom."])
        #expect(VendorRules.makerNamespaces(for: "com.getdropbox.dropbox") == ["com.dropbox.", "com.getdropbox."])
        #expect(VendorRules.makerNamespaces(for: "com.apple.garageband10").isEmpty)
        #expect(VendorRules.makerNamespaces(for: "com.electron.dockerdesktop").isEmpty)
        #expect(VendorRules.makerNamespaces(for: "com.github.Electron").isEmpty)
        // Elgato's camera app ships another vendor's driver: never its maker.
        #expect(!VendorRules.makerNamespaces(for: "com.elgato.CameraHub").contains("com.displaylink."))
    }

    @Test func aSharedPartIsFreeOnlyWhenNoAppSharingItRemains() throws {
        let updater = try #require(VendorRules.parts(for: "com.google.Chrome").first { $0.path == "/Library/Google/GoogleSoftwareUpdate" })
        let chrome = ["com.google.Chrome", "com.google.Chrome.helper"]
        #expect(VendorRules.isFree(updater, owners: ["com.google.chrome", "com.google.chrome.helper", "com.vendor.other"], app: chrome))
        #expect(!VendorRules.isFree(updater, owners: ["com.google.chrome", "com.google.drivefs"], app: chrome))
        let loops = try #require(VendorRules.parts(for: "com.apple.garageband10").first { $0.path == "/Library/Audio/Apple Loops/Apple" })
        #expect(!VendorRules.isFree(loops, owners: ["com.apple.garageband10", "com.apple.logic10"], app: ["com.apple.garageband10"]))
        #expect(VendorRules.isFree(loops, owners: ["com.apple.garageband10", "com.apple.music"], app: ["com.apple.garageband10"]))
        let own = try #require(VendorRules.parts(for: "us.zoom.xos").first)
        #expect(VendorRules.isFree(own, owners: ["us.zoom.xos", "us.zoom.other"], app: ["us.zoom.xos"]))
    }

    @Test func aBundlePartMustStillCarryItsID() throws {
        let box = try Sandbox()
        let part = try #require(VendorRules.parts(for: "com.microsoft.teams2").first { $0.bundleID != nil })
        let driver = box.path + "/MSTeamsAudioDevice.driver"
        try box.folder("MSTeamsAudioDevice.driver/Contents")
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.other.Driver"], format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: driver + "/Contents/Info.plist"))
        #expect(!VendorRules.bundleMatches(part, at: driver))
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.microsoft.MSTeamsAudioDevice"], format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: driver + "/Contents/Info.plist"))
        #expect(VendorRules.bundleMatches(part, at: driver))
    }

    @Test func uninstallersArePointedToOnlyWhenThere() throws {
        let box = try Sandbox()
        #expect(VendorRules.uninstallers(for: "com.adobe.acc.AdobeCreativeCloud", home: box.path, base: box.path).isEmpty)
        try box.folder("Applications/Utilities/Adobe Creative Cloud/Utils/Creative Cloud Uninstaller.app/Contents")
        #expect(VendorRules.uninstallers(for: "com.adobe.acc.AdobeCreativeCloud", home: box.path, base: box.path)
            == [box.path + "/Applications/Utilities/Adobe Creative Cloud/Utils/Creative Cloud Uninstaller.app"])
    }

    private func app(_ box: Sandbox, _ name: String, _ id: String) -> AppBundle {
        AppBundle(path: box.path + "/Applications/\(name).app", name: name, bundleID: id, version: nil, bytes: 1, fromAppStore: false)
    }

    @Test func homeFolderPartsTheAppHasAloneStartChosen() throws {
        let box = try Sandbox()
        try box.file("Library/Application Support/ZoomUpdater/u.bin", bytes: 5_000)
        try box.file(".zoomus/settings.db", bytes: 5_000)
        try box.file("Documents/Zoom/meeting.mp4", bytes: 5_000)
        let zoom = app(box, "zoom.us", "us.zoom.xos")
        let found = AppLeftovers.find(for: zoom, home: box.path, installed: [zoom])
        let byPath = Dictionary(uniqueKeysWithValues: found.map { ($0.path, $0) })
        let updater = try #require(byPath[box.path + "/Library/Application Support/ZoomUpdater"])
        #expect(updater.evidence == .knownPart && updater.chosenByDefault)
        #expect(byPath[box.path + "/.zoomus"]?.evidence == .knownPart)
        // Recordings are the user's.
        #expect(!found.contains { $0.path.contains("/Documents/") })
        #expect(AppLeftovers.isStillLeftover(updater.path, of: zoom, home: box.path, installed: [zoom]))
        #expect(!AppLeftovers.isStillLeftover(box.path + "/Documents/Zoom", of: zoom, home: box.path, installed: [zoom]))
    }

    @Test func aFamilysHomePartStaysWhileAnotherOfItsAppsIsInstalled() throws {
        let box = try Sandbox()
        try box.file("Library/Application Support/JabraSDK/s.bin", bytes: 5_000)
        try box.file("Library/Application Support/Jabra Direct/d.bin", bytes: 5_000)
        let direct = app(box, "Jabra Direct", "com.jabra.directonline")
        let other = app(box, "Jabra Sound", "com.jabra.soundplus")
        let found = AppLeftovers.find(for: direct, home: box.path, installed: [direct, other]).map(\.path)
        #expect(!found.contains(box.path + "/Library/Application Support/JabraSDK"))
        #expect(!AppLeftovers.isStillLeftover(box.path + "/Library/Application Support/JabraSDK", of: direct, home: box.path, installed: [direct, other]))
        let alone = AppLeftovers.find(for: direct, home: box.path, installed: [direct])
        let sdk = alone.first { $0.path == box.path + "/Library/Application Support/JabraSDK" }
        // Shared by the family: offered with the last of its apps, never chosen.
        #expect(sdk?.evidence == .knownPart && sdk?.review == .maker)
    }

    @Test func versionedFoldersInTheMakersFolderAreTheApps() throws {
        let box = try Sandbox()
        try box.file("Library/Application Support/JetBrains/IntelliJIdea2024.3/options.xml", bytes: 3_000)
        try box.file("Library/Application Support/JetBrains/IntelliJIdea2023.2/options.xml", bytes: 3_000)
        try box.file("Library/Application Support/JetBrains/PyCharm2024.3/options.xml", bytes: 3_000)
        try box.file("Library/Caches/JetBrains/IntelliJIdea2024.3/index", bytes: 3_000)
        try box.file("Library/Application Support/Google/AndroidStudio2024.2/options.xml", bytes: 3_000)
        try box.file("Library/Application Support/Google/AndroidStudioPreview2024.3/options.xml", bytes: 3_000)
        let idea = app(box, "IntelliJ IDEA", "com.jetbrains.intellij")
        let pycharm = app(box, "PyCharm", "com.jetbrains.pycharm")
        let studio = app(box, "Android Studio", "com.google.android.studio")

        let support = box.path + "/Library/Application Support/"
        let ideaFound = Set(AppLeftovers.find(for: idea, home: box.path, installed: [idea, pycharm]).map(\.path))
        #expect(ideaFound.contains(support + "JetBrains/IntelliJIdea2024.3"))
        #expect(ideaFound.contains(support + "JetBrains/IntelliJIdea2023.2"))
        #expect(ideaFound.contains(box.path + "/Library/Caches/JetBrains/IntelliJIdea2024.3"))
        #expect(!ideaFound.contains(support + "JetBrains/PyCharm2024.3"))
        let studioFound = AppLeftovers.find(for: studio, home: box.path, installed: [studio])
        #expect(studioFound.first { $0.path == support + "Google/AndroidStudio2024.2" }?.evidence == .vendorFolder)
        #expect(!studioFound.contains { $0.path == support + "Google/AndroidStudioPreview2024.3" && $0.evidence == .vendorFolder })

        // Not a version: too short, or no digits at its start.
        #expect(AppLeftovers.unversioned("IntelliJIdea2024.3") == "IntelliJIdea")
        #expect(AppLeftovers.unversioned("Chrome2") == nil)
        #expect(AppLeftovers.unversioned("2024.3") == nil)
        #expect(AppLeftovers.unversioned("Tool.2024.") == nil)
        // Another installed app by the same name keeps them.
        let copy = AppBundle(path: box.path + "/Other/IntelliJ IDEA.app", name: "IntelliJ IDEA", bundleID: "com.jetbrains.intellij-eap",
                             version: nil, bytes: 1, fromAppStore: false)
        #expect(!AppLeftovers.isAppsVendorEntry("IntelliJIdea2024.3", vendor: "JetBrains", of: idea, installed: [idea, copy]))
    }
}

/// What is only shown for an app: parts macOS protects or every user shares,
/// with what to do instead. Never part of a removal.
@Suite struct ShownComponentsTests {
    private func plist(_ dict: [String: Any], at path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0).write(to: URL(fileURLWithPath: path))
    }

    private func app(_ box: Sandbox, _ name: String, _ id: String) -> AppBundle {
        AppBundle(path: box.path + "/Applications/\(name).app", name: name, bundleID: id, version: nil, bytes: 1, fromAppStore: false)
    }

    static let extensions = """
    2 extension(s)
    --- com.apple.system_extension.network_extension
    enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
    *\t*\tTEAM000001\tcom.vendor.Editor.Filter (1.0/1)\tEditor Filter\t[activated enabled]
    *\t*\tTEAM000002\tcom.other.Filter (2.0/2)\tOther Filter\t[activated enabled]
    """

    @Test func protectedAndSharedPartsAreShownWithWhatToDo() throws {
        let box = try Sandbox()
        try plist(["CFBundleIdentifier": "com.vendor.Editor.Kext"], at: box.path + "/Library/Extensions/EditorDriver.kext/Contents/Info.plist")
        try plist(["CFBundleIdentifier": "com.other.Kext"], at: box.path + "/Library/Extensions/Other.kext/Contents/Info.plist")
        let runner = CommandRunner(run: { exe, args in
            exe == RelatedComponents.systemExtensionsTool && args == ["list"] ? (0, Self.extensions) : (1, "")
        }, exists: { _ in true })
        let editor = app(box, "Editor", "com.vendor.Editor")
        let shown = RelatedComponents.shown(for: editor, home: box.path, systemBase: box.path, runner: runner)
        #expect(shown.map(\.name) == ["EditorDriver.kext", "Editor Filter"])
        #expect(shown.allSatisfy { !$0.note.isEmpty })
        #expect(shown.first?.path == box.path + "/Library/Extensions/EditorDriver.kext")
        #expect(shown.last?.path == nil)

        try box.file("Users/Shared/Epic Games/Game/data.pak", bytes: 9_000)
        let launcher = app(box, "Epic Games Launcher", "com.epicgames.EpicGamesLauncher")
        let games = RelatedComponents.shown(for: launcher, home: box.path, systemBase: box.path, runner: runner)
        #expect(games.map(\.name) == ["Epic Games"])
        #expect((games.first?.bytes ?? 0) > 0)
        // A tool that can't run lists nothing more; it's no error.
        let failing = CommandRunner(run: { _, _ in (1, "") }, exists: { _ in false })
        #expect(RelatedComponents.shown(for: editor, home: box.path, systemBase: box.path, runner: failing).map(\.name) == ["EditorDriver.kext"])
    }

    @Test func aVendorsUninstallerIsPointedToForItsOwnAppOnly() throws {
        let box = try Sandbox()
        try box.folder("Applications/Utilities/Adobe Creative Cloud/Utils/Creative Cloud Uninstaller.app/Contents")
        let cc = app(box, "Creative Cloud", "com.adobe.acc.AdobeCreativeCloud")
        let photoshop = app(box, "Adobe Photoshop 2025", "com.adobe.Photoshop")
        #expect(AppFinder.ownUninstaller(of: cc, folders: [box.path + "/Applications"], vendorRoots: (home: box.path, base: box.path))
            == box.path + "/Applications/Utilities/Adobe Creative Cloud/Utils/Creative Cloud Uninstaller.app")
        #expect(AppFinder.ownUninstaller(of: photoshop, folders: [box.path + "/Applications"], vendorRoots: (home: box.path, base: box.path)) == nil)
    }
}
