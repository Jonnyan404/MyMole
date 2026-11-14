import Foundation
import Testing

@testable import StorageKit

/// Dropping a map frees only its top folder where it's dropped; the rest
/// is freed elsewhere, all of it.
@Suite struct FolderReleaseTests {
    @Test func droppingALargeMapIsQuickAndFreesAllOfIt() throws {
        weak var deepest: Folder?
        var root: Folder? = {
            let root = Folder(name: "Synthetic", parent: nil, rootPath: "/synthetic")
            root.subfolders = (0..<200).map { a in
                let area = Folder(name: "Area \(a)", parent: root)
                area.subfolders = (0..<1_000).map { Folder(name: "Item \($0)", parent: area) }
                return area
            }
            root.finish()
            return root
        }()
        deepest = root?.subfolders.last?.subfolders.last
        #expect(deepest != nil)
        let start = ContinuousClock.now
        root = nil
        let dropped = ContinuousClock.now - start
        #expect(dropped < .milliseconds(20), "Dropping took \(dropped)")
        for _ in 0..<1_000 where deepest != nil { Folder.releases.sync {} }
        #expect(deepest == nil)
    }
}
