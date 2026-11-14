import Foundation
import Testing

@testable import StorageKit

/// The chart parts are taken in the order a finished folder keeps, and the
/// rings stop at the first part too thin to draw: the same result as
/// sorting every time and looking at every part.
@Suite struct ChartPartsTests {
    private func tree(seed: UInt64, children: Int, shuffled: Bool) -> Folder {
        var rng = SeededGenerator(seed: seed)
        let root = Folder(name: "Synthetic", parent: nil, rootPath: "/synthetic")
        root.subfolders = (0..<children).map { i in
            let f = Folder(name: "Child \(i)", parent: root)
            f.subfolders = (0..<Int.random(in: 0...6, using: &rng)).map { j in
                let g = Folder(name: "Inner \(j)", parent: f)
                g.ownBytes[.other] = Int64.random(in: 0...5_000_000, using: &rng)
                return g
            }
            f.ownBytes[.other] = Int64.random(in: 0...3_000_000, using: &rng)
            return f
        }
        root.ownBytes[.other] = Int64.random(in: 0...20_000_000, using: &rng)
        root.finish()
        // A size changed after the folder was finished, as a removal can leave it.
        if shuffled { root.subfolders.shuffle(using: &rng) }
        return root
    }

    private func reference(_ folder: Folder) -> [Segment] {
        var parts = folder.subfolders.filter { $0.size > 0 }.map(Segment.folder)
        if folder.looseBytes > 0 { parts.append(.files(folder)) }
        return parts.sorted { $0.size > $1.size }
    }

    @Test(arguments: [false, true]) func partsAreLargestFirstWhateverTheFolderHolds(shuffled: Bool) {
        for seed in 1...20 as ClosedRange<UInt64> {
            let root = tree(seed: seed, children: 300, shuffled: shuffled)
            let parts = chartParts(of: root)
            #expect(parts.map(\.size) == reference(root).map(\.size))
            #expect(Set(parts) == Set(reference(root)))
        }
    }

    @Test func ringsStopAtTheFirstThinPartAndKeepEveryOtherArc() {
        for seed in 1...20 as ClosedRange<UInt64> {
            let root = tree(seed: seed, children: 2_000, shuffled: false)
            let arcs = Sunburst.layout(root, rings: 3, minAngle: 0.004)
            // Every part wide enough is drawn, at its true angle; none thinner is.
            let parts = chartParts(of: root)
            let total = Double(parts.reduce(0) { $0 + $1.size })
            let wide = parts.filter { 2 * .pi * Double($0.size) / total >= 0.004 }
            #expect(arcs.filter { $0.depth == 1 }.map(\.segment) == wide)
            #expect(arcs.allSatisfy { $0.end - $0.start >= 0.004 })
        }
    }

    /// Folders of folders, of uneven sizes, like a home folder in small.
    private func home(areas: Int, folders: Int, parts: Int, seed: UInt64) -> Folder {
        var rng = SeededGenerator(seed: seed)
        let root = Folder(name: "Synthetic", parent: nil, rootPath: "/synthetic")
        root.subfolders = (0..<areas).map { a in
            let area = Folder(name: "Area \(a)", parent: root)
            area.subfolders = (0..<folders).map { d in
                let dir = Folder(name: "Folder \(d)", parent: area)
                dir.subfolders = (0..<parts).map { p in
                    let part = Folder(name: "Part \(p)", parent: dir)
                    part.ownBytes[.other] = Int64.random(in: 0...9_000_000, using: &rng) * (p % 7 == 0 ? 40 : 1)
                    return part
                }
                dir.ownBytes[.other] = Int64.random(in: 0...30_000_000, using: &rng)
                return dir
            }
            return area
        }
        root.finish()
        return root
    }

    private struct Drawn: Equatable {
        let segment: Segment, depth: Int, start: Double, end: Double, branch: Int
        init(_ a: Arc) { (segment, depth, start, end, branch) = (a.segment, a.depth, a.start, a.end, a.branch) }
    }

    /// Every part looked at and sorted again, as before the order was kept.
    private func everyPart(_ root: Folder) -> [Drawn] {
        Sunburst.layout(root, include: { _ in true }).map(Drawn.init)
    }

    @Test func ringsOfAFinishedMapFollowItsOrderAndDrawTheSame() {
        for seed in 1...10 as ClosedRange<UInt64> {
            let root = home(areas: 8, folders: 40, parts: 30, seed: seed)
            #expect(Sunburst.layout(root).map(Drawn.init) == everyPart(root), "seed \(seed)")
            // Finer, deeper rings, as Columns asks for.
            #expect(Sunburst.layout(root, rings: 6, minAngle: 0.0005).map(Drawn.init)
                == Sunburst.layout(root, rings: 6, minAngle: 0.0005, include: { _ in true }).map(Drawn.init), "fine, seed \(seed)")
            // A removal shrinks the largest area below others.
            let area = root.subfolders[0]
            area.remove(area.subfolders[0])
            area.remove(area.subfolders[0])
            #expect(Sunburst.layout(root).map(Drawn.init) == everyPart(root), "after removal, seed \(seed)")
        }
    }

    @Test func ringsLookOnlyAtWhatTheyDraw() {
        // 1,000 folders in the second ring, each holding 50 too thin to draw.
        let root = home(areas: 25, folders: 40, parts: 50, seed: 3)
        func best(_ work: () -> Void) -> Duration {
            (0..<5).map { _ in let s = ContinuousClock.now; work(); return ContinuousClock.now - s }.min()!
        }
        var kept = 0, all = 0
        let ordered = best { kept = Sunburst.layout(root).count }
        let everything = best { all = Sunburst.layout(root, include: { _ in true }).count }
        #expect(kept == all)
        #expect(ordered * 4 < everything, "kept order \(ordered), every part \(everything)")
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
}
