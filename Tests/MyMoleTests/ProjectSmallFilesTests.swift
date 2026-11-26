import AppKit
import Foundation
import StorageKit
import Testing

@testable import MyMole

/// Choosing and moving the small files counted together in a project's
/// folder, in synthetic projects with a Trash of their own.
@MainActor @Suite struct ProjectSmallFilesTests {
    private final class Box {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appending(path: "small-\(UUID().uuidString)").path
        var project: String { root + "/App" }
        var build: String { project + "/.build" }
        let model: ProjectsModel
        let item: FootprintItem

        @MainActor init(files: Int = 3) throws {
            for i in 0..<files { try Self.write(root + "/App/.build/f\(i).txt") }
            try Self.write(root + "/App/.build/out/x.o")
            try Self.write(root + "/App/Sources/main.swift")
            let build = root + "/App/.build"
            item = FootprintItem(id: root + "#build", category: .build, title: ".build", location: root + "/App", attribution: .inside,
                                 entries: [FootprintEntry(path: build, bytes: Int64(files + 1) * 4096, modified: .distantPast, isDirectory: true)])
            let store = URL(fileURLWithPath: root + "/store")
            model = ProjectsModel(footprints: [ProjectFootprint(project: DevProject(path: root + "/App", markers: ["Package.swift"]), items: [item])],
                                  base: store, defaults: testDefaults(in: store), logURL: store.appending(path: "history.json"),
                                  keepList: store.appending(path: "keep.json"))
            model.trashBackend = testBin(URL(fileURLWithPath: root))
            model.jobs = TrashJobs()
            let item = item
            model.measureProject = { project, _, _ in ProjectFootprint(project: project, items: [item]) }
            model.guardPath = { _, _, _ in nil }
            model.guardFiles = { _, _ in [:] }
        }
        deinit { try? FileManager.default.removeItem(atPath: root) }

        static func write(_ path: String) throws {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data(repeating: 7, count: 4096).write(to: URL(fileURLWithPath: path))
        }

