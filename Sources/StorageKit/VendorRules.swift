import Darwin
import Foundation

/// What some big vendors' apps put outside the places every app uses, by
/// exact path, from the vendors' own uninstall lists and Homebrew's curated
/// ones. A part is offered only when its app, or the last app of the family
/// that shares it, is the one going; a part macOS protects, or one every
/// user of the Mac shares, is only shown with what to do about it.
/// Nothing here is ever chosen for the user.
public enum VendorRules {
    public enum Handling: String, Sendable, Codable {
        /// Can go, after the user chooses it.
        case offer
        /// Only listed, with what to do about it.
        case show
    }

    public enum Kind: String, Sendable, Codable {
        case appPart, data, settings, rebuildable, record
    }

    public struct Part: Sendable, Equatable {
        /// Absolute; "~/" is the user's home folder.
        public let path: String
        public let handling: Handling
        public let kind: Kind
        /// Apps (exact IDs) and makers ("com.vendor.") that share the part.
        /// It's offered only when none of them is still on the Mac. Empty:
        /// the app's alone.
        public let sharedWith: [String]
        /// A bundle is offered only while its own ID is this one.
        public let bundleID: String?
        /// What to do instead, for a part that is only shown.
        public let note: String?

        init(_ path: String, _ handling: Handling = .offer, _ kind: Kind = .data, sharedWith: [String] = [],
             bundleID: String? = nil, note: String? = nil) {
            self.path = path
            self.handling = handling
            self.kind = kind
            self.sharedWith = sharedWith
            self.bundleID = bundleID
            self.note = note
        }

        /// Whether `path` here is in the home folder.
        public var inHome: Bool { path.hasPrefix("~/") }

        /// The part's path on this Mac: `home` for "~/", `base` before a system path.
        public func resolved(home: String, base: String = "") -> String {
            inHome ? home + path.dropFirst(1) : base + path
        }
    }

    public struct Rule: Sendable {
        public let vendor: String
        /// Exact bundle IDs, or makers ("com.vendor.") for every app of theirs.
        public let apps: [String]
        /// Other ID namespaces the vendor's launch jobs and helpers use
        /// ("com.dropbox." for Dropbox, whose app is "com.getdropbox.dropbox").
        public let namespaces: [String]
        public let parts: [Part]
        /// The vendor's own uninstaller, where it installs one. Only pointed
        /// to, never run.
        public let uninstallers: [String]

        init(_ vendor: String, apps: [String], namespaces: [String] = [], parts: [Part] = [], uninstallers: [String] = []) {
            self.vendor = vendor
            self.apps = apps
            self.namespaces = namespaces
            self.parts = parts
            self.uninstallers = uninstallers
        }

        func applies(to id: String) -> Bool { VendorRules.matches(id, any: apps) }
    }

    static let protectedNote = "macOS protects it. Remove it with the vendor's uninstaller, or turn it off in System Settings > General > Login Items & Extensions."
    static let sharedFolderNote = String(localized: "In the folder every user of this Mac shares. Other users' copies of the app may still use it.")
    static let printerNote = String(localized: "Printer drivers are shared by every printer of this maker. Remove a printer in System Settings > Printers & Scanners.")

    static let microsoft = ["com.microsoft."]
    static let google = ["com.google."]
    static let appleMusicApps = ["com.apple.garageband10", "com.apple.logic10", "com.apple.mainstage3"]

