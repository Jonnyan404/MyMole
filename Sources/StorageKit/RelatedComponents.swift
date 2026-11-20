import Darwin
import Foundation

/// Discovery only. A vendor updater is not proof of exclusive ownership by an app.
public enum RelatedComponents {
    public enum Scope: Equatable, Sendable { case user, system }
    public enum Kind: Equatable, Sendable { case updater, backgroundJob }
    public struct Component: Identifiable, Equatable, Sendable {
        public let path: String
        public let scope: Scope
        public let kind: Kind
        public var id: String { path }
    }
    public struct Report: Sendable {
        public var components: [Component] = []
        public var unreadable: [String] = []
        public init() {}
    }

    public static func isChrome(_ app: AppBundle) -> Bool {
        guard let id = app.bundleID?.lowercased() else { return false }
        return id == "com.google.chrome" || id.hasPrefix("com.google.chrome.")
    }

    public static func find(for app: AppBundle, home: String = Home.path, systemBase: String = "") -> Report {
        guard !app.isProtected, app.bundleID?.lowercased().hasPrefix("com.google.") == true else { return Report() }
        var report = Report()
        let roots: [(String, Scope)] = [(home + "/Library", .user), (systemBase + "/Library", .system)]
        for (library, scope) in roots {
            for relative in ["Application Support/Google/GoogleUpdater", "Google/GoogleSoftwareUpdate"] {
                let path = library + "/" + relative
                switch inspect(relative, in: library, directory: true) {
                case .present: report.components.append(Component(path: path, scope: scope, kind: .updater))
                case .unreadable: report.unreadable.append(path)
                case .missing: break
                }
            }
            for folder in scope == .user ? ["LaunchAgents"] : ["LaunchAgents", "LaunchDaemons"] {
                let dir = library + "/" + folder
                switch inspect(folder, in: library, directory: true) {
                case .missing: continue
                case .unreadable:
                    report.unreadable.append(dir)
                    continue
                case .present: break
                }
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
                    report.unreadable.append(dir)
                    continue
                }
                for name in names.sorted() where updaterJob(name) {
                    let relative = folder + "/" + name
                    switch inspect(relative, in: library, directory: false) {
                    case .present: report.components.append(Component(path: dir + "/" + name, scope: scope, kind: .backgroundJob))
                    case .unreadable: report.unreadable.append(dir + "/" + name)
                    case .missing: break
                    }
                }
            }
        }
        report.components.sort { $0.path < $1.path }
        report.unreadable = Array(Set(report.unreadable)).sorted()
        return report
    }

    private static func updaterJob(_ name: String) -> Bool {
        let name = name.lowercased()
        return name.hasSuffix(".plist") && ["com.google.googleupdater.", "com.google.keystone."].contains(where: name.hasPrefix)
    }

    private enum Inspection { case present, missing, unreadable }

    /// Inspect only named locations. Do not follow a directory or leaf symlink.
    private static func inspect(_ relative: String, in root: String, directory: Bool) -> Inspection {
        var path = root
        let parts = [""] + relative.split(separator: "/").map(String.init)
        for (index, part) in parts.enumerated() {
            if !part.isEmpty { path += "/" + part }
            var st = stat()
            guard lstat(path, &st) == 0 else { return errno == ENOENT || errno == ENOTDIR ? .missing : .unreadable }
            let expected = index < parts.count - 1 || directory ? S_IFDIR : S_IFREG
            guard st.st_mode & S_IFMT == expected else { return .unreadable }
        }
        return .present
    }
}

extension RelatedComponents {
    /// A part of an app that is only shown: macOS protects it, or every
    /// user of the Mac shares it. `path` is nil for what macOS lists by ID only.
    public struct Shown: Identifiable, Equatable, Sendable {
        public let path: String?
        public let name: String
        public let note: String
        public let bytes: Int64?
        public var id: String { path ?? name }
    }

    public static let systemExtensionsTool = "/usr/bin/systemextensionsctl"
    static let kernelNote = String(localized: "A kernel extension. macOS protects it: remove it with the vendor's uninstaller, then restart.")

    /// The app's protected and shared parts, by the vendor's list, by the
    /// bundle ID of each kernel extension, and by the system extensions
    /// macOS reports. Discovery only.
    public static func shown(for app: AppBundle, home: String = Home.path, systemBase: String = "", runner: CommandRunner) -> [Shown] {
        guard let id = app.bundleID, AppLeftovers.isWellFormed(id), !app.isProtected else { return [] }
        let spaces = VendorRules.makerNamespaces(for: id)
        func ours(_ other: String) -> Bool {
            let o = other.lowercased()
            return o == id.lowercased() || o.hasPrefix(id.lowercased() + ".") || spaces.contains { o.hasPrefix($0) }
        }
        var out: [Shown] = []
        for part in VendorRules.parts(for: id) where part.handling == .show {
            let path = part.inApp ? app.path + part.path.dropFirst("@app".count) : part.resolved(home: home, base: systemBase)
            var st = stat()
            guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR || st.st_mode & S_IFMT == S_IFREG else { continue }
            out.append(Shown(path: path, name: part.title ?? (path as NSString).lastPathComponent, note: part.note ?? VendorRules.protectedNote,
                             bytes: AppLeftovers.measure(path)))
        }
        let kexts = systemBase + "/Library/Extensions"
        for name in (DirectoryListing.names(kexts) ?? []).sorted() where name.lowercased().hasSuffix(".kext") {
            let path = kexts + "/" + name
            guard let kid = AppIdentity.bundleInfo(atPath: path)?["CFBundleIdentifier"] as? String, ours(kid) else { continue }
            out.append(Shown(path: path, name: name, note: kernelNote, bytes: AppLeftovers.measure(path)))
        }
        if runner.exists(systemExtensionsTool) {
            let r = runner.run(systemExtensionsTool, ["list"])
            if r.code == 0 {
                for ext in systemExtensions(r.output) where ours(ext.id) {
                    out.append(Shown(path: nil, name: ext.name, note: VendorRules.protectedNote + " (\(ext.id), \(ext.state))", bytes: nil))
                }
            }
        }
        return out
    }

    /// The extensions `systemextensionsctl list` prints, one per tab-separated row.
    static func systemExtensions(_ output: String) -> [(id: String, name: String, state: String)] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let index = fields.firstIndex(where: { $0.hasSuffix(")") && $0.contains(" (") }) else { return nil }
            let id = String(fields[index].prefix { $0 != " " })
            guard AppLeftovers.isWellFormed(id) else { return nil }
            let name = index + 1 < fields.count ? fields[index + 1] : id
            let state = fields.last.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) } ?? ""
            return (id, name.isEmpty ? id : name, state)
        }
    }
}
