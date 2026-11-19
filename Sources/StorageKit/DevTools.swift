import Darwin
import Foundation

/// What developer tools keep outside projects: Docker's images, containers,
/// volumes and build cache, the simulator runtimes and devices Xcode can no
/// longer use, Android's virtual devices and system images, and virtual
/// machines. Read from each tool's own listing or files, and removed only
/// through the tool itself, by exact ID, one item the user chose at a time.
/// What rebuilds by itself may be recommended; what holds work is only
/// offered; what is in use, or holds data no tool can rebuild, is only shown.
public enum DevTools {
    public enum Handling: String, Sendable, Codable, Comparable {
        /// Rebuilt or downloaded again by the tool: chosen for the user.
        case recommend
        /// May hold work: only on the user's own choice.
        case offer
        /// In use, or data the tool can't rebuild: never removed here.
        case show

        public static func < (a: Self, b: Self) -> Bool {
            [Self.recommend, .offer, .show].firstIndex(of: a)! < [Self.recommend, .offer, .show].firstIndex(of: b)!
        }
    }

    public enum Source: String, Sendable, Codable, CaseIterable {
        case docker, simulator, android, virtualMachine, aiModels

        public var title: String {
            switch self {
            case .docker: "Docker"
            case .simulator: String(localized: "Xcode Simulators")
            case .android: "Android"
            case .virtualMachine: String(localized: "Virtual Machines")
            case .aiModels: String(localized: "AI Models")
            }
        }
    }

    /// The exact command that removes an item, never built from text a tool printed
    /// without checking it first.
    public enum Removal: Equatable, Sendable {
        /// `docker` with these arguments.
        case command([String])
        /// `/usr/bin/xcrun` with these arguments.
        case xcrun([String])
        /// A tool at this path with these arguments.
        case tool(String, [String])
        /// These files and folders, to the Trash, each checked again right before it moves.
        case trash([String])
    }

    public struct Item: Identifiable, Equatable, Sendable {
        public let id: String
        public let source: Source
        public let name: String
        public let detail: String
        public let bytes: Int64?
        public let handling: Handling
        /// Why it's recommended, offered or only shown.
        public let reason: String
        public let removal: Removal?
        public let path: String?
    }

    public struct Tools: Sendable, Equatable {
        public var docker: String?
        public var xcrun: String?

        public init(docker: String? = nil, xcrun: String? = nil) {
            self.docker = docker
            self.xcrun = xcrun
        }