    public static let rules: [Rule] = [
        Rule("Zoom", apps: ["us.zoom.xos"], parts: [
            Part("/Library/Internet Plug-Ins/ZoomUsPlugIn.plugin", .offer, .appPart),
            Part("/Library/Audio/Plug-Ins/HAL/ZoomAudioDevice.driver", .offer, .appPart),
            Part("/Library/Logs/zoomusinstall.log", .offer, .rebuildable),
            Part("~/Library/Internet Plug-Ins/ZoomUsPlugIn.plugin", .offer, .appPart),
            Part("~/Library/Application Support/ZoomUpdater", .offer, .data),
            Part("~/Library/Logs/zoominstall.log", .offer, .rebuildable),
            Part("~/Library/Logs/ZoomPhone", .offer, .rebuildable),
            Part("~/Library/Preferences/ZoomChat.plist", .offer, .settings),
            Part("~/.zoomus", .offer, .data),
        ]),
        Rule("Microsoft Teams", apps: ["com.microsoft.teams2"], parts: [
            Part("/Library/Audio/Plug-Ins/HAL/MSTeamsAudioDevice.driver", .offer, .appPart, bundleID: "com.microsoft.MSTeamsAudioDevice"),
            Part("/Library/LaunchDaemons/com.microsoft.teams.TeamsUpdaterDaemon.plist", .offer, .appPart),
            Part("/Library/Application Support/Microsoft/TeamsUpdaterDaemon", .offer, .appPart),
            Part("/Library/Logs/Microsoft/MSTeams", .offer, .rebuildable),
            Part("/Library/Logs/Microsoft/Teams", .offer, .rebuildable),
            Part("/Library/Preferences/com.microsoft.teams.plist", .offer, .settings),
            Part("/private/var/db/receipts/com.microsoft.MSTeamsAudioDevice.plist", .offer, .record),
            Part("/private/var/db/receipts/com.microsoft.MSTeamsAudioDevice.bom", .offer, .record),
            Part("~/Library/Application Support/Teams", .offer, .data),
        ]),
        // Microsoft AutoUpdate updates every Microsoft app: its parts go with the last of them.
        Rule("Microsoft AutoUpdate", apps: ["com.microsoft.autoupdate2"], parts: [
            Part("/Library/PrivilegedHelperTools/com.microsoft.autoupdate.helper", .offer, .appPart, sharedWith: microsoft),
            Part("/Library/LaunchDaemons/com.microsoft.autoupdate.helper.plist", .offer, .appPart, sharedWith: microsoft),
            Part("/Library/LaunchAgents/com.microsoft.update.agent.plist", .offer, .appPart, sharedWith: microsoft),
            Part("/Library/Caches/com.microsoft.autoupdate.helper", .offer, .rebuildable, sharedWith: microsoft),
            Part("/Library/Caches/com.microsoft.autoupdate.fba", .offer, .rebuildable, sharedWith: microsoft),
            Part("~/Library/Application Support/Microsoft AutoUpdate", .offer, .data, sharedWith: microsoft),
        ]),
        Rule("Microsoft Edge", apps: ["com.microsoft.edgemac"], parts: [
            Part("~/Library/Application Support/Microsoft/EdgeUpdater", .offer, .appPart),
            Part("~/Library/Microsoft/MicrosoftSoftwareUpdate/Actives/com.microsoft.edgemac", .offer, .appPart),
        ]),
        Rule("OneDrive", apps: ["com.microsoft.onedrive"], parts: [
            Part("/Library/Logs/Microsoft/OneDrive", .offer, .rebuildable),
            Part("~/Library/Logs/OneDrive", .offer, .rebuildable),
        ]),
        // Google's updater serves Chrome, Drive, Earth and Android Studio alike.
        Rule("Google", apps: google, parts: [
            Part("/Library/Google/GoogleSoftwareUpdate", .offer, .appPart, sharedWith: google),
            Part("/Library/Application Support/Google/GoogleUpdater", .offer, .appPart, sharedWith: google),
            Part("/private/var/db/receipts/com.google.pkg.Keystone.plist", .offer, .record, sharedWith: google),
            Part("/private/var/db/receipts/com.google.pkg.Keystone.bom", .offer, .record, sharedWith: google),
            Part("~/Library/Google/GoogleSoftwareUpdate", .offer, .appPart, sharedWith: google),
            Part("~/Library/Logs/GoogleSoftwareUpdateAgent.log", .offer, .rebuildable, sharedWith: google),
        ]),
        Rule("Google Chrome", apps: ["com.google.chrome"], parts: [
            Part("/Library/Google/Google Chrome Brand.plist", .offer, .settings),
            Part("~/Library/Google/Google Chrome Brand.plist", .offer, .settings),
        ]),
        Rule("Adobe", apps: ["com.adobe."], parts: [
            Part("/Library/Internet Plug-Ins/AdobeAAMDetect.plugin", .offer, .appPart, sharedWith: ["com.adobe."]),
            Part("/Library/Application Support/Adobe", .show, .data,
                 note: String(localized: "Shared by Creative Cloud and every Adobe app. Use Adobe's Creative Cloud uninstaller or Cleaner Tool.")),
            Part("/Users/Shared/Adobe", .show, .data, note: sharedFolderNote),
            Part("~/Library/Application Support/Adobe/CoreSync", .show, .data,
                 note: String(localized: "Creative Cloud's sync state. Let Creative Cloud sign out and finish syncing first.")),
        ]),
        // Adobe's other apps are removed from Creative Cloud itself.
        Rule("Adobe Creative Cloud", apps: ["com.adobe.acc.AdobeCreativeCloud"], uninstallers: [
            "/Applications/Utilities/Adobe Creative Cloud/Utils/Creative Cloud Uninstaller.app",
            "/Applications/Utilities/Adobe Installers/Uninstall Adobe Creative Cloud.app",
        ]),
        Rule("Dropbox", apps: ["com.getdropbox.dropbox"], namespaces: ["com.dropbox."], parts: [
            Part("/Library/DropboxHelperTools", .offer, .appPart),
            Part("/Library/Preferences/com.getdropbox.dropbox.dbkextd.plist", .offer, .settings),
            Part("~/.dropbox", .offer, .settings),
            Part("~/Library/Dropbox", .offer, .appPart),
            Part("~/Library/Application Support/DropboxElectron", .offer, .data),
        ]),
        Rule("Docker", apps: ["com.docker.docker"], parts: [
            Part("~/Library/Application Support/Docker Desktop", .offer, .data),
            Part("~/Library/Caches/Docker Desktop", .offer, .rebuildable),
            Part("~/Library/Logs/Docker Desktop", .offer, .rebuildable),
            Part("~/.docker", .show, .settings,
                 note: String(localized: "The docker command's own settings, contexts and sign-ins. Docker installed another way uses it too.")),
        ]),
        Rule("Jabra", apps: ["com.jabra.directonline"], parts: [
            Part("~/Library/Application Support/Jabra Direct", .offer, .data),
            Part("~/Library/Application Support/Jabra", .offer, .data, sharedWith: ["com.jabra."]),
            Part("~/Library/Application Support/JabraSDK", .offer, .data, sharedWith: ["com.jabra."]),
            Part("~/Library/Preferences/com.jabra.prefsettings.plist", .offer, .settings, sharedWith: ["com.jabra."]),
        ]),
        Rule("Logi Options+", apps: ["com.logi.optionsplus"], namespaces: ["com.logitech."], parts: [
            Part("/Library/Application Support/Logitech.localized/LogiOptionsPlus", .offer, .appPart),
            Part("/Library/Application Support/Logi", .offer, .appPart, sharedWith: ["com.logi.", "com.logitech."]),
            Part("~/Library/Application Support/LogiOptionsPlus", .offer, .data),
            Part("~/Library/Application Support/Logi", .offer, .data, sharedWith: ["com.logi.", "com.logitech."]),
            Part("/Users/Shared/LogiOptionsPlus", .show, .data, note: sharedFolderNote),
            Part("/Users/Shared/logi", .show, .data, note: sharedFolderNote),
        ]),
        Rule("Logitech G HUB", apps: ["com.logi.ghub"], parts: [
            Part("/Users/Shared/LGHUB", .show, .data, note: sharedFolderNote),
        ]),
        Rule("Logitech Options", apps: ["com.logitech.logi-options"], uninstallers: [
            "/Applications/Utilities/LogiMgr Uninstaller.app",
        ]),
        Rule("OBS Studio", apps: ["com.obsproject.obs-studio"], parts: [
            Part("/Library/CoreMediaIO/Plug-Ins/DAL/obs-mac-virtualcam.plugin", .offer, .appPart),
        ]),
        Rule("Parallels Desktop", apps: ["com.parallels.desktop.console"], parts: [
            Part("/Library/Preferences/Parallels", .offer, .settings),
            Part("~/Library/Parallels/Parallels Desktop", .offer, .data),
            Part("~/Library/Parallels/Applications Menus", .offer, .appPart),
            Part("~/Applications (Parallels)", .offer, .appPart),
            Part("~/.parallels_settings", .offer, .settings),
            Part("/Users/Shared/Parallels", .show, .data, note: sharedFolderNote),
        ]),
        Rule("VirtualBox", apps: ["org.virtualbox.app.virtualbox"], parts: [
            Part("/Library/Application Support/VirtualBox", .show, .appPart,
                 note: String(localized: "Holds VirtualBox's drivers. Run VirtualBox_Uninstall.tool from its installer disk image.")),
            Part("~/Library/VirtualBox", .offer, .settings),
        ]),
        Rule("Little Snitch", apps: ["at.obdev.littlesnitch"], parts: [
            Part("/Library/Little Snitch", .show, .data, note: String(localized: "Little Snitch's rules and its network filter. Use Uninstall in Little Snitch's own menu.")),
            Part("/Library/Logs/LittleSnitchDaemon.log", .offer, .rebuildable),
            Part("/Library/Caches/at.obdev.LittleSnitchConfiguration", .offer, .rebuildable),
        ]),
        Rule("Tunnelblick", apps: ["net.tunnelblick.tunnelblick"], parts: [
            Part("/Library/Application Support/Tunnelblick", .offer, .data),
        ]),
        Rule("Citrix Workspace", apps: ["com.citrix.receiver.nomas"], parts: [
            Part("/Library/Citrix Workspace", .offer, .appPart),
            Part("/Library/Logs/Citrix Workspace", .offer, .rebuildable),
        ]),
        Rule("ExpressVPN", apps: ["com.express.vpn"], parts: [
            Part("/Library/Application Support/com.express.vpn", .offer, .data),
            Part("/Library/Preferences/com.express.vpn", .offer, .settings),
        ]),
        Rule("Malwarebytes", apps: ["com.malwarebytes."], parts: [
            Part("/Library/Application Support/Malwarebytes", .show, .data,
                 note: String(localized: "Its protection runs as a system extension. Use Help > Uninstall Malwarebytes in the app.")),
        ]),
        Rule("Unity", apps: ["com.unity3d."], parts: [
            Part("/Library/Application Support/Unity", .show, .data, note: String(localized: "Unity's license is kept here for every editor. Return the license in Unity Hub first.")),
        ]),
        Rule("Epic Games", apps: ["com.epicgames.epicgameslauncher"], parts: [
            Part("/Users/Shared/Epic Games", .show, .data, note: String(localized: "Games the launcher installed. Remove them in the launcher, so their saves and licenses are handled.")),
        ]),
        Rule("Autodesk", apps: ["com.autodesk."], parts: [
            Part("/Users/Shared/Autodesk", .show, .data, note: sharedFolderNote),
        ]),
        Rule("Wacom", apps: ["com.wacom."], uninstallers: [
            "/Applications/Wacom Tablet.localized/Wacom Tablet Utility.app",
        ]),
        // GarageBand, Logic and MainStage share Apple's sound library.
        Rule("GarageBand", apps: ["com.apple.garageband10"], parts: [
            Part("/Library/Application Support/GarageBand", .offer, .data),
            Part("/Library/Audio/Apple Loops/Apple", .offer, .data, sharedWith: appleMusicApps),
        ]),
        Rule("Logic Pro", apps: ["com.apple.logic10"], parts: [
            Part("/Library/Application Support/Logic", .offer, .data),
            Part("/Library/Audio/Apple Loops/Apple", .offer, .data, sharedWith: appleMusicApps),
        ]),
        Rule("MainStage", apps: ["com.apple.mainstage3"], parts: [
            Part("/Library/Application Support/MainStage", .offer, .data),
            Part("/Library/Audio/Apple Loops/Apple", .offer, .data, sharedWith: appleMusicApps),
        ]),
        Rule("HP", apps: ["com.hp."], parts: [Part("/Library/Printers/hp", .show, .appPart, note: printerNote)]),
        Rule("Canon", apps: ["jp.co.canon."], parts: [Part("/Library/Printers/Canon", .show, .appPart, note: printerNote)]),
        Rule("Epson", apps: ["com.epson."], parts: [Part("/Library/Printers/EPSON", .show, .appPart, note: printerNote)]),
        Rule("Brother", apps: ["com.brother."], parts: [Part("/Library/Printers/Brother", .show, .appPart, note: printerNote)]),
    ]

