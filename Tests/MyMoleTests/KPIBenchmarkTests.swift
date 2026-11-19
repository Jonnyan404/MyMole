import AppKit
import Foundation
@testable import StorageKit
import Synchronization
import SwiftUI
import SystemKit
import Testing

@testable import MyMole

/// Key measurements of how quick and steady MyMole is, each held to a
/// budget in `Tests/KPIBudgets.json`. Synthetic data only, made by the run.
/// An ordinary benchmark run allows four times the budget, as parallel
/// work and a busy Mac add noise; MYMOLE_STRICT_BENCHMARKS=1, run serially,
/// holds each measurement to its budget. Off unless MYMOLE_BENCHMARK=1.
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MYMOLE_BENCHMARK"] == "1"))
struct KPIBenchmarkTests {
    private final class Box {
        let root = FileManager.default.temporaryDirectory.appending(path: "kpi-\(UUID().uuidString)")
        var path: String { root.path }
        init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(at: root) }
        func file(_ rel: String, bytes: Int) {
            let url = root.appending(path: rel)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 1, count: bytes))
        }
    }

    // MARK: Budget gate

    private static let budgets: [String: Double] = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "KPIBudgets.json")
        guard let data = try? Data(contentsOf: url), let all = try? JSONSerialization.jsonObject(with: data) as? [String: Double] else { return [:] }
        return all
    }()
    private static let strict = ProcessInfo.processInfo.environment["MYMOLE_STRICT_BENCHMARKS"] == "1"
    static let tolerance = 4.0

    /// Prints "kpi <name> <value> budget <budget> <unit>" and fails when the
    /// value is past the budget (strict) or past four times it (tolerant).
    private static func gate(_ name: String, _ value: Double, unit: String = "ms") {
        guard let budget = budgets[name] else {
            Issue.record("KPI \(name) has no budget in KPIBudgets.json")
            return
        }
        let limit = strict ? budget : budget * tolerance
        print(String(format: "kpi %@ %.3f %@ budget %.3f %@", name, value, unit, budget, value <= limit ? "ok" : "MISS"))
        #expect(value <= limit, "\(name): \(value) \(unit) against \(limit) (\(strict ? "strict" : "tolerant"))")
    }

    private static func ms(_ work: () throws -> Void) rethrows -> Double {
        let start = ContinuousClock.now
        try work()
        return Double((ContinuousClock.now - start) / .microseconds(1)) / 1_000
    }

    private static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
    }

    // MARK: Large results, in memory and on disk

    private static func spillRows(_ n: Int) -> [SpillTable.Row] {
        (0..<n).map { i in
            SpillTable.Row(path: "/synthetic/folder-\(i % 997)/file-\(i).bin", size: Int64((i &* 7_919) % 100_003) + 1_048_576,
                           modified: Date(timeIntervalSinceReferenceDate: Double(i % 86_400)), kind: FileKind.allCases[i % FileKind.allCases.count])
        }
    }

    private static func tableRows(_ n: Int) -> [FileRow] {
        (0..<n).map { i in
            FileRow(id: "/synthetic/folder-\(i % 997)/file-\(i).bin", name: "file-\(i).bin", size: Int64((i &* 7_919) % 100_003),
                    modified: Date(timeIntervalSinceReferenceDate: Double(i % 86_400)), kind: "Other", location: "/synthetic/folder-\(i % 997)")
        }
    }

    @Test func listsInMemorySortAndFilterQuickly() {
        for (n, label) in [(100_000, "100k"), (1_000_000, "1m")] {
            let rows = Self.tableRows(n)
            Self.gate("ram.sort-size.\(label)", Self.ms { _ = FileTable.sorted(rows, by: .size, ascending: false) })
            Self.gate("ram.sort-name.\(label)", Self.ms { _ = FileTable.sorted(rows, by: .name, ascending: true) })
            // The lists' own filter: prepared once, each row's name and folder looked through.
            let query = TextQuery("file-12")
            var matched = 0
            Self.gate("ram.filter.\(label)", Self.ms { matched = rows.filter { query.matches($0.name, $0.location ?? "") }.count })
            #expect(matched > 0)
        }
    }

    @Test func spilledListsWriteReadSortAndFilterQuickly() throws {
        let box = try Box()
        for (n, label) in [(100_000, "100k"), (1_000_000, "1m")] {
            let rows = Self.spillRows(n)
            var table: SpillTable?
            Self.gate("spill.write.\(label)", try Self.ms { table = try SpillTable(writing: rows, in: box.root) })
            let spilled = try #require(table)
            // A screenful of rows at random places: what scrolling a long list reads.
            var generator = SystemRandomNumberGenerator()
            let reads = (0..<10_000).map { _ in Int.random(in: 0..<n, using: &generator) }
            Self.gate("spill.read-10k-rows.\(label)", Self.ms { for i in reads { _ = spilled.row(at: i) } })
            Self.gate("spill.scroll-page.\(label)", Self.ms { for i in 0..<40 { _ = spilled.row(at: n / 2 + i) } })
            var order: [UInt32]?
            Self.gate("spill.sort-size.\(label)", Self.ms { order = spilled.ordered(by: .size, ascending: false) })
            #expect(order?.count == n)
            Self.gate("spill.sort-name.\(label)", Self.ms { order = spilled.ordered(by: .name, ascending: true) })
            Self.gate("spill.filter.\(label)", Self.ms { order = spilled.ordered(by: .size, ascending: false, query: "folder-12") })
            #expect(order?.isEmpty == false)
            Self.gate("spill.disk-mb.\(label)", Double(spilled.diskBytes) / 1_048_576, unit: "MB")
            spilled.remove()
        }
    }

    // MARK: Scans

    @Test func diskMapAndProjectsScanSyntheticTreesQuickly() throws {
        let box = try Box()
        for folder in 0..<200 { for file in 0..<100 { box.file("tree/f\(folder)/file-\(file).bin", bytes: 64) } }
        for project in 0..<100 {
            box.file("work/p\(project)/Package.swift", bytes: 32)
            for file in 0..<50 { box.file("work/p\(project)/.build/obj-\(file).o", bytes: 64) }
        }
        let tree = box.path + "/tree"
        _ = StorageScanner.scan(path: tree)
        Self.gate("scan.disk-map.20k-files", Self.ms { _ = StorageScanner.scan(path: tree, workers: PerformanceLevel.full.workers(background: false)) })
        let roots = [box.path + "/work"]
        Self.gate("scan.projects.100", Self.ms { _ = ProjectScanner.scan(roots: roots, home: box.path + "/home") })
    }

    /// Many folders with little in each, as a dependency tree is: what the
    /// walk does once per folder shows here and not among many files. One
    /// walker, so that work isn't spread over the cores.
    @Test func diskMapWalksManyFoldersQuickly() throws {
        let box = try Box()
        for branch in 0..<20 { for twig in 0..<20 { for leaf in 0..<25 { box.file("deep/branch-\(branch)/twig-\(twig)/leaf-\(leaf)/a.txt", bytes: 1) } } }
        let tree = box.path + "/deep"
        _ = StorageScanner.scan(path: tree)
        Self.gate("scan.disk-map.10k-folders.one-walker", Self.ms { _ = StorageScanner.scan(path: tree, workers: 1) })
    }

    /// How soon a walk under way ends once it's asked to.
    @Test func aWalkUnderWayStopsAtOnce() throws {
        let box = try Box()
        for branch in 0..<20 { for twig in 0..<20 { for leaf in 0..<25 { box.file("deep/branch-\(branch)/twig-\(twig)/leaf-\(leaf)/a.txt", bytes: 1) } } }
        let tree = box.path + "/deep"
        _ = StorageScanner.scan(path: tree)
        let progress = ScanProgress()
        let ended = Mutex<ContinuousClock.Instant?>(nil)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = StorageScanner.scan(path: tree, progress: progress, workers: 1)
            ended.withLock { $0 = .now }
            finished.signal()
        }
        Thread.sleep(forTimeInterval: 0.02)
        let asked = ContinuousClock.now
        progress.cancel()
        finished.wait()
        let end = try #require(ended.withLock { $0 })
        // A walk that ended by itself before the stop says nothing about stopping.
        try #require(end > asked && progress.folders < 10_000)
        Self.gate("scan.stop", Double((end - asked) / .microseconds(1)) / 1_000)
    }

    /// Walks waiting on the disk hold threads of their own, so a task
    /// started meanwhile starts at once, however many of them there are.
    @Test func blockedWalksDoNotHoldUpOtherTasks() async throws {
        let walks = ProcessInfo.processInfo.activeProcessorCount + 2
        let budget = ScanBudget(slots: .max)
        let release = DispatchSemaphore(value: 0)
        let blocked = (0..<walks).map { _ in
            Task.detached(priority: .userInitiated) { await budget.walk(background: false) { release.wait() } }
        }
        // Held up or not, the walks end: a task that never started would otherwise never be measured.
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { for _ in 0..<walks { release.signal() } }
        while budget.running < walks { try await Task.sleep(for: .milliseconds(2)) }
        let asked = ContinuousClock.now
        let started = await Task.detached(priority: .userInitiated) { ContinuousClock.now }.value
        Self.gate("tasks.start-while-walks-block", Double((started - asked) / .microseconds(1)) / 1_000)
        for _ in 0..<walks { release.signal() }
        for task in blocked { _ = await task.value }
    }

    // MARK: A finished map: its lists, search, one folder read again, memory

    /// A map as a scan leaves it: `chains` folders under the root, each
    /// `depth` folders deep, every folder holding `files` listed files.
    private static func map(chains: Int, depth: Int, files: Int) -> Folder {
        let root = Folder(name: "synthetic", parent: nil, rootPath: "/synthetic")
        for chain in 0..<chains {
            var parent = root
            for level in 0..<depth {
                let folder = Folder(name: level == 0 ? "chain-\(chain)" : "level-\(level)", parent: parent)
                folder.listedFiles = (0..<files).map { i in
                    FileItem(name: "file-\(i).bin", size: Int64((chain * 31 + level * 7 + i) % 100_003) + 1_048_576, modified: .distantPast, kind: .other)
                }
                for item in folder.listedFiles { folder.ownBytes[.other] += item.size }
                parent.subfolders.append(folder)
                parent = folder
            }
        }
        root.finish()
        return root
    }

    /// Bytes the process has allocated and not freed: unlike its footprint,
    /// unmoved by memory an earlier test gave back.
    private static func allocated() -> Int64 {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Int64(stats.size_in_use)
    }

    /// What follows the walk before a map is complete, and searching it whole.
    @Test func aFinishedMapIsPreparedAndSearchedQuickly() throws {
        let tree = Self.map(chains: 400, depth: 10, files: 50)
        var large: [LargeFile] = []
        var index: ScanIndex?
        Self.gate("disk-map.prepare.200k-files", Self.ms {
            large = StorageModel.collectLargeFiles(tree, limit: .max)
            index = ScanIndex(tree, limit: .max)
            _ = Snapshot(of: tree)
        })
        #expect(large.count == 200_000)
        let built = try #require(index)
        var found = 0
        Self.gate("disk-map.search.200k-files", Self.ms { found = built.search("file-4 level-7").found.count })
        #expect(found > 0)
    }

    /// Refresh Current Folder copies the map around the folder read again.
    @Test func oneFolderOfALargeMapIsReadAgainQuickly() throws {
        let tree = Self.map(chains: 1_000, depth: 100, files: 0)
        let fresh = Folder(name: "level-50", parent: nil, rootPath: tree.path + "/chain-7" + (1...50).map { "/level-\($0)" }.joined())
        fresh.finish()
        var replaced: Folder?
        Self.gate("disk-map.refresh-folder.100k-folders", Self.ms { replaced = tree.replacingSubtree(at: fresh.path, with: fresh) })
        #expect(replaced?.find(path: fresh.path)?.subfolders.isEmpty == true)
    }

    /// What a rescan does before it reads: the changed folders put onto
    /// a map of 100,000 folders, and the watcher handing them over.
    @Test func changedFoldersAreFoundOnALargeMapQuickly() async throws {
        let tree = Self.map(chains: 1_000, depth: 100, files: 0)
        let changed = (0..<1_000).map { i in tree.path + "/chain-\(i)" + (1...(i % 100 + 1)).map { "/level-\($0)" }.joined() + "/new-\(i)" }
        var read: [String] = []
        Self.gate("disk-map.changed-folders.1k-in-100k", Self.ms { read = ChangedFolders.toRead(changed, in: tree) })
        #expect(read.count == 1_000)

        let box = try Box()
        for i in 0..<100 { box.file("w/f\(i)/seed.bin", bytes: 1) }
        try await Task.sleep(for: .seconds(1))
        let watcher = try #require(ChangedFolders.Watcher(root: box.path + "/w", since: ChangedFolders.now()))
        for i in 0..<1_000 { box.file("w/f\(i % 100)/n\(i).bin", bytes: 1) }
        // The events reach the system's history a moment later; the flush that finds them is timed.
        var found: [String]? = []
        var took = 0.0
        for _ in 0..<40 where found?.isEmpty == true {
            try await Task.sleep(for: .milliseconds(250))
            took = Self.ms { found = watcher.flush() }
        }
        Self.gate("disk-map.watcher-flush.1k-changes", took)
        #expect(found?.isEmpty == false)
    }

    /// Two hundred pairs of copies made to share their storage: each is
    /// compared again, cloned, given its metadata and swapped in.
    @Test func copiesShareTheirStorageQuickly() throws {
        let box = try Box()
        for i in 0..<200 {
            var bytes = Data(repeating: UInt8(i % 251), count: 1_048_576)
            bytes[0] = UInt8(i / 251)
            try bytes.write(to: box.root.appending(path: "a/\(i).bin").creatingFolder())
            try bytes.write(to: box.root.appending(path: "b/\(i).bin").creatingFolder())
        }
        try FileManager.default.createDirectory(at: box.root.appending(path: "Bin"), withIntermediateDirectories: true)
        let groups = DuplicateFinder.find(in: [box.path + "/a", box.path + "/b"], minimum: 100_000, workers: 2).groups
        let chosen = Set(groups.compactMap { $0.files.last?.path })
        let plan = CloneSharing.plan(groups, chosen: chosen)
        try #require(plan.shares.count == 200, "the run's folder is on APFS")
        var out = CloneSharing.Outcome()
        Self.gate("duplicates.share-storage.200", Self.ms {
            out = CloneSharing.share(plan, groups: groups, home: box.path, backend: .folder(box.path + "/Bin"))
        })
        #expect(out.shared.count == 200)
    }

    /// Hyperspeed lets every scan in at once, each walk on a thread of its
    /// own: 300 at once finish, and how many threads that takes is measured.
    @Test func hyperspeedRunsHundredsOfScansAtOnce() async throws {
        let box = try Box()
        for i in 0..<300 { for j in 0..<20 { box.file("s\(i)/f\(j).bin", bytes: 1) } }
        let budget = ScanBudget(slots: Int.max)
        let peak = Atomic(0)
        let sampling = Atomic(true)
        let sampler = Thread {
            while sampling.load(ordering: .relaxed) {
                let n = Self.threadCount()
                if n > peak.load(ordering: .relaxed) { peak.store(n, ordering: .relaxed) }
                Thread.sleep(forTimeInterval: 0.002)
            }
        }
        sampler.start()
        let base = box.path
        var done = 0
        let took = try await Self.msAsync {
            done = await withTaskGroup(of: Int.self) { group in
                for i in 0..<300 {
                    group.addTask {
                        await budget.walk(background: false) { StorageScanner.scan(path: base + "/s\(i)", workers: 1).root.fileCount } ?? 0
                    }
                }
                var whole = 0
                for await n in group where n == 20 { whole += 1 }
                return whole
            }
        }
        sampling.store(false, ordering: .relaxed)
        #expect(done == 300)
        Self.gate("scan.hyperspeed.300-at-once", took)
        Self.gate("scan.hyperspeed.300-at-once.peak-threads", Double(peak.load(ordering: .relaxed)), unit: "threads")
    }

    private static func msAsync(_ work: () async throws -> Void) async rethrows -> Double {
        let start = ContinuousClock.now
        try await work()
        return Double((ContinuousClock.now - start) / .microseconds(1)) / 1_000
    }

    /// Threads this process has now.
    nonisolated static func threadCount() -> Int {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return 0 }
        for i in 0..<Int(count) { mach_port_deallocate(mach_task_self_, list[i]) }
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)), vm_size_t(Int(count) * MemoryLayout<thread_act_t>.stride))
        return Int(count)
    }

    @Test func aMapTakesLittleMemoryForEachFolder() {
        let before = Self.allocated()
        let tree = Self.map(chains: 2_000, depth: 50, files: 0)
        Self.gate("memory.disk-map.bytes-per-folder", Double(Self.allocated() - before) / 100_001, unit: "B")
        withExtendedLifetime(tree) {}
    }

    // MARK: Changes

    @Test func twoSavedScansAreComparedQuickly() throws {
        let box = try Box()
        func snapshot(grown: Int64, at date: Date) -> Snapshot {
            var sizes: [String: Int64] = ["": 1 << 40]
            var files: [String: Int64] = [:]
            for a in 0..<200 { for b in 0..<50 { sizes["a\(a)/b\(b)"] = Int64(a * 50 + b + 1) * 20_000_000 + (b % 7 == 0 ? grown : 0) } }
            for f in 0..<10_000 { files["a\(f % 200)/b\(f % 50)/video-\(f).mov"] = 60_000_000 + (f % 11 == 0 ? grown : 0) }
            return Snapshot(rootPath: "/synthetic", date: date, sizes: sizes, files: files)
        }
        let older = snapshot(grown: 0, at: Date(timeIntervalSince1970: 1_000_000))
        let newer = snapshot(grown: 80_000_000, at: Date(timeIntervalSince1970: 1_090_000))
        var saved: [SnapshotRef] = []
        Self.gate("changes.save-two-scans", Self.ms { saved = [older, newer].compactMap { SnapshotStore.save($0, base: box.root) } })
        try #require(saved.count == 2)
        var result: StorageModel.Comparison?
        Self.gate("changes.load-and-compare", Self.ms { result = StorageModel.comparison(SnapshotStore.load(saved[0]), SnapshotStore.load(saved[1])) })
        #expect(result?.changes.isEmpty == false && result?.problem == nil)
    }

    // MARK: The other panes' searches

    @Test func appsAndCachesAreListedQuickly() throws {
        let box = try Box()
        for i in 0..<100 {
            let contents = "Applications/Canvas\(i).app/Contents"
            box.file(contents + "/Resources/item0", bytes: 0)
            let info: NSDictionary = ["CFBundleIdentifier": "org.example.Canvas\(i)", "CFBundleName": "Canvas\(i)"]
            try info.write(to: box.root.appending(path: contents + "/Info.plist"))
            for f in 1..<100 { box.file(contents + "/Resources/item\(f)", bytes: 0) }
        }
        let places = [box.path + "/Applications"]
        _ = AppFinder.list(in: places)
        // The names appear first; the listing stops where sizes would start.
        Self.gate("apps.inventory.100", Self.ms {
            let progress = ScanProgress()
            _ = AppFinder.list(in: places, progress: progress) { _ in progress.cancel() }
        })
        var measured = 0
        Self.gate("apps.sizes.100", Self.ms { measured = AppFinder.list(in: places).apps.count })
        #expect(measured == 100)

        for cache in 0..<200 { for f in 0..<20 { box.file("home/Library/Caches/org.example.cache\(cache)/part-\(f)", bytes: 64) } }
        for log in 0..<50 { box.file("home/Library/Logs/Example\(log)/run.log", bytes: 64) }
        _ = CleanScanner.list(home: box.path + "/home")
        var candidates = 0
        Self.gate("deep-clean.scan.250-places", Self.ms { candidates = CleanScanner.list(home: box.path + "/home").candidates.count })
        #expect(candidates >= 250)

        // Temporary folders as tools leave them: a folder for each tool, one
        // in it for each project and one in that for each run.
        for tool in 0..<20 { for project in 0..<10 { for run in 0..<20 { box.file("temp/tool\(tool)-501/project\(project)/run\(run)/out.bin", bytes: 64) } } }
        let temp = try #require(Trasher.realPath(box.path + "/temp"))
        _ = CleanScanner.temporary(in: [temp], inUse: [])
        var inUse: Int64 = 0
        Self.gate("deep-clean.temporary.4k-folders", Self.ms { inUse = CleanScanner.temporary(in: [temp], inUse: []).inUseBytes })
        #expect(inUse > 0)
    }

    @Test func identicalFilesAndSimilarPicturesAreFoundQuickly() throws {
        let box = try Box()
        try FileManager.default.createDirectory(at: box.root.appending(path: "files"), withIntermediateDirectories: true)
        for pair in 0..<1_000 {
            var content = Data(repeating: UInt8(pair % 251), count: 8_192)
            withUnsafeBytes(of: UInt64(pair)) { content.replaceSubrange(0..<8, with: $0) }
            for copy in ["a", "b"] { FileManager.default.createFile(atPath: box.path + "/files/f\(pair)-\(copy).bin", contents: content) }
        }
        var groups = 0
        Self.gate("duplicates.2k-files", Self.ms { groups = DuplicateFinder.find(in: [box.path + "/files"], minimum: 4_096, workers: 4).groups.count })
        #expect(groups == 1_000)

        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        let prints = (0..<20_000).map { i -> (SimilarImage, UInt64) in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return (SimilarImage(path: "/synthetic/\(i).jpg", bytes: 1, modified: .distantPast, width: 1, height: 1, inode: 0, length: 1), state)
        }
        Self.gate("similar.group-20k-pictures", Self.ms { _ = SimilarImages.group(prints) })
    }

    /// Opening an uninstall review, Left by Removed Apps and Installers, in
    /// a Library that 300 apps have left their folders in.
    @Test func leftoversAndInstallersAreFoundQuickly() throws {
        let box = try Box()
        for i in 0..<300 {
            let id = "com.example.app\(i)"
            box.file("home/Library/Caches/\(id)/cache", bytes: 64)
            box.file("home/Library/Preferences/\(id).plist", bytes: 64)
            box.file("home/Library/Application Support/\(id)/data", bytes: 64)
        }
        let home = box.path + "/home"
        let app = AppBundle(path: home + "/Applications/App7.app", name: "App7", bundleID: "com.example.app7", version: nil, bytes: 0, fromAppStore: false)
        _ = AppLeftovers.list(for: app, home: home, installed: [app], deep: true)
        var leftovers = 0
        Self.gate("uninstall.leftovers.one-app", Self.ms { leftovers = AppLeftovers.list(for: app, home: home, installed: [app], deep: true).items.count })
        #expect(leftovers >= 1)
        // Another maker's app is installed; the 300 have none left that answers to them.
        box.file("home/Applications/Viewer.app/Contents/Resources/item", bytes: 0)
        try (["CFBundleIdentifier": "org.other.Viewer", "CFBundleName": "Viewer"] as NSDictionary)
            .write(to: box.root.appending(path: "home/Applications/Viewer.app/Contents/Info.plist"))
        let installed = [try #require(AppFinder.metadata(home + "/Applications/Viewer.app"))]
        _ = Orphans.list(home: home, installed: installed, known: { _ in false }, running: [])
        var orphans = 0
        Self.gate("uninstall.removed-apps.300", Self.ms { orphans = Orphans.list(home: home, installed: installed, known: { _ in false }, running: []).orphans.count })
        #expect(orphans > 0)

        for i in 0..<200 { box.file("home/Downloads/Installer-\(i).\(i % 2 == 0 ? "dmg" : "pkg")", bytes: 4_096) }
        for i in 0..<2_000 { box.file("home/Downloads/notes/note-\(i).txt", bytes: 16) }
        let places = [InstallerLocation(path: home + "/Downloads", depth: 2)]
        _ = InstallerFinder.list(in: places)
        var installers = 0
        Self.gate("installers.scan.200", Self.ms { installers = InstallerFinder.list(in: places).files.count })
        #expect(installers == 200)
    }

    /// Similar Photos reads its saved fingerprints at every search and writes them after.
    @Test func savedFingerprintsAreReadAndWrittenQuickly() throws {
        let box = try Box()
        var cache = FingerprintCache()
        for i in 0..<50_000 {
            cache.store(FingerprintCache.key(device: 1, inode: UInt64(i), length: Int64(i) + 1, modified: Date(timeIntervalSince1970: Double(i))),
                        print: UInt64(i) &* 0x9E37_79B9_7F4A_7C15, width: 100, height: 100)
        }
        let url = box.root.appending(path: "fingerprints/pictures.bin")
        Self.gate("similar.fingerprints.save-50k", Self.ms { cache.save(to: url) })
        var loaded = FingerprintCache()
        Self.gate("similar.fingerprints.load-50k", Self.ms { loaded = FingerprintCache.load(from: url) })
        #expect(loaded.entries.count == 50_000)
    }

    // MARK: Live Status

    /// One reading of the Mac, as Live Status takes every two seconds while it shows.
    @Test func oneReadingOfTheMacIsQuick() {
        let sampler = SystemSampler(warmup: .zero)
        _ = sampler.sample()
        Self.gate("status.reading", Self.ms { _ = sampler.sample() })
    }

    /// Scans `path` with a fresh model while a plain main-queue timer
    /// records the longest gap between its ticks: how long the main thread
    /// was ever kept from drawing.
    private func worstMainGap(scanning path: String, in box: Box) async throws -> (gap: Double, mb: Double, mapped: Bool) {
        let model = StorageModel()
        model.snapshotBase = box.root.appending(path: "snapshots-\(UUID().uuidString)")
        model.protections = UserProtections(root: box.root.appending(path: "support"))
        model.logURL = box.root.appending(path: "history.json")
        model.trashBackend = testBin(box.root)
        model.jobs = TrashJobs()
        model.scanBudget = ScanBudget(slots: 1)
        let worst = Mutex<Duration>(.zero), last = Mutex(ContinuousClock.now)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(1))
        timer.setEventHandler {
            let now = ContinuousClock.now
            let gap = last.withLock { l in defer { l = now }; return now - l }
            worst.withLock { $0 = max($0, gap) }
        }
        let before = Self.residentMB()
        timer.resume()
        defer { timer.cancel() }
        model.scan(path: path)
        while model.scanning { try await Task.sleep(for: .milliseconds(1)) }
        await model.scanJob?.value
        return (Double(worst.withLock { $0 } / .microseconds(1)) / 1_000, max(0, Self.residentMB() - before), model.root != nil)
    }

    @Test func aDiskMapScanNeverStallsTheMainThread() async throws {
        let box = try Box()
        for folder in 0..<300 { for file in 0..<100 { box.file("tree/f\(folder)/file-\(file).bin", bytes: 64) } }
        // The first scan after launch also pays for code and threads used for the first time.
        let first = try await worstMainGap(scanning: box.path + "/tree", in: box)
        Self.gate("main.worst-gap.first-disk-map-scan", first.gap)
        let warm = try await worstMainGap(scanning: box.path + "/tree", in: box)
        Self.gate("main.worst-gap.disk-map-scan", warm.gap)
        Self.gate("memory.disk-map-scan-30k-files", warm.mb, unit: "MB")
        #expect(first.mapped && warm.mapped)
    }

    // MARK: First frame

    @Test func theFirstFrameOfASavedScanIsQuick() async throws {
        let box = try Box()
        for folder in 0..<300 { for file in 0..<100 { box.file("tree/f\(folder)/file-\(file).bin", bytes: 64) } }
        for file in 0..<200 { box.file("tree/big/file-\(file).bin", bytes: 1_100_000) }
        let saved = box.root.appending(path: "saved.mymolescan")
        try ScanExport(of: StorageScanner.scan(path: box.path + "/tree").root).data().write(to: saved)
        let model = StorageModel()
        model.snapshotBase = box.root.appending(path: "snapshots")
        model.protections = UserProtections(root: box.root.appending(path: "support"))
        model.logURL = box.root.appending(path: "history.json")
        model.trashBackend = testBin(box.root)
        model.jobs = TrashJobs()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        // Owned by this test, not by closing it.
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: StorageView(model: model))
        window.contentView = host
        defer { window.close() }
        // From reading the saved result off disk to the pane drawn with it.
        let start = ContinuousClock.now
        await model.open(exported: saved)
        host.layoutSubtreeIfNeeded()
        host.display()
        Self.gate("launch.first-frame-saved-scan", Double((ContinuousClock.now - start) / .microseconds(1)) / 1_000)
        #expect(model.root != nil && model.largeFiles.count == 200)
    }

    // MARK: Trash and Undo

    @Test func movingManyItemsAndPuttingThemBackIsQuick() throws {
        let box = try Box()
        let paths = (0..<2_000).map { i -> String in
            box.file("items/item-\(i).txt", bytes: 16)
            return box.path + "/items/item-\(i).txt"
        }
        let gate = TrashGate(still: { _ in true }, protections: TrashGate.keepsNothing)
        var outcome: TrashOutcome?
        Self.gate("trash.move-2k", Self.ms { outcome = Trasher.moveToTrash(paths, through: gate, backend: testBin(box.root)) })
        let moved = try #require(outcome?.moved)
        #expect(moved.count == 2_000)
        var failed: [TrashRecord] = []
        Self.gate("trash.undo-2k", Self.ms { failed = Trasher.restore(moved) })
        #expect(failed.isEmpty && paths.allSatisfy { FileManager.default.fileExists(atPath: $0) })
    }
}

private extension URL {
    /// The URL, with the folder that holds it made first.
    func creatingFolder() throws -> URL {
        try FileManager.default.createDirectory(at: deletingLastPathComponent(), withIntermediateDirectories: true)
        return self
    }
}
