import Darwin
import Foundation

/// Local AI models as their apps keep them: Ollama's models by their
/// manifests, with the layers they share; Hugging Face's cache by
/// repository; LM Studio's models by folder; and downloads that never
/// finished. A model goes to the Trash only on the user's choice, with
/// every file that is its own and none another model still uses, and only
/// while the app that keeps it isn't running. When a model was last read
/// says nothing about whether it's still wanted, so nothing starts chosen.
extension DevTools {
    /// Where the apps keep their models by default.
    public struct ModelHomes: Sendable, Equatable {
        public var ollama: String
        public var huggingFace: String
        public var lmStudio: [String]

        public init(home: String) {
            ollama = home + "/.ollama/models"
            huggingFace = home + "/.cache/huggingface/hub"
            lmStudio = [home + "/.lmstudio/models", home + "/.cache/lm-studio/models"]
        }
    }

    /// The processes that use each place; while one runs, its models are only shown.
    static let modelApps: [(app: String, processes: [String])] = [
        ("Ollama", ["ollama", "Ollama"]),
        ("LM Studio", ["LM Studio", "lms", "llmster"]),
    ]

    static func running(_ app: String, _ running: Set<String>?) -> Bool {
        // A process list that can't be read counts as the app running.
        guard let running else { return true }
        return modelApps.first { $0.app == app }?.processes.contains(where: running.contains) ?? false
    }

    /// Allocated bytes of one file, not following a link.
    static func fileBytes(_ path: String) -> Int64? {
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
        return Int64(st.st_blocks) * 512
    }

    static func isFile(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFREG
    }

    /// Every model place, as items; `trash` is whether this edition may move them.
    static func aiModels(homes: ModelHomes, running processes: Set<String>?, trash: Bool) -> [Item] {
        ollama(homes.ollama, running: running("Ollama", processes), trash: trash)
            + huggingFace(homes.huggingFace, trash: trash)
            + homes.lmStudio.flatMap { lmStudio($0, running: running("LM Studio", processes), trash: trash) }
    }

    static func pieces(_ n: Int) -> String { n == 1 ? String(localized: "1 piece") : String(localized: "\(n) pieces") }

    // MARK: Ollama

    /// "sha256:<64 hex>" as Ollama names a blob, and its file name.
    static func ollamaBlob(_ digest: String) -> String? {
        let parts = digest.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, parts[0] == "sha256", parts[1].count == 64, parts[1].allSatisfy(\.isHexDigit) else { return nil }
        return "sha256-" + parts[1]
    }

    struct OllamaManifest {
        let path: String
        let name: String
        let blobs: [String]
    }

    /// manifests/<registry>/<namespace>/<model>/<tag>, each a JSON list of
    /// layers by digest. A manifest that can't be read leaves every blob in
    /// use, so nothing shared is ever counted as free.
    static func ollamaManifests(_ base: String) -> (manifests: [OllamaManifest], unreadable: Bool) {
        let root = base + "/manifests"
        var out: [OllamaManifest] = [], unreadable = false
        for registry in (DirectoryListing.names(root) ?? []).sorted() where !registry.hasPrefix(".") {
            for namespace in (DirectoryListing.names(root + "/" + registry) ?? []).sorted() where !namespace.hasPrefix(".") {
                let nsPath = [root, registry, namespace].joined(separator: "/")
                for model in (DirectoryListing.names(nsPath) ?? []).sorted() where !model.hasPrefix(".") {
                    for tag in (DirectoryListing.names(nsPath + "/" + model) ?? []).sorted() where !tag.hasPrefix(".") {
                        let path = [nsPath, model, tag].joined(separator: "/")
                        guard isFile(path) else { continue }
                        guard let data = FileManager.default.contents(atPath: path), data.count <= 1 << 20,
                              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                        else { unreadable = true; continue }
                        var digests = (json["layers"] as? [[String: Any]] ?? []).compactMap { $0["digest"] as? String }
                        if let config = (json["config"] as? [String: Any])?["digest"] as? String { digests.append(config) }
                        let blobs = digests.compactMap(ollamaBlob)
                        guard blobs.count == digests.count, !blobs.isEmpty else { unreadable = true; continue }
                        let short = registry == "registry.ollama.ai" && namespace == "library" ? model : [registry, namespace, model].joined(separator: "/")
                        out.append(OllamaManifest(path: path, name: short + ":" + tag, blobs: blobs))
                    }
                }
            }
        }
        return (out, unreadable)
    }

