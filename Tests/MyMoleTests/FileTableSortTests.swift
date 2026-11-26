import AppKit
import SwiftUI
import Testing

@testable import MyMole

@MainActor
@Suite struct FileTableSortTests {
    /// Sorting by a value, then each run of equal values by name, gives the
    /// order of one sort with the name as tie-break: pinned rows first,
    /// whatever the direction.
    @Test func equalValuesAreOrderedByNameAsOneSortWouldOrderThem() {
        var generator = SplitMix(seed: 7)
        let rows: [FileRow] = (0..<2_000).map { i in
            var r = FileRow(id: "/synthetic/\(i)", name: "Item \(generator.next() % 300)", size: Int64(generator.next() % 40))
            r.modified = Date(timeIntervalSinceReferenceDate: Double(generator.next() % 25))
            r.pinned = generator.next() % 50 == 0
            return r
        }
        func reference<T: Comparable>(_ key: (FileRow) -> T, ascending: Bool) -> [String] {
            rows.sorted { a, b in
                if a.pinned != b.pinned { return a.pinned }
                let (x, y) = (key(a), key(b))
                if x == y { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
                return ascending ? x < y : x > y
            }.map(\.name)
        }
        for ascending in [true, false] {
            // Rows with the same value and the same name may come in either order; their names may not.
            #expect(FileTable.sorted(rows, by: .size, ascending: ascending).map(\.name) == reference({ $0.size ?? -1 }, ascending: ascending))
            #expect(FileTable.sorted(rows, by: .modified, ascending: ascending).map(\.name) == reference({ $0.modified ?? .distantPast }, ascending: ascending))
        }
    }

    @Test func pinsStayFirstInBothSortDirectionsWithoutChangingEligibility() {
        var pinned = FileRow(id: "/synthetic/Pinned", name: "Zeta", size: 1)
        pinned.pinned = true
        pinned.canChoose = false
        let ordinary = FileRow(id: "/synthetic/Ordinary", name: "Alpha", size: 10_000)
        for column in [FileColumn.name, .size] {
            for ascending in [true, false] {
                let sorted = FileTable.sorted([ordinary, pinned], by: column, ascending: ascending)
                #expect(sorted.first?.id == pinned.id)
                #expect(sorted.first?.canChoose == false)
            }
        }
    }
    private func fixture(selection: Binding<Set<String>> = .constant([])) -> (FileTable.Coordinator, FileTableView) {
        let view = FileTable(rows: [], columns: [.name, .size], autosave: "synthetic.sort", selection: selection)
        let coordinator = view.makeCoordinator()
        let table = FileTableView()
        table.sortDescriptors = [NSSortDescriptor(key: "size", ascending: false)]
        table.dataSource = coordinator
        coordinator.table = table
        return (coordinator, table)
    }

    private func rows(_ prefix: String, count: Int = 20_000) -> [FileRow] {
        (0..<count).map { FileRow(id: "/synthetic/\(prefix)/\($0)", name: "file-\($0)", size: Int64($0)) }
    }

    @Test func largeSortKeepsEarlierRowsUsableAndRestoresSelection() async throws {
        let large = rows("large")
        var selected: Set<String> = [large[123].id]
        let (coordinator, table) = fixture(selection: Binding(get: { selected }, set: { selected = $0 }))
        let earlier = rows("earlier", count: 1)
        coordinator.load(earlier, marks: nil, selection: selected)
        coordinator.load(large, marks: nil, selection: selected)
        #expect(coordinator.shown == earlier)
        let job = try #require(coordinator.sortJob)
        await job.value
        #expect(coordinator.shown.map(\.size) == large.reversed().map(\.size))
        #expect(table.selectedRowIndexes == IndexSet(integer: large.count - 1 - 123))
        #expect(selected == [large[123].id])
        #expect(coordinator.sortJob == nil)
    }

    @Test func newerLargeResultWinsOverASortInFlight() async throws {
        let (coordinator, table) = fixture()
        coordinator.load(rows("old"), marks: nil, selection: [])
        _ = try #require(coordinator.sortJob)
        await Task.yield()
        let newest = rows("new")
        coordinator.load(newest, marks: nil, selection: [])
        await coordinator.sortJob?.value
        #expect(coordinator.shown.map(\.id) == newest.reversed().map(\.id))
        #expect(table.numberOfRows == newest.count)
        #expect(coordinator.sortJob == nil)
    }

    @Test func anEmptyResultSupersedesPendingWorkImmediately() async throws {
        let (coordinator, table) = fixture()
        coordinator.load(rows("old"), marks: nil, selection: [])
        let job = try #require(coordinator.sortJob)
        coordinator.load([], marks: nil, selection: [])
        #expect(coordinator.shown.isEmpty)
        await job.value
        #expect(coordinator.shown.isEmpty && table.numberOfRows == 0)
    }

    @Test func previewFromAMenuTargetsItsOriginalIdentityAfterSortingAndRefusesADisappearedRow() {
        var selection = Set<String>()
        let (coordinator, table) = fixture(selection: Binding(get: { selection }, set: { selection = $0 }))
        let first = FileRow(id: "/synthetic/a", name: "A", size: 100)
        let second = FileRow(id: "/synthetic/b", name: "B", size: 200)
        coordinator.load([first, second], marks: [], selection: [])
        let original = coordinator.shown[0].id
        var changed = first
        changed.size = 300
        coordinator.load([changed, second], marks: [], selection: [])
        #expect(coordinator.selectForPreview([original]))
        #expect(selection == [original] && coordinator.shown[table.selectedRow].id == original)
        coordinator.load([changed], marks: [], selection: selection)
        #expect(!coordinator.selectForPreview([original]))
        #expect(coordinator.shown.count == 1)
    }

    @Test func bulkChoiceWaitsForTheCurrentFilteredPresentationAndNeverChecksStaleRows() async throws {
        let (coordinator, table) = fixture()
        var requested: [String] = []
        coordinator.parent.onSetMarks = { ids, _ in requested = ids }
        let earlier = rows("earlier", count: 1)
        coordinator.load(earlier, marks: [], selection: [])
        let newest = rows("newest")
        coordinator.load(newest, marks: [], selection: [])
        coordinator.setListedMarks(true)
        #expect(requested.isEmpty)
        await coordinator.sortJob?.value
        coordinator.setListedMarks(true)
        #expect(Set(requested) == Set(newest.map(\.id)))
        #expect(table.numberOfRows == newest.count)
    }

    @Test func dismantlingPreventsALateSortFromPublishing() async throws {
        let (coordinator, table) = fixture()
        let earlier = rows("earlier", count: 1)
        coordinator.load(earlier, marks: nil, selection: [])
        coordinator.load(rows("old"), marks: nil, selection: [])
        let job = try #require(coordinator.sortJob)
        coordinator.stopSorting()
        await job.value
        #expect(coordinator.shown == earlier && table.numberOfRows == 1)
    }

    @Test func unchangedRowsAndSelectionReuseThePreparedSnapshot() async throws {
        let input = rows("unchanged")
        let (coordinator, table) = fixture()
        coordinator.load(input, marks: [], selection: [])
        await coordinator.sortJob?.value
        for _ in 0..<20 {
            coordinator.load(input, marks: [input[10].id], selection: [input[15].id])
            #expect(coordinator.sortJob == nil)
        }
        #expect(table.selectedRowIndexes == IndexSet(integer: input.count - 1 - 15))
        #expect(coordinator.shown.first?.id == input.last?.id)
    }

    @Test func hiddenTableKeepsItsRowsAndResumesWithOnlyTheLatestResult() async throws {
        let (coordinator, table) = fixture()
        let earlier = rows("earlier", count: 1)
        coordinator.load(earlier, marks: nil, selection: [])
        coordinator.setPresentationActive(false)
        coordinator.load(rows("intermediate"), marks: nil, selection: [])
        await coordinator.sortJob?.value
        let latest = rows("latest")
        coordinator.load(latest, marks: nil, selection: [])
        await coordinator.sortJob?.value
        #expect(coordinator.shown == earlier && table.numberOfRows == 1)
        coordinator.setPresentationActive(true)
        for _ in 0..<100 where coordinator.shown.count != latest.count { try await Task.sleep(for: .milliseconds(5)) }
        #expect(coordinator.shown.map(\.id) == latest.reversed().map(\.id))
        #expect(table.numberOfRows == latest.count)
    }
}

/// A repeatable source of numbers for a test's rows.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
