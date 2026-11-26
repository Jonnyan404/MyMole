import Darwin
import Foundation

/// Leftovers tied to the app by what their own file names, whatever they
/// are called: a launch job whose program is inside the app, which launchd
/// starts, and a browser's native messaging host whose program is inside
/// it, which the browser starts. And the folders the app names as its own
/// in its bundle.
extension AppLeftovers {
    /// The folder of native messaging hosts in each browser's own folder in Application Support.
    static let messagingHosts = "NativeMessagingHosts"

    /// Browsers' folders in Application Support that hold a native messaging hosts folder.
    static let browserFolders = [
        "Google/Chrome", "Google/Chrome Beta", "Google/Chrome Dev", "Google/Chrome Canary", "Chromium",
        "Microsoft Edge", "Microsoft Edge Beta", "Microsoft Edge Dev", "Microsoft Edge Canary",
        "BraveSoftware/Brave-Browser", "BraveSoftware/Brave-Browser-Beta", "BraveSoftware/Brave-Browser-Nightly",
        "Vivaldi", "Arc/User Data", "Mozilla",
    ]

    /// Hidden folders in the home folder that tools share, never one app's own.
    static let sharedDotFolders: Set<String> = [
        ".config", ".cache", ".local", ".ssh", ".gnupg", ".git", ".docker", ".npm", ".trash", ".zsh_sessions",
    ]

    /// A plain file of at most 1 MB, with no link at its end.
    static func smallFile(_ path: String) -> Data? {
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size <= 1 << 20 else { return nil }
        return FileManager.default.contents(atPath: path)
    }

    /// Whether `program` is inside the app's bundle, read as it's written.
    static func isInside(_ program: String, _ app: AppBundle) -> Bool {
        guard program.hasPrefix("/") else { return false }
        return (program as NSString).standardizingPath.hasPrefix(app.path + "/")
    }

    /// A launch job's list that starts a program inside the app, or that
    /// macOS shows under the app in Login Items by its ID and no other
    /// installed app's.
    static func jobNamesApp(_ path: String, of app: AppBundle, installed: [AppBundle]) -> Bool {
        guard path.hasSuffix(".plist"), let d = VendorRules.readInfo(path) else { return false }
        var programs: [String] = []
        if let p = d["Program"] as? String { programs.append(p) }
        if let first = (d["ProgramArguments"] as? [String])?.first { programs.append(first) }
        if !programs.isEmpty, programs.allSatisfy({ isInside($0, app) }) { return true }
        guard let id = app.bundleID else { return false }
        let others = installed.filter { $0.path != app.path }
        // A program inside another installed app is that app's.
        guard !programs.contains(where: { p in others.contains { isInside(p, $0) } }) else { return false }
        let raw = d["AssociatedBundleIdentifiers"]
        let associated = (raw as? [String]) ?? (raw as? String).map { [$0] } ?? []
        guard associated.contains(where: { $0.caseInsensitiveCompare(id) == .orderedSame }) else { return false }
        let otherIDs = Set(others.compactMap { $0.bundleID?.lowercased() })
        return !associated.contains { otherIDs.contains($0.lowercased()) }
    }

    /// A browser's native messaging host whose program is inside the app.
    static func hostNamesApp(_ path: String, of app: AppBundle) -> Bool {
        guard path.hasSuffix(".json"), let data = smallFile(path),
              let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let program = d["path"] as? String else { return false }
        return isInside(program, app)
    }

    /// Folders in the home folder where tools put links to their commands.
    static let commandFolders = [".local/bin", "bin"]
    /// System and Homebrew folders of commands: links into the app there are only shown.
    static let sharedCommandFolders = ["/usr/local/bin", "/opt/homebrew/bin"]

