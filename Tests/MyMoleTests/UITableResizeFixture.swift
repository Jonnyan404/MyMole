import AppKit
import StorageKit
import SwiftUI
import Testing

@testable import MyMole

/// One way to show a list while it is resized: its lines, the density and
/// how many rows, in memory or spilled to disk.
struct UITableResizeCase: CustomTestStringConvertible, Sendable {
    let lines: TableLines
    let density: Density
    let rows: Int
    let paged: Bool

    var name: String { "\(lines.rawValue).\(density.rawValue).\(paged ? "paged" : "rows").\(rows >= 1_000 ? "\(rows / 1_000)k" : "\(rows)")" }
    var testDescription: String { name }

    /// Every case, or the one MYMOLE_TABLE_CASE names, to look at alone.
    static let all: [UITableResizeCase] = {
        let only = ProcessInfo.processInfo.environment["MYMOLE_TABLE_CASE"]
        return every.filter { only == nil || $0.name == only }
    }()

    static let every: [UITableResizeCase] =
        TableLines.allCases.flatMap { lines in Density.allCases.map { UITableResizeCase(lines: lines, density: $0, rows: 10_000, paged: false) } }
        + [UITableResizeCase(lines: .grid, density: .spacious, rows: 1_000, paged: false),
           UITableResizeCase(lines: .grid, density: .spacious, rows: 100_000, paged: false),
           UITableResizeCase(lines: .grid, density: .spacious, rows: 100_000, paged: true)]
}

/// Synthetic rows like a cleanup list's: names, sizes, kinds, dates, places,
/// and a subtitle, badge or lock on some.
func uiTableRows(_ count: Int) -> [FileRow] {
    (0..<count).map { i in
        var row = FileRow(id: "/synthetic/area-\(i % 97)/folder-\(i % 991)/item-\(i).bin", name: String(format: "Synthetic item %06d.bin", i),
                          size: Int64((i &* 7_919) % 9_000_017) + 4_096, kind: ["Cache", "Log", "Archive", "Download"][i % 4],
                          location: "/synthetic/area-\(i % 97)/folder-\(i % 991)")
        row.modified = Date(timeIntervalSinceReferenceDate: Double(i % 86_400) * 60)
        if i % 3 == 0 { row.subtitle = "Kept by synthetic project \(i % 40)" }
        if i % 7 == 0 { row.badge = "Pinned" }
        row.locked = i % 11 == 0
        return row
    }
}

/// The list on the left of a split, the way a pane holds it: the window
/// edge and the divider both change its width. `width` is the panel to the
/// right of it.
struct UITableResizeView: View {
    let rows: [FileRow]
    let spill: SpillTable?
    let lines: TableLines
    let density: Density
    @Bindable var preferences: UISplitPreferences
    @State private var selection: Set<String> = []

    var body: some View {
        ListSplit(width: $preferences.width) {
            table
        } list: {
            Text("Synthetic panel").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .environment(\.tableLines, lines)
        .environment(\.layoutDensity, density)
    }

    @ViewBuilder private var table: some View {
        let columns: [FileColumn] = [.name, .size, .kind, .modified, .location]
        if let spill {
            PagedFileTable(table: spill, columns: columns, autosave: "", filterKey: 0, keep: { _ in true },
                           selection: $selection, marks: [])
        } else {
            FileTable(rows: rows, columns: columns, autosave: "", selection: $selection, marks: [])
        }
    }
}
