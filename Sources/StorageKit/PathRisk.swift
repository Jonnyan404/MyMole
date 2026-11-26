import Darwin
import Foundation

/// A warning for something picked by hand, such as a folder marked in the
/// disk map: what it is, and how careful to be.
public struct PathRisk: Sendable, Hashable {
    public enum Level: Int, Sendable, Comparable {
        /// Usually fine, but may cost a re-download, a rebuild or a setting.
        case review
        /// Can't be recreated, or is your own data.
        case caution

        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    public let level: Level
    public let reason: String

    /// What one rule looks for in a path. Every pattern is ASCII, so the
    /// path is searched as bytes: the walk asks for every folder it reads.
    struct Pattern: Sendable {
        let anywhere: [[UInt8]]
        let atEnd: [[UInt8]]

        init(anywhere: [String] = [], atEnd: [String] = []) {
            self.anywhere = anywhere.map { Array($0.utf8) }
            self.atEnd = atEnd.map { Array($0.utf8) }
        }

        /// The folder or file itself, or anything inside it.
        static func within(_ parts: [String]) -> Pattern {
            Pattern(anywhere: parts.map { $0 + "/" }, atEnd: parts)
        }

        func matches(_ path: UnsafeRawBufferPointer) -> Bool {
            guard let base = path.baseAddress else { return false }
            for needle in anywhere where needle.count <= path.count && memmem(base, path.count, needle, needle.count) != nil { return true }
            for needle in atEnd where needle.count <= path.count && memcmp(base + (path.count - needle.count), needle, needle.count) == 0 {
                return true
            }
            return false
        }
    }

    static let rules: [(pattern: Pattern, risk: PathRisk)] = [
        (.within(["/.aws", "/.kube", "/.azure", "/.docker/config.json", "/.netrc", "/.npmrc", "/.config/gh", "/.config/gcloud"]),
         PathRisk(level: .caution, reason: String(localized: "Sign-in keys or tokens. Tools that use them sign you out."))),
        (.within([
            "/Library/Safari", "/Application Support/Google/Chrome", "/Application Support/Firefox/Profiles",
            "/Application Support/BraveSoftware", "/Application Support/Microsoft Edge", "/Application Support/Arc",
        ]),
         PathRisk(level: .caution, reason: String(localized: "A browser profile: history, bookmarks, saved passwords and sign-ins."))),
        (.within(["/.Trash"]),
         PathRisk(level: .caution, reason: String(localized: "Already in the Trash."))),
        (Pattern(anywhere: ["/MobileSync/Backup"]),
         PathRisk(level: .caution, reason: String(localized: "iPhone/iPad backup. Can't be recreated."))),
        (Pattern(anywhere: ["/Mobile Documents/"]),
         PathRisk(level: .caution, reason: String(localized: "iCloud Drive files. Removing them here removes them on your other devices too."))),
        // Dropbox, Google Drive, OneDrive, Box and other File Provider services.
        (Pattern(anywhere: ["/Library/CloudStorage/"]),
         PathRisk(level: .caution, reason: String(localized: "Synced with a cloud service. Removing it here removes it in the cloud and on your other devices too."))),
        (.within([".photoslibrary"]),
         PathRisk(level: .caution, reason: String(localized: "A Photos library: every photo, video and edit in it."))),
        (Pattern(anywhere: ["/Downloads/", "/Documents/", "/Desktop/", "/Pictures/", "/Movies/", "/Music/"]),
         PathRisk(level: .caution, reason: String(localized: "Your own files."))),
        (Pattern(anywhere: ["/Library/Mail/", "/Library/Messages/"]),
         PathRisk(level: .caution, reason: String(localized: "Mail or Messages data."))),
        (Pattern(anywhere: ["/com.docker.docker/Data/vms/"], atEnd: ["/Docker.raw"]),
         PathRisk(level: .caution, reason: String(localized: "Docker's virtual disk. Holds every image, container and volume."))),
        (Pattern(anywhere: [".vmwarevm", ".pvm", ".utm", "/VirtualBox VMs/", "/Parallels/", ".vdi", ".vmdk", ".qcow2"]),
         PathRisk(level: .caution, reason: String(localized: "A virtual machine and everything installed in it."))),
        (Pattern(anywhere: ["/Xcode/Archives"]),
         PathRisk(level: .caution, reason: String(localized: "Xcode archives. Needed to symbolicate crash reports of shipped builds."))),
        (Pattern(anywhere: ["/Group Containers/"]),
         PathRisk(level: .review, reason: String(localized: "Data shared between apps. May include settings."))),
        (Pattern(anywhere: ["/CoreSimulator/Devices"]),
         PathRisk(level: .review, reason: String(localized: "Simulator apps and their data."))),
    ]

