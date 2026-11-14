import Foundation
import Testing

@testable import StorageKit

/// A finished folder keeps its folders largest first through every change
/// the map can go through, so the charts can take them in that order and
/// stop at the first one too small to draw.
@Suite struct FolderOrderTests {
    /// Three levels of uneven folders, with files of their own.
    private func tree(seed: UInt64) -> Folder {
        var rng = SeededRandom(seed: seed)
        let root = Folder(name: "Synthetic", parent: nil, rootPath: "/synthetic")
        root.subfolders = (0..<12).map { a in
            let area = Folder(name: "Area \(a)", parent: root)
            area.subfolders = (0..<Int.random(in: 1...10, using: &rng)).map { d in
                let dir = Folder(name: "Folder \(d)", parent: area)
                dir.subfolders = (0..<Int.random(in: 0...8, using: &rng)).map { l in
                    let leaf = Folder(name: "Item \(l)", parent: dir)
                    leaf.ownBytes[.other] = Int64.random(in: 0...4_000_000, using: &rng)
                    return leaf
                }
                dir.listedFiles = (0..<3).map {
                    FileItem(name: "file-\($0).bin", size: Int64.random(in: 1...2_000_000, using: &rng), modified: .distantPast, kind: .other)
                }
                for file in dir.listedFiles { dir.ownBytes[.other] += file.size }
                dir.smallFileCount = 4
                dir.smallFileBytes = Int64.random(in: 0...1_000_000, using: &rng)
                dir.ownBytes[.other] += dir.smallFileBytes
                return dir
            }
            return area
        }
        root.finish()
        return root
    }

    /// Folders not in size order, by path.
    private func outOfOrder(_ root: Folder) -> [String] {
        var out: [String] = [], stack = [root]
        while let f = stack.popLast() {
            let sizes = f.subfolders.map(\.size)
            if f.isFinished, sizes != sizes.sorted(by: >) { out.append(f.path) }
            stack.append(contentsOf: f.subfolders)
        }
        return out
    }

    private func largest(_ f: Folder) -> Folder { f.subfolders[0] }

    @Test func finishedFoldersStayLargestFirstWhateverChanges() throws {
        for seed in 1...20 as ClosedRange<UInt64> {
            let root = tree(seed: seed)
            #expect(outOfOrder(root).isEmpty)

            // The largest area loses its largest folder, which can leave it
            // smaller than the areas after it.
            let area = largest(root)
            let removed = largest(area)
            area.remove(removed)
            #expect(outOfOrder(root).isEmpty, "remove, seed \(seed)")

            area.restore(removed)
            #expect(outOfOrder(root).isEmpty, "restore, seed \(seed)")

            let dir = largest(largest(root))
            let name = try #require(dir.listedFiles.max { $0.size < $1.size }?.name)
            dir.removeFile(named: name)
            #expect(outOfOrder(root).isEmpty, "removeFile, seed \(seed)")

            let small = dir.removeSmallFiles()
            #expect(outOfOrder(root).isEmpty, "removeSmallFiles, seed \(seed)")
            dir.restoreSmallFiles(small)
            #expect(outOfOrder(root).isEmpty, "restoreSmallFiles, seed \(seed)")

            // A folder measured again, much smaller than before.
            let target = largest(root)
            let replacement = Folder(name: target.name, parent: nil, rootPath: target.path)
            replacement.ownBytes[.other] = 1
            replacement.finish()
            let replaced = try #require(root.replacingSubtree(at: target.path, with: replacement))
            #expect(outOfOrder(replaced).isEmpty, "replacingSubtree, seed \(seed)")
        }
    }
}

struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
}