        /// Where Docker and Xcode's command tools are on this Mac.
        public static func find(home: String, exists: (String) -> Bool) -> Tools {
            let docker = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", home + "/.docker/bin/docker",
                          "/Applications/Docker.app/Contents/Resources/bin/docker"].first(where: exists)
            return Tools(docker: docker, xcrun: exists(xcrunPath) ? xcrunPath : nil)
        }
    }

    public static let xcrunPath = "/usr/bin/xcrun"

    public struct Listing: Sendable {
        public var items: [Item] = []
        /// What couldn't be listed and why ("Docker isn't running").
        public var notes: [String] = []
        public init() {}
    }

    public struct Report: Sendable, Equatable {
        public var removed: [String] = []
        public var refused: [String] = []
        public var failed: [String: String] = [:]
        public init() {}
    }

    // MARK: Everything

    /// `trash` is whether this edition may move models to the Trash.
    public static func inventory(home: String, tools: Tools, runner: CommandRunner, running: Set<String>?, trash: Bool = false) -> Listing {
        var out = Listing()
        if let docker = tools.docker {
            let r = runner.run(docker, dockerList)
            if r.code == 0, let items = DevTools.docker(json: r.output) { out.items += items } else {
                out.notes.append(String(localized: "Docker didn't answer, so its images, containers and volumes aren't listed. Start Docker and look again."))
            }
        }
        if let xcrun = tools.xcrun {
            let d = runner.run(xcrun, simctlDevices), rt = runner.run(xcrun, simctlRuntimes)
            if d.code == 0, rt.code == 0, let items = simulators(devices: d.output, runtimes: rt.output) { out.items += items } else if d.code == 0 || rt.code == 0 {
                out.notes.append(String(localized: "Xcode's simulator tool didn't list everything, so some runtimes or simulators may be missing."))
            }
        }
        out.items += android(home: home, toolExists: runner.exists)
        out.items += virtualMachines(home: home, running: running ?? [])
        out.items += aiModels(homes: ModelHomes(home: home), running: running, trash: trash)
        out.items.sort { ($0.source.rawValue, $0.handling, -($0.bytes ?? 0), $0.name) < ($1.source.rawValue, $1.handling, -($1.bytes ?? 0), $1.name) }
        return out
    }

    /// Removes each item the user chose, after reading its tool's inventory
    /// again: an item that is no longer there, or no longer removable the
    /// same way, is refused. A shown item never goes.
    /// Models go to the Trash through `backend`, never past the Deep Clean
    /// keep list, and only while the place they're in is as it was listed.
    public static func remove(
        _ items: [Item], tools: Tools, home: String, runner: CommandRunner,
        running: @Sendable () -> Set<String>? = { RunningTools.names() }, trash: Bool = false, backend: TrashBackend = .system,
        protections: @escaping @Sendable () throws -> @Sendable (String) -> Bool = { let k = try CleanKeepList.load().resolved; return { k.protects($0) } }
    ) -> Report {
        var report = Report()
        for item in items {
            guard item.handling != .show, let removal = item.removal,
                  let fresh = current(item.source, tools: tools, home: home, runner: runner, running: running, trash: trash),
                  let now = fresh.first(where: { $0.id == item.id }), now.handling != .show, now.removal == removal
            else {
                report.refused.append(item.id)
                continue
            }
            let r: (code: Int32, output: String)
            switch removal {
            case .command(let args):
                guard let docker = tools.docker else { report.refused.append(item.id); continue }
                r = runner.run(docker, args)
            case .xcrun(let args):
                guard let xcrun = tools.xcrun else { report.refused.append(item.id); continue }
                r = runner.run(xcrun, args)
            case .tool(let path, let args):
                r = runner.run(path, args)
            case .trash(let paths):
                let homes = ModelHomes(home: home)
                let bases = [homes.ollama, homes.huggingFace] + homes.lmStudio
                let gate = TrashGate(still: { p in
                    bases.contains { b in p.hasPrefix(b + "/") && Trasher.noLinksBetween(b, and: p) } && FileManager.default.fileExists(atPath: p)
                }, protections: protections)
                let outcome = Trasher.moveToTrash(paths, through: gate, backend: backend)
                let moved = Set(outcome.moved.map(\.original.path))
                r = moved == Set(paths) ? (0, "")
                    : (1, outcome.failed.first?.reason ?? String(localized: "\(paths.count - moved.count) of its files stayed where they were."))
            }
            if r.code == 0 {
                report.removed.append(item.id)
            } else {
                let last = r.output.split(separator: "\n").last.map(String.init) ?? ""
                report.failed[item.id] = last.isEmpty ? String(localized: "The tool stopped with code \(r.code).") : last
            }
        }
        return report
    }

    static func current(_ source: Source, tools: Tools, home: String, runner: CommandRunner,
                        running: () -> Set<String>? = { RunningTools.names() }, trash: Bool = false) -> [Item]? {
        switch source {
        case .docker:
            guard let docker = tools.docker else { return nil }
            let r = runner.run(docker, dockerList)
            return r.code == 0 ? DevTools.docker(json: r.output) : nil
        case .simulator:
            guard let xcrun = tools.xcrun else { return nil }
            let d = runner.run(xcrun, simctlDevices), rt = runner.run(xcrun, simctlRuntimes)
            return d.code == 0 && rt.code == 0 ? simulators(devices: d.output, runtimes: rt.output) : nil
        case .android: return android(home: home, toolExists: runner.exists)
        case .virtualMachine: return nil
        case .aiModels: return aiModels(homes: ModelHomes(home: home), running: running(), trash: trash)
        }
    }

    // MARK: Docker

    static let dockerList = ["system", "df", "-v", "--format", "json"]

    /// "1.5GB", "5.5kB", "0B": Docker's sizes, in powers of 1000.
    static func dockerBytes(_ text: String) -> Int64? {
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1)]
        for (suffix, factor) in units where text.hasSuffix(suffix) {
            guard let value = Double(text.dropLast(suffix.count)), value.isFinite, value >= 0 else { return nil }
            return Int64((value * factor).rounded())
        }
        return nil
    }

    /// A reference Docker printed, safe to pass back as one argument.
    static func isDockerRef(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 256 && !s.hasPrefix("-")
            && s.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || ":._-/@".unicodeScalars.contains($0) }
    }

    static func docker(json: String) -> [Item]? {
        guard let root = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return nil }
        func list(_ key: String) -> [[String: Any]] { root[key] as? [[String: Any]] ?? [] }
        func str(_ d: [String: Any], _ k: String) -> String { d[k] as? String ?? "" }
        var out: [Item] = []
        for image in list("Images") {
            let id = str(image, "ID"), repo = str(image, "Repository"), tag = str(image, "Tag")
            guard isDockerRef(id) else { continue }
            let short = String((id.hasPrefix("sha256:") ? String(id.dropFirst(7)) : id).prefix(12))
            let untagged = repo == "<none>" || repo.isEmpty
            let name = untagged ? String(localized: "Untagged image \(short)") : repo + ":" + tag
            let bytes = dockerBytes(str(image, "UniqueSize")) ?? dockerBytes(str(image, "Size"))
            let users = Int(str(image, "Containers"))
            let handling: Handling, reason: String, removal: Removal?
            if users == nil || users! > 0 {
                (handling, reason, removal) = (.show, String(localized: "A container uses it. Remove the container first."), nil)
            } else if untagged {
                (handling, reason, removal) = (.recommend, String(localized: "Untagged and unused: left over from a newer build of the same image."), .command(["image", "rm", id]))
            } else {
                let ref = repo + ":" + tag
                guard isDockerRef(ref) else { continue }
                (handling, reason, removal) = (.offer, String(localized: "Unused, but tagged: pulled or built again only when it's needed."), .command(["image", "rm", ref]))
            }
            out.append(Item(id: "docker.image." + id, source: .docker, name: name, detail: "Image", bytes: bytes,
                            handling: handling, reason: reason, removal: removal, path: nil))
        }
        for c in list("Containers") {
            let id = str(c, "ID"), state = str(c, "State").lowercased()
            guard isDockerRef(id) else { continue }
            let stopped = ["exited", "created", "dead"].contains(state)
            out.append(Item(id: "docker.container." + id, source: .docker, name: str(c, "Names").isEmpty ? id : str(c, "Names"),
                            detail: String(localized: "Container · \(str(c, "Status"))"), bytes: dockerBytes(str(c, "Size")),
                            handling: stopped ? .offer : .show,
                            reason: stopped ? String(localized: "Stopped. What it changed inside itself goes with it; its volumes stay.")
                                : String(localized: "Running. Stop it in Docker first."),
                            removal: stopped ? .command(["container", "rm", id]) : nil, path: nil))
        }
        for v in list("Volumes") {
            let name = str(v, "Name")
            guard isDockerRef(name), !name.contains("/") else { continue }
            let anonymous = str(v, "Labels").contains("com.docker.volume.anonymous")
            let links = Int(str(v, "Links"))
            let unusedAnonymous = anonymous && links == 0
            out.append(Item(id: "docker.volume." + name, source: .docker,
                            name: anonymous ? String(localized: "Anonymous volume \(String(name.prefix(12)))") : name,
                            detail: "Volume", bytes: dockerBytes(str(v, "Size")),
                            handling: unusedAnonymous ? .offer : .show,
                            reason: unusedAnonymous ? String(localized: "No container uses it. A container made it without a name; it may still hold that container's data.")
                                : links.map { $0 > 0 } ?? true ? String(localized: "A container uses it.")
                                : String(localized: "A named volume: databases and other data live here. Remove it in Docker if you're sure."),
                            removal: unusedAnonymous ? .command(["volume", "rm", name]) : nil, path: nil))
        }
        let unused = list("BuildCache").filter { str($0, "InUse") == "false" && str($0, "Shared") == "false" }
        if !unused.isEmpty {
            out.append(Item(id: "docker.buildcache", source: .docker, name: String(localized: "Unused build cache"),
                            detail: String(localized: "Build cache · \(unused.count) records"),
                            bytes: unused.compactMap { dockerBytes(str($0, "Size")) }.reduce(0, +), handling: .recommend,
                            reason: String(localized: "Build steps no image uses now. The next build that needs one runs it again."),
                            removal: .command(["builder", "prune", "--force"]), path: nil))
        }
        return out
    }

    // MARK: Xcode's simulators

    static let simctlDevices = ["simctl", "list", "-j", "devices"]
    static let simctlRuntimes = ["simctl", "runtime", "list", "-j"]

    static func isUUID(_ s: String) -> Bool {
        s.count == 36 && s.allSatisfy { $0.isHexDigit || $0 == "-" }
    }

    /// "iOS" of "com.apple.CoreSimulator.SimRuntime.iOS-26-4".
    static func platform(_ runtime: String) -> String {
        let last = runtime.split(separator: ".").last.map(String.init) ?? runtime
        return String(last.prefix { $0 != "-" })
    }

    static func simulators(devices: String, runtimes: String) -> [Item]? {
        guard let d = ((try? JSONSerialization.jsonObject(with: Data(devices.utf8))) as? [String: Any])?["devices"] as? [String: [[String: Any]]],
              let r = (try? JSONSerialization.jsonObject(with: Data(runtimes.utf8))) as? [String: [String: Any]] else { return nil }
        var used = Set<String>()
        var out: [Item] = []
        for (runtime, list) in d {
            for dev in list {
                let available = dev["isAvailable"] as? Bool ?? true
                if available { used.insert(runtime.lowercased()); continue }
                guard let udid = dev["udid"] as? String, isUUID(udid) else { continue }
                let shutDown = (dev["state"] as? String) == "Shutdown"
                out.append(Item(id: "simulator.device." + udid, source: .simulator, name: dev["name"] as? String ?? udid,
                                detail: String(localized: "Simulator · \(platform(runtime)) runtime not installed"),
                                bytes: (dev["dataPathSize"] as? NSNumber)?.int64Value, handling: shutDown ? .offer : .show,
                                reason: shutDown ? String(localized: "Its runtime is gone, so it can't start. Its apps and data go with it.")
                                    : String(localized: "Still running. Shut it down first."),
                                removal: shutDown ? .xcrun(["simctl", "delete", udid]) : nil, path: nil))
            }
        }
        for (_, rt) in r {
            guard let identifier = rt["identifier"] as? String, isUUID(identifier), let runtime = rt["runtimeIdentifier"] as? String else { continue }
            let version = rt["version"] as? String ?? ""
            let deletable = rt["deletable"] as? Bool ?? false
            let inUse = used.contains(runtime.lowercased())
            let handling: Handling = deletable && !inUse ? .offer : .show
            let reason = !deletable ? String(localized: "macOS keeps this runtime; remove it in Xcode's Components settings.")
                : inUse ? String(localized: "Simulators use it. Remove them first, or keep it.")
                : String(localized: "No simulator uses it. Xcode downloads it again when one needs it.")
            out.append(Item(id: "simulator.runtime." + identifier, source: .simulator, name: String(localized: "\(platform(runtime)) \(version) runtime"),
                            detail: String(localized: "Simulator runtime"), bytes: (rt["sizeBytes"] as? NSNumber)?.int64Value, handling: handling,
                            reason: reason, removal: handling == .offer ? .xcrun(["simctl", "runtime", "delete", identifier]) : nil, path: nil))
        }
        return out
    }

    // MARK: Android

    static func isPlainName(_ s: String) -> Bool {
        !s.isEmpty && !s.hasPrefix("-") && !s.hasPrefix(".") && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }

    static func ini(_ path: String) -> [String: String] {
        guard let data = FileManager.default.contents(atPath: path), data.count <= 1 << 20 else { return [:] }
        var out: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { out[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces) }
        }
        return out
    }

    static func android(home: String, toolExists: (String) -> Bool) -> [Item] {
        let avd = home + "/.android/avd"
        let sdk = home + "/Library/Android/sdk"
        let bin = sdk + "/cmdline-tools/latest/bin"
        let avdmanager = toolExists(bin + "/avdmanager") ? bin + "/avdmanager" : nil
        let sdkmanager = toolExists(bin + "/sdkmanager") ? bin + "/sdkmanager" : nil
        var used = Set<String>()
        var out: [Item] = []
        for file in (DirectoryListing.names(avd) ?? []).sorted() where file.hasSuffix(".ini") {
            let name = String(file.dropLast(4))
            guard isPlainName(name) else { continue }
            let folder = avd + "/" + name + ".avd"
            guard isFolder(folder) else { continue }
            let config = ini(folder + "/config.ini")
            if let sysdir = config["image.sysdir.1"] { used.insert(sysdir.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) }
            // A folder that can't be read counts as one the emulator is using.
            let running = DirectoryListing.names(folder).map { $0.contains { $0.hasSuffix(".lock") } } ?? true
            let handling: Handling = running || avdmanager == nil ? .show : .offer
            let reason = running ? String(localized: "The emulator is running it. Close the emulator first.")
                : avdmanager == nil ? String(localized: "Delete it in Android Studio's Device Manager.")
                : String(localized: "A virtual device with its apps and data. Android Studio can make a new one.")
            out.append(Item(id: "android.avd." + name, source: .android, name: config["avd.ini.displayname"] ?? name,
                            detail: String(localized: "Virtual device"), bytes: AppLeftovers.measure(folder), handling: handling, reason: reason,
                            removal: handling == .offer ? .tool(avdmanager!, ["delete", "avd", "-n", name]) : nil, path: folder))
        }
        let images = sdk + "/system-images"
        for api in (DirectoryListing.names(images) ?? []).sorted() where isPlainName(api) {
            for tag in (DirectoryListing.names(images + "/" + api) ?? []).sorted() where isPlainName(tag) {
                for abi in (DirectoryListing.names(images + "/" + api + "/" + tag) ?? []).sorted() where isPlainName(abi) {
                    let path = [images, api, tag, abi].joined(separator: "/")
                    guard isFolder(path) else { continue }
                    let inUse = used.contains("system-images/\(api)/\(tag)/\(abi)")
                    let handling: Handling = inUse || sdkmanager == nil ? .show : .offer
                    let reason = inUse ? String(localized: "A virtual device uses it.")
                        : sdkmanager == nil ? String(localized: "Remove it in Android Studio's SDK Manager.")
                        : String(localized: "No virtual device uses it. The SDK Manager downloads it again when one needs it.")
                    out.append(Item(id: "android.image.\(api).\(tag).\(abi)", source: .android, name: "\(api) · \(tag) · \(abi)",
                                    detail: String(localized: "System image"), bytes: AppLeftovers.measure(path), handling: handling, reason: reason,
                                    removal: handling == .offer ? .tool(sdkmanager!, ["--uninstall", "system-images;\(api);\(tag);\(abi)"]) : nil,
                                    path: path))
                }
            }
        }
        return out
    }

    static func isFolder(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR
    }

    // MARK: Virtual machines

    /// Where each app keeps its machines by default, how a machine's folder
    /// ends, and the processes that run them.
    static let machineHomes: [(app: String, folder: String, suffix: String?, processes: [String])] = [
        ("UTM", "Library/Containers/com.utmapp.UTM/Data/Documents", ".utm", ["UTM", "QEMULauncher"]),
        ("Parallels Desktop", "Parallels", ".pvm", ["prl_client_app", "prl_vm_app"]),
        ("VMware Fusion", "Virtual Machines.localized", ".vmwarevm", ["vmware-vmx"]),
        ("VMware Fusion", "Virtual Machines", ".vmwarevm", ["vmware-vmx"]),
        ("VirtualBox", "VirtualBox VMs", nil, ["VirtualBoxVM", "VBoxHeadless"]),
        ("Tart", ".tart/vms", nil, ["tart"]),
    ]

    /// Every machine, only to look at: a running one, or one that only its
    /// app can take apart safely, is never removed here.
    static func virtualMachines(home: String, running: Set<String>) -> [Item] {
        var out: [Item] = []
        for m in machineHomes {
            let dir = home + "/" + m.folder
            for entry in (DirectoryListing.names(dir) ?? []).sorted() where !entry.hasPrefix(".") {
                let path = dir + "/" + entry
                guard isFolder(path) else { continue }
                if let suffix = m.suffix { guard entry.hasSuffix(suffix) else { continue } }
                if m.app == "VirtualBox" { guard (DirectoryListing.names(path) ?? []).contains(where: { $0.hasSuffix(".vbox") }) else { continue } }
                let name = m.suffix.map { entry.hasSuffix($0) ? String(entry.dropLast($0.count)) : entry } ?? entry
                let isRunning = m.processes.contains { running.contains($0) }
                out.append(Item(id: "vm." + path, source: .virtualMachine, name: name,
                                detail: isRunning ? String(localized: "\(m.app) · running") : m.app, bytes: AppLeftovers.measure(path),
                                handling: .show, reason: String(localized: "A whole computer with everything installed in it. Remove it in \(m.app), which also handles its snapshots."),
                                removal: nil, path: path))
            }
        }
        return out
    }
}
