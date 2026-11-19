import Darwin
import Foundation

/// What macOS counts as System Data, place by place: what each is, who
/// manages it, how much it takes and its largest files. Read only. Each
/// place says where its space can be won back, if anywhere; nothing here
/// removes anything.
public enum SystemData {
    /// Where a place's space can be won back.
    public enum Remedy: String, Sendable, Equatable {
        /// macOS frees it by itself when space is needed.
        case macOS
        /// Deep Clean lists what in it can go.
        case deepClean
        /// Developer Tools lists what in it can go.
        case developerTools
        /// Uninstall removes an app with its data here.
        case uninstall
        /// Only the app that keeps it should take it apart.
        case ownApp
        /// A restart gives it back.
        case restart
    }

    public struct Place: Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String
        public let detail: String
        /// The folders it measures; their sizes add up.
        public let paths: [String]
        public let remedy: Remedy
    }

    public struct Measured: Sendable, Equatable, Identifiable {
        public let place: Place
        /// Nil when none of its folders could be read.
        public let bytes: Int64?
        /// Some of its folders, or folders inside them, couldn't be read.
        public let partial: Bool
        /// The largest files in it, largest first.
        public let largest: [(path: String, bytes: Int64)]
        public var id: String { place.id }

        public static func == (a: Measured, b: Measured) -> Bool {
            a.place == b.place && a.bytes == b.bytes && a.partial == b.partial
                && a.largest.map(\.path) == b.largest.map(\.path) && a.largest.map(\.bytes) == b.largest.map(\.bytes)
        }
    }

    /// The places, for this user. Folders that don't exist are left out of a place's paths.
    public static func places(home: String = Home.path, temporary: String = NSTemporaryDirectory()) -> [Place] {
        let darwin = (temporary.hasSuffix("/") ? String(temporary.dropLast()) : temporary)
        let userFolders = (darwin as NSString).deletingLastPathComponent // …/T's parent holds C and 0
        return [
            Place(id: "vm", title: String(localized: "Swap and sleep image"),
                  detail: String(localized: "Memory macOS moved to the disk, and the copy of memory kept for sleep. macOS grows and shrinks them itself."),
                  paths: ["/private/var/vm"], remedy: .restart),
            Place(id: "temporary", title: String(localized: "Your temporary files and caches"),
                  detail: String(localized: "What programs keep for a while in the folders macOS gives each user for this."),
                  paths: [userFolders + "/T", userFolders + "/C"], remedy: .deepClean),
            Place(id: "caches", title: String(localized: "Caches in your Library"),
                  detail: String(localized: "Apps' caches and logs. Apps make them again when they need them."),
                  paths: [home + "/Library/Caches", home + "/Library/Logs"], remedy: .deepClean),
            Place(id: "appData", title: String(localized: "App data"),
                  detail: String(localized: "What apps keep in Application Support. It often holds settings and work; an app's own goes with it in Uninstall."),
                  paths: [home + "/Library/Application Support"], remedy: .uninstall),
            Place(id: "containers", title: String(localized: "App containers"),
                  detail: String(localized: "Sandboxed apps' own folders, with their data, caches and shared groups."),
                  paths: [home + "/Library/Containers", home + "/Library/Group Containers"], remedy: .uninstall),
            Place(id: "developer", title: String(localized: "Developer data"),
                  detail: String(localized: "Xcode's build data, simulators and device support."),
                  paths: [home + "/Library/Developer"], remedy: .developerTools),
            Place(id: "backups", title: String(localized: "iPhone and iPad backups"),
                  detail: String(localized: "Backups made on this Mac. Remove old ones in Finder, with the device's General settings."),
                  paths: [home + "/Library/Application Support/MobileSync/Backup"], remedy: .ownApp),
            Place(id: "mail", title: String(localized: "Mail and Messages"),
                  detail: String(localized: "Messages and their attachments. Remove them in Mail and Messages; Messages can keep them for a set time."),
                  paths: [home + "/Library/Mail", home + "/Library/Messages"], remedy: .ownApp),
            Place(id: "assets", title: String(localized: "macOS downloads"),
                  detail: String(localized: "Updates, voices, fonts and models macOS downloads for itself. macOS removes them when they're no longer needed."),
                  paths: ["/System/Library/AssetsV2", "/Library/Updates"], remedy: .macOS),
        ]
    }

    /// Measures each place in turn. A place inside another (backups inside
    /// App data) is taken out of the one holding it, so nothing counts twice.
    public static func measure(_ places: [Place], progress: ScanProgress = ScanProgress(), workers: Int = 2, largest: Int = 5,
                               each: (Measured) -> Void = { _ in }) -> [Measured] {
        var out: [Measured] = []
        let all = places.flatMap(\.paths)
        for place in places where !progress.isCancelled {
            var total: Int64 = 0, read = false, partial = false
            var files: [(path: String, bytes: Int64)] = []
            for path in place.paths where !progress.isCancelled {
                guard exists(path) else { continue }
                let r = StorageScanner.scan(path: path, progress: progress, workers: workers)
                guard !r.cancelled else { break }
                if r.root.unreadable { partial = true; continue }
                read = true
                if !r.deniedPaths.isEmpty { partial = true }
                total += r.root.size
                // A place measured on its own inside this one doesn't count here.
                for inner in all where inner != path && inner.hasPrefix(path + "/") {
                    if let f = r.root.find(path: inner) {
                        total -= f.size
                        f.parent?.remove(f)
                    }
                }
                files += biggest(in: r.root, count: largest)
            }
            files.sort { $0.bytes > $1.bytes }
            let m = Measured(place: place, bytes: read ? max(0, total) : nil, partial: partial || !read && place.paths.contains(where: exists),
                             largest: Array(files.prefix(largest)))
            out.append(m)
            each(m)
        }
        return out
    }

    static func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR
    }

    /// The largest listed files anywhere in the tree.
    static func biggest(in root: Folder, count: Int) -> [(path: String, bytes: Int64)] {
        var top: [(path: String, bytes: Int64)] = []
        func walk(_ f: Folder) {
            let base = f.path
            for file in f.listedFiles {
                guard top.count < count || file.size > top.last!.bytes else { continue }
                top.append((base + "/" + file.name, file.size))
                top.sort { $0.bytes > $1.bytes }
                if top.count > count { top.removeLast() }
            }
            for sub in f.subfolders { walk(sub) }
        }
        walk(root)
        return top
    }
}