    /// Never a part, nor anything inside one of these: the user's own files,
    /// virtual machines, what every user shares, and what macOS protects.
    public static let neverUnder: [String] = [
        "~/Documents", "~/Desktop", "~/Downloads", "~/Movies", "~/Music", "~/Pictures", "~/Dropbox",
        "~/Library/CloudStorage", "~/Library/Mobile Documents", "~/Creative Cloud Files", "~/Parallels",
        "~/VirtualBox VMs", "~/Virtual Machines.localized", "~/.tart/vms",
        "/Users/Shared", "/Library/Extensions", "/Library/SystemExtensions", "/Library/StagedExtensions",
        "/Library/Audio/Plug-Ins/Components", "/Library/Audio/Plug-Ins/VST", "/Library/Audio/Plug-Ins/VST3",
        "/System", "/usr", "/bin", "/sbin",
    ]

    /// Never a part itself: folders a whole family of apps shares.
    public static let neverExactly: [String] = [
        "~/Library/Application Support/Microsoft", "~/Library/Group Containers/UBF8T346G9.Office",
        "~/Library/Group Containers/UBF8T346G9.ms", "~/Library/Group Containers/UBF8T346G9.OfficeOsfWebHost",
        "~/Library/Application Support/Google", "~/Library/Application Support/Adobe", "~/Library/Google",
        "/Library/Application Support/Microsoft", "/Library/Google", "/Library/Printers", "/Library/Audio/Apple Loops",
        "/Library/Application Support/Logitech.localized", "/Library/Logs/Microsoft",
    ]