    static func ollama(_ base: String, running: Bool, trash: Bool) -> [Item] {
        let blobsDir = base + "/blobs"
        guard let names = DirectoryListing.names(blobsDir) else { return [] }
        let (manifests, unreadable) = ollamaManifests(base)
        var users: [String: Int] = [:]
        for m in manifests { for b in Set(m.blobs) { users[b, default: 0] += 1 } }
        let bytes = Dictionary(uniqueKeysWithValues: names.compactMap { n in fileBytes(blobsDir + "/" + n).map { (n, $0) } })
        var out: [Item] = []
        for m in manifests {
            let own = Set(m.blobs).filter { users[$0] == 1 && bytes[$0] != nil }.sorted()
            let shared = Set(m.blobs).filter { (users[$0] ?? 0) > 1 }
            let sharedBytes = shared.compactMap { bytes[$0] }.reduce(0, +)
            let freed = own.compactMap { bytes[$0] }.reduce(0, +)
            let detail = shared.isEmpty ? String(localized: "Ollama model")
                : String(localized: "Ollama model · \(ByteSize.format(sharedBytes)) shared with other models stays")
            let movable = trash && !running && !unreadable
            let reason = running ? String(localized: "Ollama is running. Quit it first, or remove the model with ollama rm.")
                : unreadable ? String(localized: "One of Ollama's model lists couldn't be read, so it isn't known which layers other models use.")
                : !trash ? String(localized: "Remove it with ollama rm, or in the Ollama app.")
                : String(localized: "Downloaded again with ollama pull. Its own layers go with it; layers other models use stay.")
            out.append(Item(id: "ai.ollama." + m.name, source: .aiModels, name: m.name, detail: detail, bytes: freed,
                            handling: movable ? .offer : .show, reason: reason,
                            removal: movable ? .trash([m.path] + own.map { blobsDir + "/" + $0 }) : nil, path: m.path))
        }
        // Unfinished downloads, and layers no model lists, which Ollama prunes itself when it starts.
        let partial = names.filter { $0.hasPrefix("sha256-") && $0.contains("-partial") }.sorted()
        if !partial.isEmpty {
            let movable = trash && !running
            out.append(Item(id: "ai.ollama.partial", source: .aiModels, name: String(localized: "Unfinished Ollama downloads"),
                            detail: pieces(partial.count), bytes: partial.compactMap { bytes[$0] }.reduce(0, +),
                            handling: movable ? .offer : .show,
                            reason: running ? String(localized: "Ollama is running and may still be downloading. Quit it first.")
                                : String(localized: "A download that stopped before it finished. ollama pull starts it again."),
                            removal: movable ? .trash(partial.map { blobsDir + "/" + $0 }) : nil, path: blobsDir))
        }
        if !unreadable {
            let unused = names.filter { $0.hasPrefix("sha256-") && !$0.contains("-partial") && users[$0] == nil && bytes[$0] != nil }
            if !unused.isEmpty {
                out.append(Item(id: "ai.ollama.unused", source: .aiModels, name: String(localized: "Ollama layers no model lists"),
                                detail: unused.count == 1 ? String(localized: "1 layer") : String(localized: "\(unused.count) layers"), bytes: unused.compactMap { bytes[$0] }.reduce(0, +),
                                handling: .show, reason: String(localized: "Ollama removes these itself the next time it starts."),
                                removal: nil, path: blobsDir))
            }
        }
        return out
    }

