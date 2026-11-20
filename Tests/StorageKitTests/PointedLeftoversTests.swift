import Foundation
import Testing

@testable import StorageKit

/// Leftovers tied by what their own file names (a launch job's program, a
/// browser's native messaging host), by the IDs crash reporters and macOS
/// name an app's folders with, by the forms of its name Electron writes,
/// and by the folders the app names as its own.
@Suite struct PointedLeftoversTests {
    private func app(_ box: Sandbox, _ name: String, _ id: String) -> AppBundle {
        AppBundle(path: box.path + "/Applications/\(name).app", name: name, bundleID: id, version: nil, bytes: 1, fromAppStore: false)
    }

    private func write(_ object: Any, plist: Bool, at path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let data = plist ? try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
            : try JSONSerialization.data(withJSONObject: object)
        try data.write(to: URL(fileURLWithPath: path))
    }

    @Test func launchJobsAreTheAppsByTheProgramTheyStart() throws {
        let box = try Sandbox()
        let editor = app(box, "Editor", "com.vendor.editor"), viewer = app(box, "Viewer", "com.other.viewer")
        let agents = box.path + "/Library/LaunchAgents/"
        try write(["Label": "io.updater.agent", "ProgramArguments": [editor.path + "/Contents/MacOS/Updater", "--check"]], plist: true,
                  at: agents + "io.updater.agent.plist")
        try write(["Label": "net.login.item", "BundleProgram": "Contents/Library/LoginItems/Item.app/Contents/MacOS/Item",
                   "AssociatedBundleIdentifiers": ["com.vendor.editor"]], plist: true, at: agents + "net.login.item.plist")
        try write(["Label": "io.viewer.agent", "Program": viewer.path + "/Contents/MacOS/Agent"], plist: true,
                  at: agents + "io.viewer.agent.plist")
        // A path that only starts inside the app, and leaves it again.
        try write(["Label": "io.escape", "Program": editor.path + "/../Viewer.app/Contents/MacOS/Agent"], plist: true,
                  at: agents + "io.escape.plist")
        let found = AppLeftovers.find(for: editor, home: box.path, installed: [editor, viewer])
        let jobs = found.filter { $0.place == "LaunchAgents" }
        #expect(Set(jobs.map(\.path)) == [agents + "io.updater.agent.plist", agents + "net.login.item.plist"])
        #expect(jobs.allSatisfy { $0.evidence == .pointsIntoApp && $0.chosenByDefault && $0.kind == .appPart })
        #expect(AppLeftovers.isStillLeftover(agents + "io.updater.agent.plist", of: editor, home: box.path, installed: [editor, viewer]))
        #expect(!AppLeftovers.isStillLeftover(agents + "io.viewer.agent.plist", of: editor, home: box.path, installed: [editor, viewer]))
        #expect(!AppLeftovers.isStillLeftover(agents + "io.escape.plist", of: editor, home: box.path, installed: [editor, viewer]))
        // An installed app the job also names keeps it.
        let suite = app(box, "Suite", "com.vendor.suite")
        try write(["Label": "net.shared", "BundleProgram": "x", "AssociatedBundleIdentifiers": ["com.vendor.editor", "com.vendor.suite"]],
                  plist: true, at: agents + "net.shared.plist")
        #expect(!AppLeftovers.find(for: editor, home: box.path, installed: [editor, suite]).contains { $0.path.hasSuffix("net.shared.plist") })
    }

    @Test func browserConnectionsAreTheAppsByTheProgramTheyStart() throws {
        let box = try Sandbox()
        let vault = app(box, "Vault", "com.vendor.vault"), other = app(box, "Other", "com.other.app")
        let support = box.path + "/Library/Application Support/"
        let chrome = support + "Google/Chrome/NativeMessagingHosts/com.vendor.vault.json"
        let firefox = support + "Mozilla/NativeMessagingHosts/vault_host.json"
        let theirs = support + "BraveSoftware/Brave-Browser/NativeMessagingHosts/com.other.app.json"
        try write(["name": "com.vendor.vault", "path": vault.path + "/Contents/Library/Host"], plist: false, at: chrome)
        try write(["name": "vault_host", "path": vault.path + "/Contents/Library/Host"], plist: false, at: firefox)
        try write(["name": "com.other.app", "path": other.path + "/Contents/MacOS/Host"], plist: false, at: theirs)
        let found = AppLeftovers.find(for: vault, home: box.path, installed: [vault, other])
        let hosts = found.filter { $0.evidence == .pointsIntoApp }
        #expect(Set(hosts.map(\.path)) == [chrome, firefox])
        #expect(hosts.allSatisfy { $0.chosenByDefault && $0.kind == .appPart })
        #expect(AppLeftovers.isStillLeftover(firefox, of: vault, home: box.path, installed: [vault, other]))
        #expect(!AppLeftovers.isStillLeftover(theirs, of: vault, home: box.path, installed: [vault, other]))
    }