    private static func withBytes<R>(_ text: String, _ body: (UnsafeRawBufferPointer) -> R) -> R {
        var text = text
        return text.withUTF8 { body(UnsafeRawBufferPointer($0)) }
    }

    /// The first rule that matches, if any.
    public static func of(_ path: String) -> PathRisk? {
        let code = code(of: path)
        return code >= 0 ? rules[Int(code)].risk : nil
    }

    static func code(of path: String) -> Int8 {
        withBytes(path) { bytes in rules.firstIndex(where: { $0.pattern.matches(bytes) }).map(Int8.init) ?? -1 }
    }

    static func merging(_ a: Int8, _ b: Int8) -> Int8 {
        guard a >= 0 else { return b }
        guard b >= 0 else { return a }
        let (x, y) = (rules[Int(a)].risk.level, rules[Int(b)].risk.level)
        return x == y ? min(a, b) : x > y ? a : b
    }

    static func decoded(_ code: Int8) -> PathRisk? {
        guard code >= 0, Int(code) < rules.count else { return nil }
        let risk = rules[Int(code)].risk
        return PathRisk(level: risk.level, reason: String(localized: "Inside: \(risk.reason)"))
    }

    // Ancestor-wide rules are checked once per directory, rather than once
    // per ordinary file. Only names that can add a new rule need a full path.
    private static let specificNames: Set<String> = [
        ".aws", ".kube", ".azure", ".netrc", ".npmrc", "config.json", "gh", "gcloud",
        "Safari", "Chrome", "Profiles", "BraveSoftware", "Microsoft Edge", "Arc", ".Trash",
        "Backup", "Docker.raw", "Archives", "Devices",
    ]
    private static let specificSuffixes = Pattern(anywhere: [".photoslibrary", ".vmwarevm", ".pvm", ".utm", ".vdi", ".vmdk", ".qcow2"])

    static func childCode(_ name: String, in parent: String) -> Int8 {
        guard specificNames.contains(name) || withBytes(name, specificSuffixes.matches) else { return -1 }
        return code(of: (parent == "/" ? "" : parent) + "/" + name)
    }

    public static let incomplete = PathRisk(level: .caution, reason: String(localized: "This folder wasn't fully scanned and may contain personal data. Check its location before moving it."))

    /// The gravest risk of anything inside `folder` as scanned, so marking a
    /// parent warns about what it holds. Looks at up to `limit` folders, and
    /// ends at the next folder once `stop` says so, with what it found by
    /// then. It reads the disk, so run it off the main thread for big folders.
    public static func inside(_ folder: Folder, limit: Int = 50_000, stop: () -> Bool = { false }) -> PathRisk? {
        var found: PathRisk?
        var stack = [folder]
        var seen = 0
        while let f = stack.popLast(), seen < limit, found?.level != .caution, !stop() {
            seen += 1
            // Every entry, small files included: the tree keeps only big
            // files by name, and a credential file is small.
            let names = (try? FileManager.default.contentsOfDirectory(atPath: f.path)) ?? f.listedFiles.map(\.name)
            for p in (f === folder ? [] : [f.path]) + names.map({ f.path + "/" + $0 }) {
                if let r = of(p), found.map({ r.level > $0.level }) ?? true { found = r }
            }
            stack += f.subfolders
        }
        return found.map { PathRisk(level: $0.level, reason: String(localized: "Inside: \($0.reason)")) }
    }
}
