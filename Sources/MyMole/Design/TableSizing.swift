import AppKit
import SwiftUI

enum NativeListViewport {
    /// A bounded scroll viewport takes the parent's proposal. Document rows
    /// and manually widened columns must not resize the surrounding SwiftUI.
    nonisolated static func size(_ proposal: ProposedViewSize) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height,
              width.isFinite, height.isFinite else { return nil }
        return CGSize(width: max(0, width), height: max(0, height))
    }
}

@MainActor protocol ColumnWidthProviding {
    var preferredColumnWidth: CGFloat { get }
}

extension NSTableView {
    func configureRows(height: CGFloat) {
        usesAutomaticRowHeights = false
        rowSizeStyle = .custom
        rowHeight = height
    }

    func configureUserColumns(hiddenByDefault: Set<String> = []) {
        (self as? any UserColumnTable)?.defaultHiddenColumns = hiddenByDefault
        tableColumn(withIdentifier: .init(FileColumn.name.rawValue))?.isHidden = false
        allowsColumnResizing = true
        allowsColumnReordering = true
        columnAutoresizingStyle = .noColumnAutoresizing
        (self as? NSOutlineView)?.autoresizesOutlineColumn = false
        for column in tableColumns {
            column.resizingMask = .userResizingMask
            if let field = FileColumn(rawValue: column.identifier.rawValue) { column.maxWidth = field.width.max }
        }
        enclosingScrollView?.hasHorizontalScroller = true
        headerView?.toolTip = String(localized: "Drag column dividers to resize. Double-click a divider to fit visible contents. Right-click a heading to show or hide columns. Scroll sideways or hover to read full text.")
    }

    /// Fill unused space without shrinking any user-chosen column width.
    func fitFlexibleColumn(_ id: String) {
        if let viewport = (self as? any UserColumnTable)?.columnViewport, viewport.id == id {
            viewport.fit()
            return
        }
        guard let clip = enclosingScrollView?.contentView, clip.bounds.width > 0,
              let flexible = tableColumn(withIdentifier: .init(id)), !flexible.isHidden else { return }
        let extra = clip.bounds.width - columnsWidth
        if extra > 0.5 { flexible.width = min(flexible.maxWidth, flexible.width + extra) }
        updateScrollableWidth()
    }

    /// Whether the Size column ends past the viewport's width: then the
    /// size moves under each name until the column fits again.
    var sizeColumnOutOfView: Bool {
        guard let clip = enclosingScrollView?.contentView, clip.bounds.width > 0,
              let index = tableColumns.firstIndex(where: { $0.identifier.rawValue == FileColumn.size.rawValue }),
              !tableColumns[index].isHidden else { return false }
        return rect(ofColumn: index).maxX > clip.bounds.width + 0.5
    }

    private func updateSizeOutOfView() {
        guard let table = self as? any UserColumnTable else { return }
        let out = sizeColumnOutOfView
        guard out != table.sizeOutOfView else { return }
        table.sizeOutOfView = out
        enumerateAvailableRowViews { row, _ in
            for index in 0..<row.numberOfColumns {
                (row.view(atColumn: index) as? FileNameCell)?.sizeInSubtitle = out
            }
        }
    }

    fileprivate var columnsWidth: CGFloat {
        let visible = tableColumns.indices.filter { !tableColumns[$0].isHidden }
        guard let first = visible.first, let last = visible.last else { return 0 }
        return rect(ofColumn: last).maxX + rect(ofColumn: first).minX
    }

    func updateScrollableWidth() {
        updateSizeOutOfView()
        let width = max(enclosingScrollView?.contentView.bounds.width ?? 0, columnsWidth)
        if abs(frame.width - width) > 0.5 { setFrameSize(NSSize(width: width, height: frame.height)) }
        if let headerView, abs(headerView.frame.width - width) > 0.5 {
            headerView.setFrameSize(NSSize(width: width, height: headerView.frame.height))
        }
        // AppKit coalesces layout and drawing at the end of the input turn.
        // Forcing either here repeats text layout inside native divider tracking.
        needsLayout = true
        headerView?.needsLayout = true
        enumerateAvailableRowViews { row, _ in
            row.needsLayout = true
        }
        if let scroll = enclosingScrollView { scroll.reflectScrolledClipView(scroll.contentView) }
    }