    @Test func crashReportersAndMacOSKeepTheAppsFoldersByItsID() throws {
        let box = try Sandbox()
        let id = "com.vendor.editor"
        try box.file("Library/Caches/com.plausiblelabs.crashreporter.data/\(id)/live_report.plcrash", bytes: 2_000)
        try box.file("Library/Caches/KSCrashReports/Editor/Reports/r.json", bytes: 2_000)
        try box.file("Library/Application Support/com.bugsnag.Bugsnag/\(id)/events/e.json", bytes: 2_000)
        try box.file("Library/Application Support/FileProvider/\(id).fileprovider/db.sqlite", bytes: 2_000)
        try box.file("Library/Autosave Information/\(id).plist", bytes: 300)
        try box.file("Library/Caches/com.plausiblelabs.crashreporter.data/com.other.app/live_report.plcrash", bytes: 2_000)
        let editor = app(box, "Editor", id)
        let found = AppLeftovers.find(for: editor, home: box.path, installed: [editor])
        let lib = box.path + "/Library/"
        #expect(Set(found.map(\.path)) == [
            lib + "Caches/com.plausiblelabs.crashreporter.data/\(id)", lib + "Caches/KSCrashReports/Editor",
            lib + "Application Support/com.bugsnag.Bugsnag/\(id)", lib + "Application Support/FileProvider/\(id).fileprovider",
            lib + "Autosave Information/\(id).plist",
        ])
        let report = try #require(found.first { $0.path.contains("plausiblelabs") })
        #expect(report.kind == .rebuildable && report.chosenByDefault)
        #expect(found.first { $0.path.contains("bugsnag") }?.kind == .rebuildable)
        #expect(AppLeftovers.isStillLeftover(lib + "Caches/com.plausiblelabs.crashreporter.data/\(id)", of: editor, home: box.path, installed: [editor]))
        #expect(!AppLeftovers.isStillLeftover(lib + "Caches/com.plausiblelabs.crashreporter.data/com.other.app", of: editor, home: box.path, installed: [editor]))
    }

    @Test func electronsFormsOfTheNameAreFoundByName() throws {
        let box = try Sandbox()
        try box.file("Library/Application Support/beekeeper-studio/Local Storage/x.db", bytes: 3_000)
        try box.file("Library/Logs/BeekeeperStudio/main.log", bytes: 1_000)
        let app = app(box, "Beekeeper Studio", "io.beekeeperstudio.desktop")
        let found = AppLeftovers.find(for: app, home: box.path, installed: [app])
        let support = try #require(found.first { $0.path.hasSuffix("/beekeeper-studio") })
        #expect(support.evidence == .name && !support.chosenByDefault)
        #expect(found.contains { $0.path.hasSuffix("/Logs/BeekeeperStudio") })
        // Another app whose name is the same but for spaces and case: neither's.
        let twin = AppBundle(path: box.path + "/Applications/BeekeeperStudio.app", name: "BeekeeperStudio", bundleID: "com.twin.app",
                             version: nil, bytes: 1, fromAppStore: false)
        #expect(!AppLeftovers.find(for: app, home: box.path, installed: [app, twin]).contains { $0.evidence == .name })
    }

    @Test func foldersTheAppNamesAsItsOwnAreFoundAndCheckedAgainstOthers() throws {
        let box = try Sandbox()
        let code = app(box, "Visual Studio Code", "com.microsoft.VSCode")
        try write(["nameShort": "Code", "dataFolderName": ".vscode"], plist: false, at: code.path + "/Contents/Resources/app/product.json")
        try box.file("Library/Application Support/Code/User/settings.json", bytes: 1_000)
        try box.file(".vscode/extensions/ext/package.json", bytes: 5_000)
        #expect(AppLeftovers.declaredFolders(of: code.path) == ["Library/Application Support/Code", ".vscode"])
        let readers = AppIdentity.Readers(carried: { _ in [] }, groups: { _ in [] })
        let identity = try #require(AppIdentity.owned(for: code, installed: [code], readers: readers))
        let found = AppLeftovers.find(for: code, home: box.path, installed: [code], identity: identity)
        let declared = found.filter { $0.evidence == .declared }
        #expect(Set(declared.map(\.path)) == [box.path + "/Library/Application Support/Code", box.path + "/.vscode"])
        #expect(declared.allSatisfy { $0.chosenByDefault })
        #expect(AppLeftovers.isStillLeftover(box.path + "/.vscode", of: code, home: box.path, installed: [code], identity: identity))
        // A shared hidden folder is never one app's.
        let odd = app(box, "Odd", "com.odd.app")
        try write(["nameShort": "Google", "dataFolderName": ".config"], plist: false, at: odd.path + "/Contents/Resources/app/product.json")
        #expect(AppLeftovers.declaredFolders(of: odd.path) == ["Library/Application Support/Google"])
        #expect(AppLeftovers.find(for: odd, home: box.path, installed: [odd],
                                  identity: AppIdentity(folders: AppLeftovers.declaredFolders(of: odd.path))).allSatisfy { $0.evidence != .declared })
        // Another installed app that names the same folder keeps it.
        let fork = app(box, "Fork", "com.fork.editor")
        try write(["nameShort": "Code", "dataFolderName": ".vscode"], plist: false, at: fork.path + "/Contents/Resources/app/product.json")
        let shared = try #require(AppIdentity.owned(for: code, installed: [code, fork], readers: readers))
        #expect(shared.folders.isEmpty)
    }

    @Test func vendorsDocumentedFoldersAndUninstallers() throws {
        let box = try Sandbox()
        try box.file("Library/Android/sdk/platforms/android-36/android.jar", bytes: 8_000)
        try box.file(".android/avd/Pixel.avd/userdata.img", bytes: 8_000)
        let studio = app(box, "Android Studio", "com.google.android.studio")
        let alone = AppLeftovers.find(for: studio, home: box.path, installed: [studio])
        let sdk = try #require(alone.first { $0.path == box.path + "/Library/Android/sdk" })
        #expect(!sdk.chosenByDefault && alone.contains { $0.path == box.path + "/.android" })
        let idea = app(box, "IntelliJ IDEA", "com.jetbrains.intellij")
        #expect(!AppLeftovers.find(for: studio, home: box.path, installed: [studio, idea]).contains { $0.path.hasSuffix("/Android/sdk") })

        try box.file("Library/Application Support/Google/DriveFS/123/content_cache/c.bin", bytes: 6_000)
        let drive = app(box, "Google Drive", "com.google.drivefs")
        let cache = try #require(AppLeftovers.find(for: drive, home: box.path, installed: [drive]).first {
            $0.path == box.path + "/Library/Application Support/Google/DriveFS" })
        #expect(!cache.chosenByDefault)

        try box.file("Library/Preferences/com.electron.dockerdesktop.plist", bytes: 300)
        let docker = app(box, "Docker", "com.docker.docker")
        #expect(AppLeftovers.find(for: docker, home: box.path, installed: [docker]).contains {
            $0.path.hasSuffix("com.electron.dockerdesktop.plist") && $0.chosenByDefault })

        try box.file("Applications/Avast.app/Contents/Backend/hub/uninstall.sh", bytes: 500)
        let avast = app(box, "Avast", "com.avast.av")
        let shown = RelatedComponents.shown(for: avast, home: box.path, runner: CommandRunner(run: { _, _ in (1, "") }, exists: { _ in false }))
        #expect(shown.contains { $0.name == String(localized: "Avast's own uninstaller") && $0.note.contains("Uninstall Avast Security") })
    }
}
