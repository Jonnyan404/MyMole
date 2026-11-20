import Foundation
import Testing

@testable import StorageKit

/// Leftovers tied by the ID macOS reads: plug-in bundles in the user's
/// Library and background services' containers. Plus what the vendors'
/// own documentation adds: shared folders only shown, and folder names
/// that aren't the app's.
@Suite struct BundledLeftoversTests {
    private func app(_ box: Sandbox, _ name: String, _ id: String) -> AppBundle {
        AppBundle(path: box.path + "/Applications/\(name).app", name: name, bundleID: id, version: nil, bytes: 1, fromAppStore: false)
    }

    private func plist(_ dict: [String: Any], at path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0).write(to: URL(fileURLWithPath: path))
    }

    private func bundle(_ box: Sandbox, _ rel: String, id: String) throws {
        try box.file(rel + "/Contents/MacOS/bin", bytes: 4_000)
        try plist(["CFBundleIdentifier": id], at: box.path + "/" + rel + "/Contents/Info.plist")
    }

    @Test func plugInsAreTheAppsByTheirOwnBundleID() throws {
        let box = try Sandbox()
        try bundle(box, "Library/QuickLook/Editor.qlgenerator", id: "com.vendor.Editor.QuickLook")
        try bundle(box, "Library/Audio/Plug-Ins/VST3/Editor Synth.vst3", id: "com.vendor.Editor")
        try bundle(box, "Library/Screen Savers/Editor.saver", id: "com.vendor.EditorPro.Saver")
        try bundle(box, "Library/Services/Viewer.service", id: "com.vendor.Viewer.Service")
        let editor = app(box, "Editor", "com.vendor.Editor"), viewer = app(box, "Viewer", "com.vendor.Viewer")
        let found = AppLeftovers.find(for: editor, home: box.path, installed: [editor, viewer])
        let lib = box.path + "/Library/"
        let paths = Set(found.map(\.path))
        #expect(paths == [lib + "QuickLook/Editor.qlgenerator", lib + "Audio/Plug-Ins/VST3/Editor Synth.vst3"])
        // Certainly the app's: chosen, as a part of it.
        let ql = try #require(found.first { $0.path.hasSuffix("Editor.qlgenerator") })
        #expect(ql.evidence == .bundleID && ql.chosenByDefault && ql.kind == .appPart)
        #expect(AppLeftovers.isStillLeftover(lib + "QuickLook/Editor.qlgenerator", of: editor, home: box.path, installed: [editor, viewer]))
        #expect(!AppLeftovers.isStillLeftover(lib + "Services/Viewer.service", of: editor, home: box.path, installed: [editor, viewer]))
        // Another installed app whose ID names the bundle more closely keeps it.
        let ql2 = AppBundle(path: box.path + "/Applications/QL.app", name: "QL", bundleID: "com.vendor.Editor.QuickLook", version: nil, bytes: 1, fromAppStore: false)
        #expect(!AppLeftovers.find(for: editor, home: box.path, installed: [editor, ql2]).contains { $0.path.hasSuffix("Editor.qlgenerator") })
    }

    @Test func serviceContainersAreTheAppsByTheirRecordedOwner() throws {
        let box = try Sandbox()
        let mine = "Library/Daemon Containers/6B1E4C2A-0000-4000-8000-000000000001"
        let theirs = "Library/Daemon Containers/6B1E4C2A-0000-4000-8000-000000000002"
        try box.file(mine + "/Data/state.db", bytes: 4_000)
        try plist(["MCMMetadataIdentifier": "com.vendor.Editor.Agent"], at: box.path + "/" + mine + "/" + AppLeftovers.containerMetadata)
        try box.file(theirs + "/Data/state.db", bytes: 4_000)
        try plist(["MCMMetadataIdentifier": "com.other.Agent"], at: box.path + "/" + theirs + "/" + AppLeftovers.containerMetadata)
        let editor = app(box, "Editor", "com.vendor.Editor")
        let found = AppLeftovers.find(for: editor, home: box.path, installed: [editor])
        #expect(found.map(\.path) == [box.path + "/" + mine])
        #expect(found.first?.evidence == .bundleID)
        #expect(AppLeftovers.isStillLeftover(box.path + "/" + mine, of: editor, home: box.path, installed: [editor]))
        #expect(!AppLeftovers.isStillLeftover(box.path + "/" + theirs, of: editor, home: box.path, installed: [editor]))
    }

    /// Steam keeps the games it installed in its folder: shown with what to
    /// do instead, never offered, though the name alone would find it.
    @Test func steamsFolderIsShownNotOffered() throws {
        let box = try Sandbox()
        try box.file("Library/Application Support/Steam/steamapps/common/Game/game.bin", bytes: 6_000)
        let steam = app(box, "Steam", "com.valvesoftware.steam")
        let path = box.path + "/Library/Application Support/Steam"
        #expect(!AppLeftovers.find(for: steam, home: box.path, installed: [steam]).contains { $0.path == path })
        #expect(!AppLeftovers.isStillLeftover(path, of: steam, home: box.path, installed: [steam]))
        let shown = RelatedComponents.shown(for: steam, home: box.path, runner: CommandRunner(run: { _, _ in (1, "") }, exists: { _ in false }))
        #expect(shown.contains { $0.path == path && $0.note.contains("steamapps") })
    }

    @Test func mozillasCacheGoesWithTheLastOfItsApps() throws {
        let box = try Sandbox()
        try box.file("Library/Caches/Mozilla/updates/u.bin", bytes: 4_000)
        try box.file("Library/Application Support/Mozilla/NativeMessagingHosts/other.json", bytes: 400)
        let firefox = app(box, "Firefox", "org.mozilla.firefox"), thunderbird = app(box, "Thunderbird", "org.mozilla.thunderbird")
        let cache = box.path + "/Library/Caches/Mozilla"
        #expect(!AppLeftovers.find(for: firefox, home: box.path, installed: [firefox, thunderbird]).contains { $0.path == cache })
        let alone = AppLeftovers.find(for: firefox, home: box.path, installed: [firefox])
        #expect(alone.first { $0.path == cache }?.review == .maker)
        #expect(!alone.contains { $0.path.hasPrefix(box.path + "/Library/Application Support/Mozilla") })
    }

    @Test func intelliJCommunityKeepsItsFoldersAsIdeaIC() throws {
        let box = try Sandbox()
        try box.file("Library/Application Support/JetBrains/IdeaIC2026.2/options.xml", bytes: 3_000)
        try box.file("Library/Logs/JetBrains/IdeaIC2026.2/idea.log", bytes: 3_000)
        let ce = app(box, "IntelliJ IDEA CE", "com.jetbrains.intellij.ce")
        let found = Set(AppLeftovers.find(for: ce, home: box.path, installed: [ce]).map(\.path))
        #expect(found.contains(box.path + "/Library/Application Support/JetBrains/IdeaIC2026.2"))
        #expect(found.contains(box.path + "/Library/Logs/JetBrains/IdeaIC2026.2"))
    }

    /// Docker's own uninstaller, inside the app wherever it is, is pointed
    /// to by a name of its own; it never stops the app from being moved.
    @Test func dockersOwnUninstallerIsPointedTo() throws {
        let box = try Sandbox()
        try box.file("Elsewhere/Docker.app/Contents/MacOS/uninstall", bytes: 1_000)
        let docker = AppBundle(path: box.path + "/Elsewhere/Docker.app", name: "Docker", bundleID: "com.docker.docker",
                               version: nil, bytes: 1, fromAppStore: false)
        let shown = RelatedComponents.shown(for: docker, home: box.path, runner: CommandRunner(run: { _, _ in (1, "") }, exists: { _ in false }))
        let hint = try #require(shown.first { $0.path == box.path + "/Elsewhere/Docker.app/Contents/MacOS/uninstall" })
        #expect(hint.name == String(localized: "Docker Desktop's own uninstaller") && hint.note.contains("Troubleshoot"))
        #expect(VendorRules.uninstallers(for: "com.docker.docker", home: box.path).isEmpty)
        #expect(!VendorRules.offered(for: "com.docker.docker", home: box.path).contains { $0.inApp })
    }

    @Test func adobesSharedLicensingIsNeverAPart() {
        #expect(VendorRules.isNever("/Library/Application Support/Adobe/SLStore/x", home: "/synthetic/home"))
        #expect(VendorRules.isNever("/Library/Application Support/Adobe/Color Profiles", home: "/synthetic/home"))
    }
}
