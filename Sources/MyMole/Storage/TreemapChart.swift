import StorageKit
import SwiftUI

/// Two levels of nested rectangles: the current folder's contents, and
/// inside each big one, its own contents. Click a block to step into it.
struct TreemapChart: View {
    @Bindable var model: StorageModel
    @State private var drawing: Drawing?

    private struct Drawing {
        let key: SunburstChart.LayoutKey
        let size: CGSize
        let cells: [Cell]
    }

    struct Cell {
        let rect: CGRect
        let segment: Segment
        let level: Int
        let branch: Int
        /// How many smaller items this block gathers, when it stands for
        /// the ones too small to draw one by one; 0 for one item.
        var rest = 0
    }

    /// Blocks drawn for the current folder at most, and the smallest of them
    /// in points²; the rest share one block. Inside a block, its own contents
    /// smaller than that are left out. A folder of tens of thousands would
    /// otherwise be tens of thousands of blocks of a few points each.
    static let blockLimit = 3_000, blockMinimum: CGFloat = 4
    static let innerLimit = 400, innerMinimum: CGFloat = 36

    /// The largest parts worth a block of their own in `area`, at most
    /// `limit`, and the bytes and count of the rest. Parts are largest first.
    static func split(_ parts: [Segment], area: CGFloat, minimum: CGFloat, limit: Int) -> (shown: [Segment], rest: Int64, count: Int) {
        let total = Double(parts.reduce(0) { $0 + $1.size })
        guard total > 0, area > 0 else { return ([], 0, 0) }
        var n = 0
        for p in parts {
            guard n < limit, Double(p.size) / total * Double(area) >= Double(minimum) else { break }
            n += 1
        }
        return (Array(parts.prefix(n)), parts.dropFirst(n).reduce(0) { $0 + $1.size }, parts.count - n)
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let key = SunburstChart.LayoutKey(model)
            let shown = drawing
            let scaleX = shown.map { size.width / $0.size.width } ?? 1
            let scaleY = shown.map { size.height / $0.size.height } ?? 1
            ZStack(alignment: .topLeading) {
                if let shown {
                    surface(shown.cells)
                        .frame(width: shown.size.width, height: shown.size.height)
                        .scaleEffect(x: scaleX, y: scaleY, anchor: .topLeading)
                        .dsCrossfade(value: shown.key)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    let seg = hit(p, in: size, key: key)
                    if model.hovered != seg { model.hovered = seg }
                case .ended:
                    if model.hovered != nil { model.hovered = nil }
                }
            }
            .onTapGesture { p in
                if case .folder(let f) = hit(p, in: size, key: key) { model.open(f) }
            }
            .task(id: Key(layout: key, size: size)) {
                guard size.width > 0, size.height > 0 else { return }
                // Stretch the installed drawing during a resize. Reflow its
                // blocks when the size settles, keeping their targets in place
                // and leaving the frame free for the list beside the map.
                let resizing = drawing?.key == key
                if resizing {
                    guard drawing?.size != size else { return }
                    do { try await Task.sleep(for: .milliseconds(100)) }
                    catch { return }
                }
                guard !Task.isCancelled, key == SunburstChart.LayoutKey(model) else { return }
                let cells = layout(in: CGRect(origin: .zero, size: size))
                withAnimation(resizing || model.showingLive ? nil : Motion.content) {
                    drawing = Drawing(key: key, size: size, cells: cells)
                }
                ChartLayouts.didInstall()
            }
        }
        .padding(16)
    }

    private func hit(_ point: CGPoint, in size: CGSize, key: SunburstChart.LayoutKey) -> Segment? {
        guard let drawing, drawing.key == key, size.width > 0, size.height > 0 else { return nil }
        let local = CGPoint(x: point.x * drawing.size.width / size.width, y: point.y * drawing.size.height / size.height)
        return drawing.cells.last { $0.rest == 0 && $0.rect.contains(local) }?.segment
    }

    private func surface(_ cells: [Cell]) -> some View {
        Canvas { ctx, _ in
            var outlines = Path()
            for c in cells {
                let fill = fill(for: c)
                let shape = Path(roundedRect: c.rect.insetBy(dx: 1, dy: 1), cornerRadius: c.level == 1 ? 6 : 3)
                // A soft top-light gradient gives each block some depth
                // without the noise of a full cushion render.
                ctx.fill(
                    shape,
                    with: .linearGradient(
                        Gradient(colors: [fill.mix(with: .white, by: 0.12), fill.mix(with: .black, by: 0.12)]),
                        startPoint: c.rect.origin, endPoint: CGPoint(x: c.rect.maxX, y: c.rect.maxY)))
                if c.level == 1 { outlines.addPath(shape) }
            }
            // Top-level blocks never overlap: their outlines in one stroke.
            ctx.stroke(outlines, with: .color(.black.opacity(0.25)), lineWidth: 1)

            // Labels follow the fills so a nested name stays inside its
            // own block. Tiny blocks borrow their parent's label strip.
            let hovered = cells.last { $0.level > 1 && $0.rest == 0 && $0.segment == model.hovered }
            let labeled = hovered.map { c in
                ChartLabel.draw(
                    name(of: c.segment),
                    detail: ByteCountFormatter.string(fromByteCount: c.segment.size, countStyle: .file),
                    in: c.rect.insetBy(dx: 7, dy: 4), on: fill(for: c), ctx: ctx)
            } ?? false
            for c in cells where c.level == 1 && c.rect.height > 34 {
                let rect = CGRect(x: c.rect.minX + 7, y: c.rect.minY + 4, width: c.rect.width - 14, height: 28)
                if c.rest > 0 {
                    ChartLabel.draw(String(localized: "\(c.rest) smaller items"), in: rect, on: fill(for: c), ctx: ctx)
                    continue
                }
                if !labeled, let hovered, hovered.branch == c.branch,
                   ChartLabel.draw(name(of: hovered.segment),
                                   detail: ByteCountFormatter.string(fromByteCount: hovered.segment.size, countStyle: .file),
                                   in: rect, on: fill(for: c), ctx: ctx) {
                    continue
                }
                ChartLabel.draw(
                    name(of: c.segment),
                    detail: ByteCountFormatter.string(fromByteCount: c.segment.size, countStyle: .file),
                    in: rect, on: fill(for: c), ctx: ctx)
            }
        }
    }

    private func fill(for cell: Cell) -> Color {
        if cell.rest > 0 { return Color.gray.opacity(0.35) }
        let color = ChartColors.color(for: cell.segment, branch: cell.branch, depth: cell.level, byKind: model.colorByKind)
        return model.isHighlighted(cell.segment) ? color.mix(with: .white, by: 0.3) : color
    }

    private func name(of segment: Segment) -> String {
        if case .files(let folder) = segment, folder.smallFileCount == 0, folder.listedFiles.count == 1 {
            return folder.listedFiles[0].name
        }
        return segment.name
    }

    private struct Key: Hashable {
        let layout: SunburstChart.LayoutKey
        let size: CGSize
    }

    private func layout(in bounds: CGRect) -> [Cell] {
        guard let cur = model.current else { return [] }
        let ready = model.isReady
        let all = chartParts(of: cur, include: ready)
        let top = Self.split(all, area: bounds.width * bounds.height, minimum: Self.blockMinimum, limit: Self.blockLimit)
        let parts = top.shown
        let rects = Squarify.layout(parts.map { Double($0.size) } + (top.rest > 0 ? [Double(top.rest)] : []), in: bounds)
        var out: [Cell] = []
        if top.rest > 0, let last = rects.last, last.width >= 1, last.height >= 1 {
            out.append(Cell(rect: last, segment: .folder(cur), level: 1, branch: parts.count, rest: top.count))
        }
        for (i, (part, rect)) in zip(parts, rects).enumerated() where rect.width >= 1 && rect.height >= 1 {
            out.append(Cell(rect: rect, segment: part, level: 1, branch: i))
            // Second level inside blocks with room, below the label strip.
            guard case .folder(let f) = part, rect.width > 60, rect.height > 60 else { continue }
            let inner = CGRect(x: rect.minX + 4, y: rect.minY + 34, width: rect.width - 8, height: rect.height - 38)
            guard inner.width > 10, inner.height > 10 else { continue }
            let inside = Self.split(chartParts(of: f, include: ready), area: inner.width * inner.height,
                                    minimum: Self.innerMinimum, limit: Self.innerLimit)
            let kids = inside.shown
            // What's left out keeps its share of the space, undrawn.
            let values = kids.map { Double($0.size) } + (inside.rest > 0 ? [Double(inside.rest)] : [])
            for (k, r) in zip(kids, Squarify.layout(values, in: inner)) where r.width >= 2 && r.height >= 2 {
                out.append(Cell(rect: r, segment: k, level: 2, branch: i))
            }
        }
        return out
    }
}