        func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: build + "/" + name) }
        var small: Set<String> { Set((0..<3).map { build + "/f\($0).txt" }) }
        @MainActor func move() async throws {
            model.trashChosen()
            for _ in 0..<2_000 where model.trashing { try await Task.sleep(for: .milliseconds(5)) }
            try #require(!model.trashing)
        }
    }

    @Test func tickingTheRowChoosesTheFilesThereAndOnlyThoseGoAndComeBack() async throws {
        let box = try Box()
        let m = box.model
        #expect(m.smallFilesState(in: box.build) == .off)
        await m.toggleSmallFiles(in: box.build)?.value
        #expect(m.chosen == box.small && m.excluded.isEmpty)
        #expect(m.smallFilesState(in: box.build) == .on && m.check(box.item) == .mixed && m.state(of: box.build + "/out") == .off)
        #expect(m.chosenEntries.count == 3 && m.chosenBytes == 3 * 4096)
        // Made after the tick: not one of them.
        try Box.write(box.build + "/later.txt")
        try await box.move()
        #expect(!box.exists("f0.txt") && !box.exists("f1.txt") && !box.exists("f2.txt"), "\(m.notice?.text ?? "-")")
        #expect(box.exists("later.txt") && box.exists("out/x.o"))
        #expect(m.chosen.isEmpty && m.canUndo && m.smallFilesState(in: box.build) == .off)
        m.undoTrash()
        for _ in 0..<2_000 where m.trashing { try await Task.sleep(for: .milliseconds(5)) }
        #expect(box.exists("f0.txt") && box.exists("f1.txt") && box.exists("f2.txt"))
    }

    @Test func untickingThemInAChosenFolderLeavesThemBehind() async throws {
        let box = try Box()
        let m = box.model
        m.toggle(box.item)
        #expect(m.smallFilesState(in: box.build) == .on)
        await m.toggleSmallFiles(in: box.build)?.value
        #expect(m.chosen == [box.build] && m.excluded == box.small)
        #expect(m.smallFilesState(in: box.build) == .off && m.state(of: box.build + "/out") == .on && m.check(box.item) == .mixed)
        #expect(m.chosenBytes == 4096)
        // Ticked again, they're part of the folder again.
        await m.toggleSmallFiles(in: box.build)?.value
        #expect(m.chosen == [box.build] && m.excluded.isEmpty && m.check(box.item) == .on)
        await m.toggleSmallFiles(in: box.build)?.value
        try await box.move()
        #expect(box.exists("f0.txt") && box.exists("f2.txt") && !box.exists("out"))
    }

    @Test func theRowFollowsAChosenFolderWithSomethingElseLeftOut() async throws {
        let box = try Box()
        let m = box.model
        m.toggle(box.item)
        m.toggle(path: box.build + "/out")
        // The files still go, so the row is ticked.
        #expect(m.state(of: box.build) == .mixed && m.smallFilesState(in: box.build) == .on)
        m.toggle(path: box.build + "/f1.txt")
        #expect(m.smallFilesState(in: box.build) == .on)
        await m.toggleSmallFiles(in: box.build)?.value
        #expect(m.smallFilesState(in: box.build) == .off)
        m.toggle(path: box.build + "/f1.txt")
        #expect(m.smallFilesState(in: box.build) == .mixed)
        await m.toggleSmallFiles(in: box.build)?.value
        #expect(m.smallFilesState(in: box.build) == .on && m.excluded == [box.build + "/out"])
    }

    @Test func choosingTheFolderAfterwardsTakesEverythingAndClearingClearsThem() async throws {
        let box = try Box()
        let m = box.model
        await m.toggleSmallFiles(in: box.build)?.value
        m.toggle(box.item)
        #expect(m.chosen == [box.build] && m.smallFilesState(in: box.build) == .on && m.check(box.item) == .on)
        m.toggle(box.item)
        #expect(m.chosen.isEmpty && m.smallFilesState(in: box.build) == .off)
    }

    @Test func keptFilesAreNeverChosenAndAKeptFolderHasNothingToTick() async throws {
        let box = try Box()
        let m = box.model
        m.changeRules(project: box.project) { $0.keepPaths = [box.build + "/f1.txt"] }
        await m.toggleSmallFiles(in: box.build)?.value
        #expect(m.chosen == box.small.subtracting([box.build + "/f1.txt"]) && m.smallFilesState(in: box.build) == .on)
        m.chosen = []
        m.changeRules(project: box.project) { $0.keepPaths = [box.build] }
        #expect(m.toggleSmallFiles(in: box.build) == nil && m.chosen.isEmpty && m.smallFilesState(in: box.build) == .off)
    }

    @Test func filesGoneSinceTheLastTickArentLeftChosenAndAnEmptyReadChoosesNothing() async throws {
        let box = try Box()
        let m = box.model
        await m.toggleSmallFiles(in: box.build)?.value
        try FileManager.default.removeItem(atPath: box.build + "/f0.txt")
        await m.toggleSmallFiles(in: box.build)?.value
        #expect(m.chosen.isEmpty)
        await m.toggleSmallFiles(in: box.build)?.value
        #expect(m.chosen == box.small.subtracting([box.build + "/f0.txt"]))
        m.chosen = []
        m.readSmallFiles = { _ in nil }
        await m.toggleSmallFiles(in: box.build)?.value
        #expect(m.chosen.isEmpty && m.excluded.isEmpty)
    }

    @Test func aReadOverTakenByANewMeasurementChoosesNothing() async throws {
        let box = try Box()
        let m = box.model
        let gate = DispatchSemaphore(value: 0)
        m.readSmallFiles = { gate.wait(); return SmallFileList.read(in: $0) }
        m.contentsVersions[box.build] = 1
        let reading = m.toggleSmallFiles(in: box.build)
        // Ticked again before it's read: one read is enough.
        #expect(m.toggleSmallFiles(in: box.build) == nil)
        m.dropContents(touching: [box.build + "/out"])
        gate.signal()
        await reading?.value
        #expect(m.chosen.isEmpty && m.readingSmallFiles.isEmpty)
    }

    @Test func filesTheGuardHoldsStayWithTheReasonShown() async throws {
        let box = try Box()
        let m = box.model
        m.guardFiles = { paths, _ in Dictionary(uniqueKeysWithValues: paths.filter { $0.hasSuffix("f1.txt") }.map { ($0, "It's a key file.") }) }
        await m.toggleSmallFiles(in: box.build)?.value
        try await box.move()
        #expect(!box.exists("f0.txt") && box.exists("f1.txt") && !box.exists("f2.txt"))
        #expect(m.notice?.text.contains("It's a key file") == true && m.notice?.stays == true)
    }

    @Test func aFolderSwappedForALinkAfterTheTickMovesNothing() async throws {
        let box = try Box()
        let m = box.model
        await m.toggleSmallFiles(in: box.build)?.value
        try FileManager.default.moveItem(atPath: box.build, toPath: box.root + "/elsewhere")
        try FileManager.default.createSymbolicLink(atPath: box.build, withDestinationPath: box.root + "/elsewhere")
        try await box.move()
        for i in 0..<3 { #expect(FileManager.default.fileExists(atPath: box.root + "/elsewhere/f\(i).txt")) }
        #expect(m.notice?.text.hasPrefix("Nothing was moved to the Trash") == true)
    }

    /// The report: a folder held whole said "Moved 0 items" for four seconds.
    @Test func nothingMovedSaysSoWithTheReasonUntilClosed() async throws {
        let box = try Box()
        let m = box.model
        m.guardPath = { _, _, _ in "Holds a Git repository." }
        m.toggle(box.item)
        try await box.move()
        let text = try #require(m.notice?.text)
        #expect(text == "Nothing was moved to the Trash · 1 protected (Holds a Git repository)")
        #expect(m.notice?.stays == true && m.notice?.canUndo == false)
        #expect(box.exists("out/x.o") && box.exists("f0.txt"))
    }

    /// Many files in one folder are chosen and counted without work that
    /// grows with the square of their number.
    @Test func manyFilesAreChosenAndCountedInLinearTime() async throws {
        let count = 10_000
        let box = try Box(files: 0)
        let m = box.model
        let build = box.build
        let files = (0..<count).map { FootprintEntry(path: build + "/s\($0)", bytes: 4096, modified: .distantPast, isDirectory: false) }
        m.readSmallFiles = { _ in files }
        await m.toggleSmallFiles(in: build)?.value
        #expect(m.chosen.count == count)
        // The main thread's own CPU time: other tests running at once don't count.
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        m.choiceIndex = nil
        #expect(m.chosenEntries.count == count && m.chosenBytes == Int64(count) * 4096 && m.smallFilesState(in: build) == .on)
        let spent = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1e9
        print("10 000 small files: counted from nothing in \(spent) s of CPU")
        #expect(spent < 5)
        let whole = Set(files.map(\.path))
        #expect(files.allSatisfy { ProjectsModel.lies($0.path, in: whole) })
        #expect(!ProjectsModel.lies(build + "/other", in: whole) && ProjectsModel.lies(build + "/s1/inside", in: whole))
        await m.toggleSmallFiles(in: build)?.value
        #expect(m.chosen.isEmpty && m.excluded.isEmpty)
    }
}
