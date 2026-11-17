import Darwin
import Foundation
import StorageKit

/// What an app left outside your Library, in places only root may change:
/// its system-wide data and settings, its launchd jobs and privileged
/// helper, and the installer's record of it. The app finds them, the
/// helper checks every path against these rules again and removes them.
/// Only exact bundle IDs in the vendor's namespace are matched, never
/// names, and never Apple's.
public enum SystemLeftovers {
    public enum Kind: String, Codable, Sendable {
        case rebuildable, appPart, record, settings, data

        /// Permanent system removal always needs an explicit per-item choice.
        public var chosenByDefault: Bool { false }

        public var title: String {
            switch self {
            case .rebuildable: "Rebuilt"
            case .appPart: "App part"
            case .record: "Installer record"
            case .settings: "Settings"
            case .data: "Data"
            }
        }
    }

    enum Rule { case exactID, idPlist, jobPlist, idOrPart, receipt }

    struct Place {
        let folder: String
        let rule: Rule
        let kind: Kind
    }

    /// Launch daemons come first: a job is stopped before its program goes.
    static let places: [Place] = [
        Place(folder: "/Library/LaunchDaemons", rule: .jobPlist, kind: .appPart),
        Place(folder: "/Library/LaunchAgents", rule: .jobPlist, kind: .appPart),
        Place(folder: "/Library/PrivilegedHelperTools", rule: .idOrPart, kind: .appPart),
        Place(folder: "/Library/Caches", rule: .exactID, kind: .rebuildable),
        Place(folder: "/Library/Logs", rule: .exactID, kind: .rebuildable),
        Place(folder: "/Library/Preferences", rule: .idPlist, kind: .settings),
        Place(folder: "/Library/Application Support", rule: .exactID, kind: .data),
        Place(folder: "/private/var/db/receipts", rule: .receipt, kind: .record),
    ]

    static let launchctl = "/bin/launchctl"

    /// An ID safe to match system-wide: three or more reverse-DNS parts,
    /// not Apple's.
    public static func isUsable(_ id: String) -> Bool {
        AppLeftovers.isWellFormed(id) && id.split(separator: ".").count >= 3 && !id.lowercased().hasPrefix("com.apple.")
    }

    static func matches(_ entry: String, id: String, rule: Rule) -> Bool {
        let entry = entry.lowercased()
        let id = id.lowercased()
        return switch rule {
        case .exactID: entry == id
        case .idPlist: entry == id + ".plist"
        case .jobPlist: entry.hasSuffix(".plist") && (entry == id + ".plist" || entry.hasPrefix(id + "."))
        case .idOrPart: entry == id || entry.hasPrefix(id + ".")
        case .receipt:
            (entry.hasSuffix(".bom") || entry.hasSuffix(".plist"))
                && (entry.hasPrefix(id + ".") || entry == id + ".bom" || entry == id + ".plist")
        }
    }

    /// The app the leftovers are of: its bundle ID, and where it is or was
    /// (absolute, without the base), which ties the installer's record to it.
    public struct Origin: Codable, Sendable, Equatable {
        public let id: String
        public let path: String
        public init(id: String, path: String) {
            self.id = id
            self.path = path
        }
    }

    /// How a system leftover is tied to the app, beyond its exact ID.
    public enum Why: String, Codable, Sendable {
        /// On the vendor's own list of what the app installs, at that path.
        case vendorList
        /// A launch job or helper of the app's maker, with none of the maker's apps left.
        case maker
        /// The installer's record of the app, which installed this app alone.
        case record
        /// Installed by that record, and by no other.
        case installedWith
        /// A driver or plug-in whose own bundle ID is the app's.
        case component

        public var title: String {
            switch self {
            case .vendorList: "on the vendor's own list of what the app installs"
            case .maker: "its maker's, and no other app of the maker is left"
            case .record: "the installer's record of this app alone"
            case .installedWith: "installed by the app's own installer, and by no other"
            case .component: "a driver or plug-in that carries the app's ID"
            }
        }
    }

