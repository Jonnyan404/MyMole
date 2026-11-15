import AppKit
import StorageKit
import SwiftUI
import Testing

@testable import MyMole
@testable import StorageKit

/// Maps to move around in, made in memory: one the size of a real home
/// folder, and the shapes that are hardest to draw.
enum UIDiskMapKind: String, CaseIterable, CustomTestStringConvertible, Sendable {
    /// About 750,000 folders and 1.5 million files, sized unevenly.
    case home
    /// One folder holding 50,000 folders.
    case wide
    /// A chain of folders 3,000 deep.
    case deep
    /// One large folder beside 20,000 tiny ones.
    case tiny

    var testDescription: String { rawValue }

    /// The p95 main-thread time a navigation step may take: one frame on a
    /// home-sized map, two on the extreme shapes, where one step charts and
    /// lists tens of thousands of folders. Every map keeps p99 within two
    /// frames.
    var inputBudget: Double { self == .home ? 16.7 : 33.3 }

    /// The p95 of the longest the main thread is held up during a step,
    /// the step and the new layout's drawing together: two frames on a
    /// home-sized map, three on the extreme shapes.
    var stallBudget: Double { self == .home ? 33 : 50 }

    /// Every map, or the one MYMOLE_DISK_MAP names, to look at alone.
    static var chosen: [UIDiskMapKind] {
        let only = ProcessInfo.processInfo.environment["MYMOLE_DISK_MAP"]
        return allCases.filter { only == nil || $0.rawValue == only }
    }

    @MainActor func build() -> Folder {
        let root = Folder(name: "Synthetic home", parent: nil, rootPath: "/synthetic/home")
        // Uneven sizes, as on a real disk: a few large, many small.
        func bytes(_ i: Int) -> Int64 { Int64(4_096 + (i &* 2_654_435_761) % 9_000_000) * Int64(1 + (i % 7 == 0 ? 40 : 0)) }
        func leaf(_ name: String, in parent: Folder, files: Int, seed: Int) -> Folder {
            let f = Folder(name: name, parent: parent)
            f.smallFileCount = files
            f.smallFileBytes = bytes(seed)
            f.ownBytes[.other] = f.smallFileBytes
            return f
        }
        switch self {
        case .home:
            var seed = 0
            root.subfolders = (0..<25).map { a in
                let area = Folder(name: "Area \(a)", parent: root)
                area.subfolders = (0..<40).map { d in
                    let dir = Folder(name: "Folder \(a)-\(d)", parent: area)
                    dir.subfolders = (0..<50).map { s in
                        let sub = Folder(name: "Part \(s)", parent: dir)
                        sub.subfolders = (0..<14).map { l in
                            seed += 1
                            return leaf("Item \(l)", in: sub, files: 2, seed: seed)
                        }
                        return sub
                    }
                    return dir
                }
                return area
            }
        case .wide:
            let wide = Folder(name: "Wide", parent: root)
            wide.subfolders = (0..<50_000).map { leaf("Entry \($0)", in: wide, files: 3, seed: $0) }
            root.subfolders = [wide] + (0..<20).map { leaf("Beside \($0)", in: root, files: 2, seed: $0 + 90_000) }
        case .deep:
            var parent = root
            for depth in 0..<3_000 {
                let next = Folder(name: "Level \(depth)", parent: parent)
                parent.subfolders = [next, leaf("Side \(depth)", in: parent, files: 1, seed: depth)]
                parent = next
            }
            parent.subfolders = [leaf("Bottom", in: parent, files: 10, seed: 7)]
        case .tiny:
            let large = leaf("Large", in: root, files: 1, seed: 1)
            large.smallFileBytes = 400_000_000_000
            large.ownBytes[.other] = large.smallFileBytes
            root.subfolders = [large] + (0..<20_000).map { i in
                let f = leaf("Tiny \(i)", in: root, files: 1, seed: i)
                f.smallFileBytes = 1_024
                f.ownBytes[.other] = 1_024
                return f
            }
        }
        root.finish()
        return root
    }
}

/// A model showing `kind`'s map, as a saved scan does.
@MainActor func syntheticNavigationModel(_ kind: UIDiskMapKind, in directory: URL) -> StorageModel {
    let tree = kind.build()
    let model = StorageModel()
    model.snapshotBase = directory.appending(path: "snapshots")
    model.protections = UserProtections(root: directory.appending(path: "protections"))
    model.logURL = directory.appending(path: "history.json")
    model.trashBackend = testBin(directory)
    model.jobs = TrashJobs()
    model.settings = testDefaults(in: directory)
    model.present(tree, rootPath: "/synthetic/home", index: ScanIndex(tree, limit: 10_000), large: [], opened: ("synthetic", .now))
    return model
}

/// The Disk Map's own parts: the path above, the chart the model has
/// chosen, and the list beside it.
struct UIDiskNavigationView: View {
    let model: StorageModel
    @Bindable var preferences: UISplitPreferences

    var body: some View {
        VStack(spacing: 0) {
            PathBar(model: model)
            ListSplit(width: $preferences.width) {
                Group {
                    switch model.chart {
                    case .rings: SunburstChart(model: model)
                    case .wheel: SliceChart(model: model, style: .wheel)
                    case .pie: SliceChart(model: model, style: .pie)
                    case .boxes: TreemapChart(model: model)
                    case .columns: ColumnsChart(model: model)
                    case .bars: BarsChart(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } list: {
                InspectorList(model: model)
            }
        }
    }
}
