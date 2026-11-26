import Foundation
import Testing

@testable import StorageKit

/// Leftovers of real apps, as Homebrew's maintainers list them for
/// `brew uninstall --zap`, laid out side by side in a test home folder.
/// Each app is looked for with the others installed: what's found should be
/// its own listed paths, and never another app's. Only paths one app lists
/// are its own; what several list is shared. The corpus is made by a local
/// script from Homebrew's cask list, which isn't kept here.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MYMOLE_BREW_CORPUS"] != nil))
struct HomebrewCorpusTests {
    struct Corpus: Decodable {
        let apps: [App]
    }
    struct App: Decodable {
        let token: String
        let name: String
        let bundleID: String
        let paths: [String]
        let own: [String]
    }
    struct Metrics: Encodable {
        var apps = 0
        var ownPaths = 0
        var found = 0
        var foundChosen = 0
        var otherAppsHits = 0
        var otherAppsHitsChosen = 0
        var sharedHits = 0
        var byEvidence: [String: Int] = [:]
        var missedByPlace: [String: Int] = [:]
    }

    static let fileEndings: Set<String> = ["plist", "json", "log", "txt", "db", "sqlite", "binarycookies", "sfl2", "sfl3", "ini", "xml", "cfg", "conf"]

    /// `a` is `b`, or one holds the other.
    static func overlaps(_ a: String, _ b: String) -> Bool {
        let a = a.lowercased(), b = b.lowercased()
        return a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
    }

    static func place(_ rel: String) -> String {
        let parts = rel.split(separator: "/").map(String.init)
        if parts.first == "Library", parts.count > 2 { return parts[1] }
        return parts.first?.hasPrefix(".") == true ? "~/.*" : parts.first ?? ""
    }

    @Test func eachAppsListedLeftoversAreFoundAndNoOtherAppsAre() throws {
        let path = try #require(ProcessInfo.processInfo.environment["MYMOLE_BREW_CORPUS"])
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        try #require(!corpus.apps.isEmpty)
        let batch = Int(ProcessInfo.processInfo.environment["MYMOLE_BREW_BATCH"] ?? "") ?? 50
        var metrics = Metrics()
        var misses: [String] = []
        var wrong: [String] = []
        for start in stride(from: 0, to: corpus.apps.count, by: batch) {
            let group = Array(corpus.apps[start..<min(start + batch, corpus.apps.count)])
            let box = try Sandbox()
            let all = Set(group.flatMap(\.paths))
            for rel in all {
                // A path another one is inside is a folder; a leaf is a file by its ending, else a folder with a file.
                let isParent = all.contains { $0.count > rel.count && $0.lowercased().hasPrefix(rel.lowercased() + "/") }
                let ending = (rel as NSString).pathExtension.lowercased()
                if isParent { try box.folder(rel) } else if Self.fileEndings.contains(ending) { try box.file(rel, bytes: 600) } else { try box.file(rel + "/data.bin", bytes: 600) }
            }
            let apps = group.map {
                AppBundle(path: box.path + "/Applications/\($0.token)/\($0.name).app", name: $0.name, bundleID: $0.bundleID,
                          version: nil, bytes: 1, fromAppStore: false)
            }
            for (entry, app) in zip(group, apps) {
                let found = AppLeftovers.find(for: app, home: box.path, installed: apps, deep: true)
                let rel = found.map { (String($0.path.dropFirst(box.path.count + 1)), $0) }
                metrics.apps += 1
                metrics.ownPaths += entry.own.count
                for own in entry.own {
                    if let hit = rel.first(where: { Self.overlaps($0.0, own) }) {
                        metrics.found += 1
                        if hit.1.chosenByDefault { metrics.foundChosen += 1 }
                        metrics.byEvidence[hit.1.evidence.rawValue, default: 0] += 1
                    } else {
                        metrics.missedByPlace[Self.place(own), default: 0] += 1
                        if misses.count < 60 { misses.append("\(entry.token): \(own)") }
                    }
                }
                let others = group.filter { $0.token != entry.token }
                for (r, leftover) in rel where !entry.own.contains(where: { Self.overlaps(r, $0) }) {
                    if let other = others.first(where: { $0.own.contains { Self.overlaps(r, $0) } }) {
                        metrics.otherAppsHits += 1
                        if leftover.chosenByDefault { metrics.otherAppsHitsChosen += 1 }
                        if wrong.count < 60 { wrong.append("\(entry.token) took \(other.token)'s \(r) (\(leftover.evidence.rawValue)\(leftover.chosenByDefault ? ", chosen" : ""))") }
                    } else {
                        metrics.sharedHits += 1
                    }
                }
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        print("brew-corpus " + String(decoding: try encoder.encode(metrics), as: UTF8.self))
        for m in misses { print("brew-corpus-miss " + m) }
        for w in wrong { print("brew-corpus-wrong " + w) }
        // Another app's leftover is never chosen for the user.
        #expect(metrics.otherAppsHitsChosen == 0)
    }
}