    /// Every leftover of `ids` under `base` (empty: the real system),
    /// daemons first. With `app`, also what the vendor lists, the maker's
    /// jobs once its last app goes, the app's installer record and what
    /// only that record installed.
    public static func find(ids: [String], base: String = "", app: Origin? = nil) -> [SystemLeftover] {
        let usable = ids.filter(isUsable)
        var out: [SystemLeftover] = []
        for place in places where !usable.isEmpty {
            let dir = base + place.folder
            for name in ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted()
            where usable.contains(where: { matches(name, id: $0, rule: place.rule) }) {
                let path = dir + "/" + name
                guard let bytes = size(path) else { continue }
                out.append(SystemLeftover(path: path, bytes: bytes, place: place.folder, kind: place.kind))
            }
        }
        guard let app, let owners = ownerMap(base: base) else { return out }
        let known = Set(out.map(\.path))
        for c in extras(for: app, ids: ids, base: base, owners: owners) where !known.contains(c.path) {
            guard let bytes = size(c.path) else { continue }
            var l = SystemLeftover(path: c.path, bytes: bytes, place: c.place, kind: c.kind)
            l.why = c.why
            out.append(l)
        }
        return out
    }

    /// A system leftover found by a rule beyond the exact-ID places.
    struct Extra {
        let path: String
        let place: String
        let kind: Kind
        let why: Why
        /// The labels a launch job here may have to be stopped.
        let label: (String) -> Bool
        /// Whether the apps still installed leave it free to go.
        let free: ([Owner]) -> Bool
    }

    static let jobFolders = ["/Library/LaunchDaemons", "/Library/LaunchAgents", "/Library/PrivilegedHelperTools"]
    /// Drivers and plug-ins the system loads for every app. Never audio
    /// units or instruments: those are the user's, whoever made them.
    static let componentFolders = ["/Library/Audio/Plug-Ins/HAL", "/Library/Internet Plug-Ins", "/Library/CoreMediaIO/Plug-Ins/DAL"]

    static func kind(_ k: VendorRules.Kind) -> Kind {
        switch k {
        case .appPart: .appPart
        case .data: .data
        case .settings: .settings
        case .rebuildable: .rebuildable
        case .record: .record
        }
    }

    /// "us.zoom.ZoomDaemon" of "us.zoom.ZoomDaemon.plist".
    static func stem(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.hasSuffix(".plist") ? String(name.dropLast(6)) : name
    }

