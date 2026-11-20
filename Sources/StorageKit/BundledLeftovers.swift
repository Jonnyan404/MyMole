import Darwin
import Foundation

/// What an app installs as bundles of their own in the user's Library
/// (web, Quick Look, Spotlight and audio plug-ins, preference panes,
/// screen savers, services, input methods), and the containers macOS
/// makes for its background services. Each is tied to the app by the ID
/// macOS itself reads: a bundle's own CFBundleIdentifier, a container's
/// recorded owner. A name alone never ties one.
extension AppLeftovers {
    /// Library folders that hold bundles, each with its own Info.plist.
    static let bundlePlaces = [
        "Internet Plug-Ins", "PreferencePanes", "QuickLook", "Screen Savers", "Services", "Spotlight", "ColorPickers",
        "Input Methods", "Audio/Plug-Ins/Components", "Audio/Plug-Ins/VST", "Audio/Plug-Ins/VST3", "Contextual Menu Items",
    ]

    /// Containers of sandboxed background services, named by a UUID.
    static let daemonContainers = "Daemon Containers"

    /// The file in a container where macOS records whose it is.
    static let containerMetadata = ".com.apple.containermanagerd.metadata.plist"

    /// Whether `bundleID` is the app's or a part's it carries, or an ID
    /// under one of those: never another installed app's that names it more closely.
    static func ownsID(_ bundleID: String, app: AppBundle, identity: AppIdentity, installed: [AppBundle]) -> Bool {
        guard let id = app.bundleID else { return false }
        let b = bundleID.lowercased()
        let own = ([id] + identity.helperIDs).map { $0.lowercased() }
        guard let mine = own.filter({ b == $0 || b.hasPrefix($0 + ".") }).max(by: { $0.count < $1.count }) else { return false }
        let others = installed.filter { $0.path != app.path }.compactMap { $0.bundleID?.lowercased() } + identity.otherOwnerIDs.map { $0.lowercased() }
        return !others.contains { o in o.count > mine.count && (b == o || b.hasPrefix(o + ".")) }
    }

    /// The owner macOS recorded for a container.
    static func containerOwner(_ dir: String) -> String? {
        VendorRules.readInfo(dir + "/" + containerMetadata)?["MCMMetadataIdentifier"] as? String
    }

    /// A bundle in `place` whose own ID is the app's, or a service container the app owns.
    static func ownsBundled(_ path: String, place: String, app: AppBundle, identity: AppIdentity, installed: [AppBundle]) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR || st.st_mode & S_IFMT == S_IFREG else { return false }
        let owner: String?
        if place == daemonContainers {
            guard st.st_mode & S_IFMT == S_IFDIR else { return false }
            owner = containerOwner(path)
        } else if bundlePlaces.contains(place) {
            owner = AppIdentity.bundleInfo(atPath: path)?["CFBundleIdentifier"] as? String
        } else {
            return false
        }
        guard let owner, isWellFormed(owner) else { return false }
        return ownsID(owner, app: app, identity: identity, installed: installed)
    }

    static func bundled(of app: AppBundle, lib: String, identity: AppIdentity, installed: [AppBundle], scan: LeftoverScan) -> [Leftover] {
        var out: [Leftover] = []
        for place in bundlePlaces + [daemonContainers] where !scan.shouldStop {
            let dir = lib + "/" + place
            for entry in scan.names(dir, within: lib) where !scan.shouldStop && !entry.hasPrefix(".") {
                let p = dir + "/" + entry
                guard ownsBundled(p, place: place, app: app, identity: identity, installed: installed),
                      let m = scan.measure(p) else { continue }
                var l = Leftover(path: p, bytes: m, place: place)
                l.evidence = .bundleID
                out.append(l)
            }
        }
        return out
    }

    /// Checked again before it moves, by the same ID.
    static func isStillBundled(_ path: String, of app: AppBundle, lib: String, identity: AppIdentity, installed: [AppBundle]) -> Bool {
        let folder = ((path.hasPrefix(lib + "/") ? String(path.dropFirst(lib.count + 1)) : "") as NSString).deletingLastPathComponent
        guard bundlePlaces.contains(folder) || folder == daemonContainers else { return false }
        return ownsBundled(path, place: folder, app: app, identity: identity, installed: installed)
    }

    /// Paths a vendor's rule only shows, with what to do instead: never offered as leftovers.
    static func shownOnly(for app: AppBundle, home: String) -> Set<String> {
        guard let id = app.bundleID else { return [] }
        return Set(VendorRules.parts(for: id).filter { $0.handling == .show && $0.inHome }.map { $0.resolved(home: home) })
    }
}