    /// Use existing visible views only: never enumerate a large data source,
    /// make offscreen cells, or read the filesystem from a header action.
    func visibleContentWidth(of index: Int) -> CGFloat {
        guard tableColumns.indices.contains(index) else { return 0 }
        let column = tableColumns[index]
        var width = (column.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width + 32
        let visible = rows(in: visibleRect)
        var sampled = 0
        enumerateAvailableRowViews { row, number in
            guard sampled < 256, NSLocationInRange(number, visible),
                  let cell = row.view(atColumn: index) as? any ColumnWidthProviding else { return }
            sampled += 1
            let indent = max(0, frameOfCell(atColumn: index, row: number).minX - rect(ofColumn: index).minX)
            width = max(width, cell.preferredColumnWidth + indent)
        }
        return min(column.maxWidth, max(column.minWidth, ceil(width)))
    }

    func addColumnWidthActions(to menu: NSMenu) {
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        menu.addItem(ClosureMenuItem(String(localized: "Fit Visible Contents")) { [weak self] in
            guard let self else { return }
            for (index, column) in tableColumns.enumerated() where !column.isHidden { column.width = visibleContentWidth(of: index) }
            (self as? any UserColumnTable)?.columnViewport?.rememberUserWidth()
            updateScrollableWidth()
            columnsChanged()
        })
        menu.addItem(ClosureMenuItem(String(localized: "Reset Column Widths")) { [weak self] in
            self?.resetColumnWidths()
        })
    }

    /// Every column back at the width the list gives it itself, and the
    /// flexible column free to follow the viewport again.
    func resetColumnWidths() {
        let standard = columnStore?.standardWidths ?? [:]
        for column in tableColumns {
            let id = column.identifier.rawValue
            if let width = standard[id] ?? FileColumn(rawValue: id)?.width.ideal { column.width = width }
        }
        (self as? any UserColumnTable)?.columnViewport?.forgetUserWidth()
        fitFlexibleColumn(FileColumn.name.rawValue)
        columnsChanged()
    }

    static func stopFitting(_ observers: inout [NSObjectProtocol]) {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }

    /// Viewport growth may fill the name column; manual drags never trigger
    /// a fit or take width away from another column.
    func keepFitting(_ id: String, defaults: UserDefaults = .standard) -> [NSObjectProtocol] {
        guard let clip = enclosingScrollView?.contentView else { return [] }
        let state = ColumnViewport(table: self, id: id, defaults: defaults)
        (self as? any UserColumnTable)?.columnViewport = state
        clip.postsFrameChangedNotifications = true
        DispatchQueue.main.async { state.resized() }
        return [
            NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: clip, queue: .main) { _ in
                MainActor.assumeIsolated { state.resized() }
            },
            NotificationCenter.default.addObserver(forName: NSTableView.columnDidResizeNotification, object: self, queue: .main) { _ in
                MainActor.assumeIsolated { state.columnResized() }
            },
        ]
    }
}

@MainActor final class ColumnViewport {
    weak var table: NSTableView?
    let id: String
    private var width: CGFloat = -1
    /// The width the user gave the column, by a divider or a menu; nil
    /// until they have. The width a list starts with is the list's own.
    private(set) var userWidth: CGFloat?
    private var expectedWidth: CGFloat
    private var fitting = false
    /// Setting the width itself: no column change of the user's.
    var isFitting: Bool { fitting }
    private let defaults: UserDefaults
    private let storageKey: String?

    /// How far the column gives way to the columns beside it in a narrow
    /// viewport while the user has chosen no width for it, or its own
    /// minimum when that is wider. Enough for a tick box, an icon and the
    /// start of a name.
    static let unchosenFloor: CGFloat = 160

    init(table: NSTableView, id: String, defaults: UserDefaults) {
        self.table = table
        self.id = id
        self.defaults = defaults
        storageKey = table.autosaveName.map { "table.flexibleWidth.v1." + $0 + "." + id }
        let column = table.tableColumn(withIdentifier: .init(id))
        let nativeWidth = column?.width ?? 200
        let saved = storageKey.flatMap { defaults.object(forKey: $0) as? Double }
            .flatMap { $0.isFinite && $0 >= (column?.minWidth ?? 0) && $0 <= (column?.maxWidth ?? 32_768) ? CGFloat($0) : nil }
        // A saved width equal to the one the list starts with is no choice:
        // an earlier build saved that for every list.
        let standard = table.columnStore?.standardWidths[id]
        userWidth = saved.flatMap { width in standard.map { abs($0 - width) <= 0.5 } == true ? nil : width }
        expectedWidth = nativeWidth
    }

    func resized() {
        guard let table, let current = table.enclosingScrollView?.contentView.bounds.width, abs(width - current) > 0.5 else { return }
        width = current
        fit()
    }

    func fit() {
        guard !fitting, let table, let clip = table.enclosingScrollView?.contentView, clip.bounds.width > 0,
              let column = table.tableColumn(withIdentifier: .init(id)), !column.isHidden else { return }
        // Some outline tracking paths deliver their resize notification after
        // the viewport changes. Capture that native drag before fitting again.
        if abs(column.width - expectedWidth) > 0.5 { rememberUserWidth() }
        fitting = true
        defer { fitting = false }
        // Only automatic filler retracts when the viewport shrinks. A native
        // divider drag establishes a new minimum, preserved by narrow panes;
        // without one the column gives way so the columns beside it stay in view.
        let available = clip.bounds.width - (table.columnsWidth - column.width)
        let floor = userWidth ?? max(column.minWidth, Self.unchosenFloor)
        let target = min(column.maxWidth, max(column.minWidth, max(floor, available)))
        expectedWidth = target
        // A fit follows the viewport and is not the user's choice, so it is
        // not saved (`ColumnStore`): this runs on every frame of a resize.
        if abs(column.width - target) > 0.5 { column.width = target }
        table.updateScrollableWidth()
    }

    func columnResized() {
        guard !fitting, let table, let column = table.tableColumn(withIdentifier: .init(id)) else { return }
        if abs(column.width - expectedWidth) > 0.5 {
            rememberUserWidth()
        }
        table.updateScrollableWidth()
    }

    func rememberUserWidth() {
        guard let column = table?.tableColumn(withIdentifier: .init(id)) else { return }
        userWidth = column.width
        expectedWidth = column.width
        if let storageKey { defaults.set(Double(column.width), forKey: storageKey) }
        table?.columnsChanged()
    }

    /// The column follows the viewport again, as before the user chose a width.
    func forgetUserWidth() {
        guard let column = table?.tableColumn(withIdentifier: .init(id)) else { return }
        userWidth = nil
        expectedWidth = column.width
        if let storageKey { defaults.removeObject(forKey: storageKey) }
    }
}