    /// A real file or folder, plainly written, with no link from the base on.
    static func isReal(_ path: String, base: String) -> Bool {
        guard Trasher.isPlainPath(path), Trasher.noLinksBetween(base.isEmpty ? "/" : base, and: path),
              (path as NSString).lastPathComponent != Staging.containerName else { return false }
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT == S_IFDIR || st.st_mode & S_IFMT == S_IFREG)
    }

    static func bundleID(_ path: String) -> String? {
        let info = AppIdentity.bundleInfo(atPath: path) ?? {
            guard let data = FileManager.default.contents(atPath: path + "/Info.plist"), data.count <= 1 << 20 else { return nil }
            return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        }()
        guard let id = info?["CFBundleIdentifier"] as? String, AppLeftovers.isWellFormed(id) else { return nil }
        return id
    }

    /// Owners other than the app itself, and other than apps inside `path`
    /// (an updater app inside the updater's own folder).
    static func others(_ owners: [Owner], besides app: Origin, inside path: String? = nil, base: String) -> [Owner] {
        owners.filter { o in
            (app.path.isEmpty || (o.path != app.path && !o.path.hasPrefix(app.path + "/")))
                && !(path.map { p in o.path == String(p.dropFirst(base.count)) || o.path.hasPrefix(String(p.dropFirst(base.count)) + "/") } ?? false)
        }
    }

    /// Named after an installed app: then it's that app's, whatever a rule says.
    static func namedForOwner(_ path: String, _ owners: [Owner]) -> Bool {
        let name = stem(path).lowercased()
        let bare = name.hasSuffix(".bom") ? String(name.dropLast(4)) : name
        return owners.contains { $0.ids.contains { bare == $0 || bare.hasPrefix($0 + ".") } }
    }

    static func extras(for app: Origin, ids: [String], base: String, owners: [Owner]) -> [Extra] {
        guard AppLeftovers.isWellFormed(app.id) else { return [] }
        var out: [Extra] = []
        var seen = Set<String>()
        func add(_ e: Extra) {
            guard !VendorRules.isNever(e.path, home: "/var/empty", base: base), isReal(e.path, base: base),
                  e.free(owners), !namedForOwner(e.path, others(owners, besides: app, base: base)), seen.insert(e.path).inserted else { return }
            out.append(e)
        }
        let family = ([app.id] + ids).map { $0.lowercased() }
        func isFamily(_ id: String) -> Bool { family.contains { id.lowercased() == $0 || id.lowercased().hasPrefix($0 + ".") } }

        // The vendor's own list.
        for part in VendorRules.offered(for: app.id, home: "/var/empty", base: base) where !part.inHome {
            let path = part.resolved(home: "", base: base)
            guard VendorRules.bundleMatches(part, at: path) else { continue }
            let stemName = stem(path)
            add(Extra(path: path, place: (part.path as NSString).deletingLastPathComponent, kind: kind(part.kind), why: .vendorList,
                      label: { $0 == stemName }, free: { all in
                          let rest = Set(others(all, besides: app, inside: path, base: base).flatMap(\.ids))
                          return VendorRules.isFree(part, owners: rest, app: [app.id] + ids) && VendorRules.bundleMatches(part, at: path)
                      }))
        }

        // The maker's launch jobs and helpers, once none of its apps is left.
        let spaces = VendorRules.makerNamespaces(for: app.id)
        func makerFree(_ space: String) -> ([Owner]) -> Bool {
            { all in !others(all, besides: app, base: base).contains { $0.ids.contains { $0.hasPrefix(space) } } }
        }
        for folder in jobFolders {
            for name in (DirectoryListing.names(base + folder) ?? []).sorted() {
                let lower = name.lowercased()
                guard let space = spaces.first(where: { lower.hasPrefix($0) }), AppLeftovers.isWellFormed(stem(name)) else { continue }
                add(Extra(path: base + folder + "/" + name, place: folder, kind: .appPart, why: .maker,
                          label: { $0.lowercased().hasPrefix(space) }, free: makerFree(space)))
            }
        }

        // Drivers and plug-ins by their own bundle ID.
        for folder in componentFolders {
            for name in (DirectoryListing.names(base + folder) ?? []).sorted() {
                let path = base + folder + "/" + name
                guard let id = bundleID(path) else { continue }
                if isFamily(id) {
                    add(Extra(path: path, place: folder, kind: .appPart, why: .component, label: { _ in false }, free: { _ in bundleID(path).map(isFamily) ?? false }))
                } else if let space = spaces.first(where: { id.lowercased().hasPrefix($0) }) {
                    let free = makerFree(space)
                    add(Extra(path: path, place: folder, kind: .appPart, why: .maker, label: { _ in false }, free: { all in
                        free(all) && bundleID(path)?.lowercased().hasPrefix(space) == true
                    }))
                }
            }
        }

        // The installer's record of this app alone, and what only it installed.
        guard !app.path.isEmpty, let receipts = InstallerReceipts.all(base: base) else { return out }
        var tied: [InstallerReceipts.Receipt] = []
        var untied: [InstallerReceipts.Receipt] = []
        for r in receipts {
            if InstallerReceipts.installsOnly(r, app: app.path) { tied.append(r) } else { untied.append(r) }
        }
        // What other records installed; unknown when one can't be read.
        var claimed: Set<String>?? = .none
        func claimedElsewhere() -> Set<String>? {
            if case .some(let known) = claimed { return known }
            var all = Set<String>()
            var complete = true
            for r in untied {
                guard let paths = InstallerReceipts.installed(r) else { complete = false; break }
                all.formUnion(paths.map { $0.lowercased() })
            }
            claimed = .some(complete ? all : nil)
            return complete ? all : nil
        }
        let parts = Set(jobFolders + componentFolders)
        // The record's tie is read once per request: its two files go one
        // after the other, and the other apps are checked again for each.
        for r in tied {
            for file in [r.bom, r.plist] {
                add(Extra(path: file, place: InstallerReceipts.folder, kind: .record, why: .record, label: { _ in false }, free: { _ in true }))
            }
            for installed in InstallerReceipts.installed(r) ?? [] where parts.contains((installed as NSString).deletingLastPathComponent) {
                guard let elsewhere = claimedElsewhere(), !elsewhere.contains(installed.lowercased()) else { continue }
                let folder = (installed as NSString).deletingLastPathComponent
                let stemName = stem(installed)
                add(Extra(path: base + installed, place: folder, kind: .appPart, why: .installedWith,
                          label: { $0 == stemName }, free: { _ in true }))
            }
        }
        return out
    }

    /// Right inside one of the places, plainly written, a real file or
    /// folder, and named after one of `ids` by that place's rule.
    static func allowed(_ path: String, ids: [String], base: String = "") -> Place? {
        guard Trasher.isPlainPath(path) else { return nil }
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        guard let place = places.first(where: { base + $0.folder == parent }), name != Staging.containerName,
            ids.filter(isUsable).contains(where: { matches(name, id: $0, rule: place.rule) }),
            size(path) != nil
        else { return nil }
        return place
    }

    /// An installed app: where it is, and the IDs it and what it carries answer to, in lower case.
    struct Owner: Sendable {
        let path: String
        let ids: Set<String>
    }

    /// What every app still installed answers to: its bundle ID and the
    /// identities it carries.
    static func installedOwners(base: String) -> Set<String>? {
        ownerMap(base: base).map { Set($0.flatMap(\.ids)) }
    }

    /// Folders apps are installed in, besides the Applications folders:
    /// vendors put updaters and helper apps in Application Support.
    static let ownerSupport = "/Library/Application Support"
    /// How deep inside a root folders are looked through, and how many
    /// entries in all before the map counts as unknown.
    static let ownerDepth = 3
    static let ownerBudget = 100_000
    /// Folders whose contents are code of their own, never holding installed apps.
    static let bundleExtensions: Set<String> = ["framework", "bundle", "plugin", "kext", "driver", "xpc", "appex", "component", "vst", "vst3", "systemextension"]

    /// Every installed app under /Applications, each user's Applications
    /// folder and /Library/Application Support, a few folders deep. Nil when
    /// /Applications can't be read, a folder there can't be read, or an app's
    /// identity can't be: then ownership can't be checked and nothing goes.
    /// Apple's own folders in Application Support are not looked through.
    static func ownerMap(base: String) -> [Owner]? {
        func names(_ dir: String) -> [String]? { DirectoryListing.names(dir) }
        // /Applications is always there: missing, it's a map of nothing.
        guard (try? FileManager.default.contentsOfDirectory(atPath: base + "/Applications")) != nil, let users = names(base + "/Users")
        else { return nil }
        var roots: [(path: String, strict: Bool)] = [(base + "/Applications", true)]
        for user in users {
            let home = base + "/Users/" + user
            var st = stat()
            guard lstat(home, &st) == 0, st.st_mode & S_IFMT != S_IFLNK else { return nil }
            guard st.st_mode & S_IFMT == S_IFDIR else { continue }
            guard names(home + "/Applications") != nil else { return nil }
            roots.append((home + "/Applications", true))
        }
        var support = stat()
        if lstat(base + ownerSupport, &support) == 0, support.st_mode & S_IFMT == S_IFDIR { roots.append((base + ownerSupport, false)) }
        var owners: [Owner] = []
        var budget = ownerBudget
        func walk(_ dir: String, depth: Int, strict: Bool, top: Bool) -> Bool {
            guard let inside = names(dir) else { return false }
            budget -= inside.count
            guard budget >= 0 else { return false }
            for name in inside {
                let path = dir + "/" + name
                if top && !strict && (name.hasPrefix(".") || name == "Apple" || name.lowercased().hasPrefix("com.apple.")) { continue }
                var st = stat()
                guard lstat(path, &st) == 0 else { return false }
                let isLink = st.st_mode & S_IFMT == S_IFLNK
                if name.lowercased().hasSuffix(".app") {
                    guard !isLink, st.st_mode & S_IFMT == S_IFDIR else { return false }
                    let plist = path + "/Contents/Info.plist"
                    var info = stat()
                    // Not a bundle at all: nothing to own anything.
                    if lstat(plist, &info) != 0 && errno == ENOENT { continue }
                    guard info.st_mode & S_IFMT == S_IFREG, Trasher.noLinksBetween(path, and: path + "/Contents"),
                          let id = AppIdentity.bundleInfo(atPath: path)?["CFBundleIdentifier"] as? String, AppLeftovers.isWellFormed(id),
                          let carried = AppIdentity.carried(atPath: path) else { return false }
                    owners.append(Owner(path: String(path.dropFirst(base.count)), ids: Set([id.lowercased()] + carried.map { $0.lowercased() })))
                    continue
                }
                // A link in the Applications folders could hide an app; elsewhere it's not followed.
                if isLink {
                    if strict && top { return false }
                    continue
                }
                guard st.st_mode & S_IFMT == S_IFDIR, depth < ownerDepth,
                      !bundleExtensions.contains((name as NSString).pathExtension.lowercased()) else { continue }
                guard walk(path, depth: depth + 1, strict: strict, top: false) else { return false }
            }
            return true
        }
        for root in roots {
            guard walk(root.path, depth: 0, strict: root.strict, top: true) else { return nil }
        }
        return owners
    }

    /// The IDs a request may name: the app's own, and others in the app's
    /// vendor namespace. Anything else a client sends is ignored.
    static func requestable(appID: String, ids: [String]) -> [String] {
        guard isUsable(appID), let space = AppIdentity.namespace(of: appID) else { return [] }
        return Array(Set([appID] + ids.filter { isUsable($0) && $0.hasPrefix(space) })).sorted()
    }

    /// Removes what passes `allowed`, permanently. Nothing goes while the
    /// app itself is installed, and no entry that matches an app still
    /// installed, or something one carries, whatever the request says. A
    /// launch daemon's job is stopped first; one that can't be stopped
    /// stays, and so does one whose job isn't named after the app: its
    /// file would go while the job ran on until the next restart.
    /// One removal runs at a time; each stages only its own entries.
    public static func remove(
        _ paths: [String], appID: String, ids: [String], appPath: String? = nil, base: String = "",
        runner: CommandRunner = .processes(timeLimit: 30)
    ) -> RemovalReport {
        Staging.lock.lock()
        defer { Staging.lock.unlock() }
        var report = RemovalReport()
        let all = requestable(appID: appID, ids: ids)
        let origin = Origin(id: appID, path: appPath ?? "")
        let hasRules = AppLeftovers.isWellFormed(appID) && (!VendorRules.rules(for: appID).isEmpty || !VendorRules.makerNamespaces(for: appID).isEmpty)
        guard !all.isEmpty || hasRules, let owners = installedOwners(base: base), !owners.contains(appID.lowercased()) else {
            report.refused = paths
            return report
        }
        let order = Dictionary(uniqueKeysWithValues: places.enumerated().map { (base + $1.folder, $0) })
        let sorted = Set(paths).sorted {
            let a = order[($0 as NSString).deletingLastPathComponent] ?? .max
            let b = order[($1 as NSString).deletingLastPathComponent] ?? .max
            return a != b ? a < b : $0 < $1
        }
        // What the rules beyond the exact-ID places allow, planned once; each
        // is checked against the apps installed again before it goes.
        let planned = ownerMap(base: base).map { extras(for: origin, ids: all, base: base, owners: $0) } ?? []
        var staging = Staging()
        defer { staging.finish() }
        for path in sorted {
            let name = (path as NSString).lastPathComponent
            guard let map = ownerMap(base: base), !map.contains(where: { $0.ids.contains(appID.lowercased()) }) else {
                report.refused.append(path)
                continue
            }
            let current = Set(map.flatMap(\.ids))
            // The exact-ID places first, then the rules beyond them.
            let labelOK: (String) -> Bool
            let recheck: (String) -> Bool
            if let place = allowed(path, ids: all, base: base) {
                guard !current.contains(where: { matches(name, id: $0, rule: place.rule) }) else {
                    report.refused.append(path)
                    continue
                }
                labelOK = { label in all.contains(where: { label == $0 || label.hasPrefix($0 + ".") }) }
                recheck = { _ in
                    guard let latest = installedOwners(base: base), !latest.contains(appID.lowercased()) else { return false }
                    return !latest.contains { matches(name, id: $0, rule: place.rule) }
                }
            } else if Trasher.isPlainPath(path), let extra = planned.first(where: { $0.path == path }), isReal(path, base: base),
                      extra.free(map), !namedForOwner(path, others(map, besides: origin, base: base)) {
                labelOK = extra.label
                recheck = { _ in
                    guard let latest = ownerMap(base: base), !latest.contains(where: { $0.ids.contains(appID.lowercased()) }) else { return false }
                    return extra.free(latest) && !namedForOwner(path, others(latest, besides: origin, base: base))
                }
            } else {
                report.refused.append(path)
                continue
            }
            if (path as NSString).deletingLastPathComponent == base + "/Library/LaunchDaemons", let label = label(path) {
                // Only a job named after the app or its maker is stopped: the
                // tool never stops one by a name that just happens to be in the file.
                guard AppLeftovers.isWellFormed(label), labelOK(label) else {
                    report.failed[path] = "Its job isn't named after the app, so it stays."
                    continue
                }
                if let why = stop(label, runner: runner) {
                    report.failed[path] = why
                    continue
                }
            }
            removeStaged(path, staging: &staging, recheck: { candidate in
                size(candidate) != nil && recheck(candidate)
            }, size: { size($0) ?? 0 }, report: &report)
        }
        return report
    }

    /// Stops a launch daemon. Nil when it's stopped or wasn't loaded; why
    /// it may still run otherwise.
    static func stop(_ label: String, runner: CommandRunner) -> String? {
        let r = runner.run(launchctl, ["bootout", "system/" + label])
        // 3: no such process; 113: no such service. Both mean not loaded.
        if r.code == 0 || r.code == 3 || r.code == 113 { return nil }
        if r.code == CommandRunner.timedOut { return "Its job didn't stop in time, so it stays." }
        return "Its job couldn't be stopped (launchctl \(r.code)), so it stays."
    }

    /// The label a launchd job's file gives it. Nil when it has none: it
    /// can't have been loaded as a job then, so there's nothing to stop.
    static func label(_ plist: String) -> String? {
        NSDictionary(contentsOfFile: plist)?["Label"] as? String
    }

    /// Size of a real file or folder, nil for anything else.
    static func size(_ path: String) -> Int64? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        switch st.st_mode & S_IFMT {
        case S_IFDIR: return StorageScanner.scan(path: path, workers: 2).root.size
        case S_IFREG: return Int64(st.st_blocks) * 512
        default: return nil
        }
    }
}

public struct SystemLeftover: Codable, Sendable, Hashable, Identifiable {
    public let path: String
    public let bytes: Int64
    public let place: String
    public let kind: SystemLeftovers.Kind
    /// How it's tied to the app when not by its exact ID.
    public var why: SystemLeftovers.Why?

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }

    public init(path: String, bytes: Int64, place: String, kind: SystemLeftovers.Kind) {
        self.path = path
        self.bytes = bytes
        self.place = place
        self.kind = kind
    }
}
