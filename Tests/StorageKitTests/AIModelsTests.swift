import Foundation
import Testing

@testable import StorageKit

/// Local AI models from synthetic manifests and caches in a home folder of
/// the test's own: shared layers stay with the models that use them, a
/// model list that can't be read moves nothing, a running app's models are
/// only shown, and moves go to the test's own Trash folder.
@Suite struct AIModelsTests {
    private let a = String(repeating: "a", count: 64), b = String(repeating: "b", count: 64)
    private let c = String(repeating: "c", count: 64), d = String(repeating: "d", count: 64)

    private func write(_ box: Sandbox, _ rel: String, _ text: String) throws {
        let url = box.url.appending(path: rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func manifest(_ layers: [String], config: String) -> String {
        let l = layers.map { #"{"mediaType":"application/vnd.ollama.image.model","digest":"sha256:\#($0)","size":1}"# }.joined(separator: ",")
        return #"{"schemaVersion":2,"config":{"digest":"sha256:\#(config)","size":1},"layers":[\#(l)]}"#
    }

    /// llama3:8b and llama3:instruct share layer a; each has its own config.
    private func ollama(_ box: Sandbox) throws {
        let m = ".ollama/models/manifests/registry.ollama.ai/library/llama3/"
        try write(box, m + "8b", manifest([a, b], config: c))
        try write(box, m + "instruct", manifest([a], config: d))
        for (h, size) in [(a, 400_000), (b, 100_000), (c, 4_096), (d, 4_096)] { _ = try box.file(".ollama/models/blobs/sha256-" + h, bytes: size) }
        _ = try box.file(".ollama/models/blobs/sha256-\(String(repeating: "e", count: 64))-partial", bytes: 50_000)
        _ = try box.file(".ollama/models/blobs/sha256-\(String(repeating: "f", count: 64))", bytes: 20_000)
    }

    @Test func sharedLayersStayWithTheModelsThatUseThem() throws {
        let box = try Sandbox()
        try ollama(box)
        let items = DevTools.ollama(box.path + "/.ollama/models", running: false, trash: true)
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })
        let blobs = box.path + "/.ollama/models/blobs/sha256-"
        let eight = try #require(byName["llama3:8b"])
        #expect(eight.handling == .offer)
        #expect(eight.removal == .trash([box.path + "/.ollama/models/manifests/registry.ollama.ai/library/llama3/8b", blobs + b, blobs + c]))
        #expect(eight.detail.contains(ByteSize.format(DevTools.fileBytes(blobs + a)!)))
        #expect(eight.bytes == DevTools.fileBytes(blobs + b)! + DevTools.fileBytes(blobs + c)!)
        let instruct = try #require(byName["llama3:instruct"])
        #expect(instruct.removal == .trash([box.path + "/.ollama/models/manifests/registry.ollama.ai/library/llama3/instruct", blobs + d]))
        #expect(items.first { $0.id == "ai.ollama.partial" }?.handling == .offer)
        // A layer no model lists is Ollama's to prune.
        let unused = try #require(items.first { $0.id == "ai.ollama.unused" })
        #expect(unused.handling == .show && unused.removal == nil)
    }

    @Test func aModelListThatCantBeReadMovesNothing() throws {
        let box = try Sandbox()
        try ollama(box)
        try write(box, ".ollama/models/manifests/registry.ollama.ai/library/other/latest", "{not json")
        let items = DevTools.ollama(box.path + "/.ollama/models", running: false, trash: true)
        #expect(items.filter { $0.name.hasPrefix("llama3") }.allSatisfy { $0.handling == .show && $0.removal == nil })
        #expect(!items.contains { $0.id == "ai.ollama.unused" })
    }

    @Test func aRunningAppsModelsAreOnlyShown() throws {
        let box = try Sandbox()
        try ollama(box)
        try write(box, ".lmstudio/models/lmstudio-community/Qwen-GGUF/model.gguf", "weights")
        let running = DevTools.aiModels(homes: .init(home: box.path), running: ["ollama", "LM Studio"], trash: true)
        #expect(running.count == 5 && running.allSatisfy { $0.handling == .show })
        // A process list that can't be read counts as running.
        #expect(DevTools.aiModels(homes: .init(home: box.path), running: nil, trash: true).allSatisfy { $0.handling == .show })
        let store = DevTools.aiModels(homes: .init(home: box.path), running: [], trash: false)
        #expect(store.allSatisfy { $0.handling == .show && $0.removal == nil })
    }

    @Test func huggingFaceRepositoriesAndTheirUnfinishedDownloads() throws {
        let box = try Sandbox()
        let repo = ".cache/huggingface/hub/models--mistralai--Mistral-7B/"
        _ = try box.file(repo + "blobs/\(a)", bytes: 300_000)
        _ = try box.file(repo + "blobs/\(b).incomplete", bytes: 70_000)
        try write(box, repo + "snapshots/rev1/config.json", "{}")
        try write(box, repo + "snapshots/rev2/config.json", "{}")
        try write(box, ".cache/huggingface/hub/version.txt", "1")
        let items = DevTools.huggingFace(box.path + "/.cache/huggingface/hub", trash: true)
        #expect(items.map(\.name) == ["mistralai/Mistral-7B", "Unfinished downloads of mistralai/Mistral-7B"])
        let model = try #require(items.first { $0.name == "mistralai/Mistral-7B" })
        #expect(model.handling == .offer && model.removal == .trash([box.path + "/" + repo.dropLast()]))
        #expect(model.detail.contains("2"))
        let partial = try #require(items.first { $0.id.hasPrefix("ai.hf.incomplete.") })
        #expect(partial.removal == .trash([box.path + "/" + repo + "blobs/\(b).incomplete"]))
        #expect(DevTools.huggingFaceRepo("datasets--org--set")! == ("datasets", "org/set"))
        #expect(DevTools.huggingFaceRepo("models--") == nil && DevTools.huggingFaceRepo("version.txt") == nil)
    }

    /// The move reads the list again, goes to the test's own Trash, and
    /// leaves a model the keep list protects where it is.
    @Test func removalGoesToTheTrashAndHonoursKeep() throws {
        let box = try Sandbox()
        try ollama(box)
        try write(box, ".lmstudio/models/pub/Kept-GGUF/model.gguf", "weights")
        let listed = DevTools.aiModels(homes: .init(home: box.path), running: [], trash: true)
        let eight = try #require(listed.first { $0.name == "llama3:8b" })
        let kept = try #require(listed.first { $0.name == "pub/Kept-GGUF" })
        let keptPath = box.path + "/.lmstudio/models/pub/Kept-GGUF"
        try FileManager.default.createDirectory(atPath: box.path + "/Bin", withIntermediateDirectories: true)
        let report = DevTools.remove([eight, kept], tools: .init(), home: box.path, runner: CommandRunner(run: { _, _ in (1, "") }, exists: { _ in false }),
                                     running: { [] }, trash: true, backend: .folder(box.path + "/Bin"), protections: { { $0 == keptPath || $0.hasPrefix(keptPath + "/") } })
        #expect(report.removed == [eight.id])
        #expect(report.failed[kept.id] != nil)
        let blobs = box.path + "/.ollama/models/blobs/sha256-"
        #expect(!FileManager.default.fileExists(atPath: blobs + b) && FileManager.default.fileExists(atPath: blobs + a))
        #expect(FileManager.default.fileExists(atPath: keptPath))
        // What changed since the list was read is refused.
        let again = DevTools.remove([eight], tools: .init(), home: box.path, runner: CommandRunner(run: { _, _ in (1, "") }, exists: { _ in false }),
                                    running: { [] }, trash: true, backend: .folder(box.path + "/Bin"), protections: TrashGate.keepsNothing)
        #expect(again.refused == [eight.id])
    }
}