    // MARK: Hugging Face

    /// "models--org--name" as org/name, with what kind of repository it is.
    static func huggingFaceRepo(_ folder: String) -> (kind: String, name: String)? {
        let parts = folder.components(separatedBy: "--")
        guard parts.count >= 2, ["models", "datasets", "spaces"].contains(parts[0]), parts.dropFirst().allSatisfy({ !$0.isEmpty }) else { return nil }
        return (parts[0], parts.dropFirst().joined(separator: "/"))
    }

    static func huggingFace(_ hub: String, trash: Bool) -> [Item] {
        var out: [Item] = []
        for folder in (DirectoryListing.names(hub) ?? []).sorted() {
            guard let repo = huggingFaceRepo(folder) else { continue }
            let path = hub + "/" + folder
            guard isFolder(path) else { continue }
            let revisions = (DirectoryListing.names(path + "/snapshots") ?? []).filter { !$0.hasPrefix(".") }.count
            let blobs = path + "/blobs"
            let unfinished = (DirectoryListing.names(blobs) ?? []).filter { $0.hasSuffix(".incomplete") }.sorted()
            let kind = switch repo.kind {
            case "datasets": String(localized: "Hugging Face dataset")
            case "spaces": String(localized: "Hugging Face space")
            default: String(localized: "Hugging Face model")
            }
            let detail = revisions > 1 ? String(localized: "\(kind) · \(revisions) revisions") : kind
            out.append(Item(id: "ai.hf." + folder, source: .aiModels, name: repo.name, detail: detail, bytes: AppLeftovers.measure(path),
                            handling: trash ? .offer : .show,
                            reason: trash ? String(localized: "Downloaded again by the program that asks for it. When it was last read doesn't tell whether a program still needs it.")
                                : String(localized: "Remove it with the hf cache command, or by moving its folder to the Trash."),
                            removal: trash ? .trash([path]) : nil, path: path))
            if !unfinished.isEmpty {
                out.append(Item(id: "ai.hf.incomplete." + folder, source: .aiModels,
                                name: String(localized: "Unfinished downloads of \(repo.name)"), detail: pieces(unfinished.count),
                                bytes: unfinished.compactMap { fileBytes(blobs + "/" + $0) }.reduce(0, +), handling: trash ? .offer : .show,
                                reason: String(localized: "Pieces of a download that stopped. The next download of the same files starts over."),
                                removal: trash ? .trash(unfinished.map { blobs + "/" + $0 }) : nil, path: blobs))
            }
        }
        return out
    }

    // MARK: LM Studio

    /// models/<publisher>/<model>: one folder of model files each.
    static func lmStudio(_ base: String, running: Bool, trash: Bool) -> [Item] {
        var out: [Item] = []
        for publisher in (DirectoryListing.names(base) ?? []).sorted() where !publisher.hasPrefix(".") {
            let pub = base + "/" + publisher
            guard isFolder(pub) else { continue }
            for model in (DirectoryListing.names(pub) ?? []).sorted() where !model.hasPrefix(".") {
                let path = pub + "/" + model
                guard isFolder(path) else { continue }
                let movable = trash && !running
                out.append(Item(id: "ai.lmstudio." + path, source: .aiModels, name: publisher + "/" + model,
                                detail: String(localized: "LM Studio model"), bytes: AppLeftovers.measure(path),
                                handling: movable ? .offer : .show,
                                reason: running ? String(localized: "LM Studio is running and may have it loaded. Quit it first.")
                                    : !trash ? String(localized: "Remove it in LM Studio's My Models.")
                                    : String(localized: "LM Studio downloads it again from its Discover page."),
                                removal: movable ? .trash([path]) : nil, path: path))
            }
        }
        return out
    }
}
