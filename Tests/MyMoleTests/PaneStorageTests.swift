import Foundation
import Testing

/// The main window is made by AppKit, not by a SwiftUI scene, so what SwiftUI
/// keeps per scene has nothing behind it there: `@SceneStorage` gives a
/// constant binding (a filter field filtered nothing and emptied on the next
/// redraw), the scene phase is always background, and focused scene values,
/// window actions and `.searchable` have no scene to reach.
@Suite struct PaneStorageTests {
    static let sceneOnly = [
        "@SceneStorage", "\\.scenePhase", "@FocusedValue", "@FocusedBinding", "@FocusedObject",
        ".focusedSceneValue(", ".focusedSceneObject(", ".focusedValue(", ".focusedObject(",
        "\\.openWindow", "\\.dismissWindow", "\\.pushWindow", ".searchable(",
    ]

    @Test func noViewReliesOnASwiftUIScene() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources")
        let walk = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var read = 0
        for case let file as URL in walk where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            read += 1
            for api in Self.sceneOnly where text.contains(api) {
                Issue.record("\(file.path.dropFirst(sources.path.count + 1)) uses \(api)")
            }
        }
        #expect(read > 100)
    }
}