    /// ID families that belong to other projects, whoever ships them.
    public static let neverNamespaces = [
        "com.apple.", "com.electron.", "com.github.", "org.sparkle-project.", "com.plausiblelabs.",
        "com.bugsnag.", "com.displaylink.", "nl.superalloy.",
    ]

    /// `id` is one of `list`: exactly, or under a maker ("com.vendor.").
    static func matches(_ id: String, any list: [String]) -> Bool {
        let id = id.lowercased()
        return list.contains { entry in
            let e = entry.lowercased()
            return e.hasSuffix(".") ? id.hasPrefix(e) : id == e || id.hasPrefix(e + ".")
        }
    }

    /// Every rule for the app.
    public static func rules(for appID: String) -> [Rule] {
        rules.filter { $0.applies(to: appID) }
    }

    /// The app's parts by every rule for it, each once.
    public static func parts(for appID: String) -> [Part] {
        var seen = Set<String>()
        return rules(for: appID).flatMap(\.parts).filter { seen.insert($0.path).inserted }
    }

    /// The maker namespaces whose launch jobs and helpers are the app's
    /// maker's: its own ("com.vendor."), and those a rule adds. Never
    /// another project's.
    public static func makerNamespaces(for appID: String) -> [String] {
        var out: [String] = []
        if let space = AppIdentity.namespace(of: appID)?.lowercased(), AppLeftovers.company(of: appID) != nil { out.append(space) }
        out += rules(for: appID).flatMap(\.namespaces).map { $0.lowercased() }
        return Array(Set(out)).filter { s in !neverNamespaces.contains { s.hasPrefix($0) } }.sorted()
    }