    /// Where a link points, worked out from the folder it's in; nil for anything but a link.
    static func linkTarget(_ path: String) -> String? {
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFLNK,
              let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: path), !dest.isEmpty else { return nil }
        return dest.hasPrefix("/") ? dest : ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(dest)
    }

    /// A link to a command inside the app, which stops working once the app is gone.
    static func linksIntoApp(_ path: String, _ app: AppBundle) -> Bool {
        linkTarget(path).map { isInside($0, app) } ?? false
    }

    /// The app's command links in the home folder's own command folders.
    static func commandLinks(of app: AppBundle, home: String, scan: LeftoverScan) -> [Leftover] {
        var out: [Leftover] = []
        for folder in commandFolders where !scan.shouldStop {
            let dir = home + "/" + folder
            // Read only as the folder of commands it usually is: "~/bin" can be anything.
            guard AppFinder.isRealFolder(dir), Trasher.noLinksBetween(home, and: dir) else { continue }
            for entry in scan.names(dir, within: home) where !scan.shouldStop {
                let p = dir + "/" + entry
                var st = stat()
                guard linksIntoApp(p, app), lstat(p, &st) == 0 else { continue }
                var l = Leftover(path: p, bytes: Int64(st.st_blocks) * 512, place: "~/" + folder)
                l.evidence = .pointsIntoApp
                out.append(l)
            }
        }
        return out
    }

    /// Checked again before it moves: still a link into the app, directly in one of those folders.
    static func isStillCommandLink(_ path: String, of app: AppBundle, home: String) -> Bool {
        let dir = (path as NSString).deletingLastPathComponent
        return commandFolders.contains { dir == home + "/" + $0 } && Trasher.noLinksBetween(home, and: path) && linksIntoApp(path, app)
    }

    /// The app's command links in the system's and Homebrew's command
    /// folders, by folder: their names, never moved.
    public static func sharedCommandLinks(of app: AppBundle, base: String = "") -> [(folder: String, names: [String])] {
        sharedCommandFolders.compactMap { folder in
            let dir = base + folder
            let names = (DirectoryListing.names(dir) ?? []).sorted().filter { linksIntoApp(dir + "/" + $0, app) }
            return names.isEmpty ? nil : (dir, names)
        }
    }

    static func pointing(of app: AppBundle, lib: String, installed: [AppBundle], scan: LeftoverScan) -> [Leftover] {
        var out: [Leftover] = []
        let agents = lib + "/LaunchAgents"
        for entry in scan.names(agents, within: lib) where !scan.shouldStop {
            let p = agents + "/" + entry
            guard jobNamesApp(p, of: app, installed: installed), let m = scan.measure(p) else { continue }
            var l = Leftover(path: p, bytes: m, place: "LaunchAgents")
            l.evidence = .pointsIntoApp
            out.append(l)
        }
        for browser in browserFolders where !scan.shouldStop {
            let place = "Application Support/" + browser + "/" + messagingHosts
            let dir = lib + "/" + place
            for entry in scan.names(dir, within: lib) where !scan.shouldStop {
                let p = dir + "/" + entry
                guard hostNamesApp(p, of: app), let m = scan.measure(p) else { continue }
                var l = Leftover(path: p, bytes: m, place: place)
                l.evidence = .pointsIntoApp
                out.append(l)
            }
        }
        return out
    }

    /// Checked again before it moves, by the same file's contents.
    static func isStillPointing(_ path: String, of app: AppBundle, lib: String, installed: [AppBundle]) -> Bool {
        let dir = (path as NSString).deletingLastPathComponent
        if dir == lib + "/LaunchAgents" { return jobNamesApp(path, of: app, installed: installed) }
        guard browserFolders.contains(where: { dir == lib + "/Application Support/" + $0 + "/" + messagingHosts }) else { return false }
        return hostNamesApp(path, of: app)
    }

    // MARK: Folders the app names as its own

    /// What VS Code and the editors built from it (VSCodium, Cursor,
    /// Windsurf and others) name in their product.json: settings in
    /// Application Support by "nameShort" ("Code"), extensions in the home
    /// folder by "dataFolderName" (".vscode"). Relative to the home folder.
    public static func declaredFolders(of appPath: String) -> [String] {
        let path = appPath + "/Contents/Resources/app/product.json"
        guard Trasher.noLinksBetween(appPath, and: path), let data = smallFile(path),
              let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        func plain(_ s: String) -> Bool {
            !s.isEmpty && s.count <= 100 && s != "." && s != ".." && !s.contains("/") && !s.contains("\0")
        }
        var out: [String] = []
        if let name = d["nameShort"] as? String, plain(name), letters(name).count >= 3, !genericNames.contains(name.lowercased()),
           !name.lowercased().hasPrefix("com.apple.") {
            out.append("Library/Application Support/" + name)
        }
        if let folder = d["dataFolderName"] as? String, folder.hasPrefix("."), plain(folder), letters(folder).count >= 3,
           !sharedDotFolders.contains(folder.lowercased()) {
            out.append(folder)
        }
        return out
    }

    /// `folders` without those another installed app names as its own, or
    /// whose folder an app of that name would use.
    public static func unclaimed(_ folders: [String], by others: [AppBundle]) -> [String] {
        guard !folders.isEmpty else { return [] }
        var claimed = Set<String>()
        for other in others {
            claimed.formUnion(declaredFolders(of: other.path).map { $0.lowercased() })
            for form in nameForms(other.name) { claimed.insert("library/application support/" + form) }
        }
        return folders.filter { !claimed.contains($0.lowercased()) }
    }

    static func declared(of app: AppBundle, home: String, identity: AppIdentity, scan: LeftoverScan) -> [Leftover] {
        identity.folders.compactMap { rel in
            guard !scan.shouldStop else { return nil }
            let p = home + "/" + rel
            guard isDeclared(p, home: home), let m = scan.measure(p) else { return nil }
            var l = Leftover(path: p, bytes: m, place: rel.hasPrefix("Library/") ? "Application Support" : "Home")
            l.evidence = .declared
            return l
        }
    }

    static func isDeclared(_ path: String, home: String) -> Bool {
        !VendorRules.isNever(path, home: home) && Trasher.noLinksBetween(home, and: path) && AppFinder.isRealFolder(path)
    }

    /// Checked again before it moves: still a folder the app named, read before the app moved.
    static func isStillDeclared(_ path: String, of app: AppBundle, home: String, identity: AppIdentity) -> Bool {
        guard path.hasPrefix(home + "/") else { return false }
        return identity.folders.contains(String(path.dropFirst(home.count + 1))) && isDeclared(path, home: home)
    }
}
