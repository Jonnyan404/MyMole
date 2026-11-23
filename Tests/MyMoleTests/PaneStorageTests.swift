import Foundation
import Testing

/// The main window is made by AppKit, not by a SwiftUI scene, so
/// `@SceneStorage` there has nowhere to keep a value: its binding stays
/// constant, a filter field filters nothing and empties on the next redraw.
@Suite struct PaneStorageTests {
    @Test func noPaneKeepsStateInSceneStorage() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources")
        let walk = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var read = 0
        for case let file as URL in walk where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            read += 1
            if text.contains("@SceneStorage") {
                Issue.record("\(file.path.dropFirst(sources.path.count + 1)) uses @SceneStorage")
            }
        }
        #expect(read > 100)
    }
}