    /// Whether no installed app (by the IDs `owners` holds, lower case)
    /// is one that shares the part, other than `app` and what it carries.
    public static func isFree(_ part: Part, owners: Set<String>, app: [String]) -> Bool {
        guard !part.sharedWith.isEmpty else { return true }
        let mine = Set(app.map { $0.lowercased() })
        return !owners.contains { o in !mine.contains(o) && matches(o, any: part.sharedWith) }
    }

    /// Whether `path` is one a part may never be, or inside one.
    public static func isNever(_ path: String, home: String, base: String = "") -> Bool {
        func resolve(_ p: String) -> String { p.hasPrefix("~/") ? home + p.dropFirst(1) : base + p }
        return neverExactly.contains { path == resolve($0) }
            || neverUnder.contains { let r = resolve($0); return path == r || path.hasPrefix(r + "/") }
    }

    /// The parts that may be offered for the app: not shown-only, not a never path.
    public static func offered(for appID: String, home: String, base: String = "") -> [Part] {
        parts(for: appID).filter { $0.handling == .offer && !isNever($0.resolved(home: home, base: base), home: home, base: base) }
    }

    /// A part's own bundle ID still matches what the rule names.
    public static func bundleMatches(_ part: Part, at path: String) -> Bool {
        guard let wanted = part.bundleID else { return true }
        let info = AppIdentity.bundleInfo(atPath: path) ?? readInfo(path + "/Info.plist")
        return (info?["CFBundleIdentifier"] as? String)?.caseInsensitiveCompare(wanted) == .orderedSame
    }

    static func readInfo(_ path: String) -> [String: Any]? {
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size <= 1 << 20,
              let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// The vendor's uninstallers that are on this Mac, to point to.
    public static func uninstallers(for appID: String, home: String, base: String = "") -> [String] {
        rules(for: appID).flatMap(\.uninstallers).map { $0.hasPrefix("~/") ? home + $0.dropFirst(1) : base + $0 }.filter {
            var st = stat()
            return lstat($0, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR
        }
    }
}
