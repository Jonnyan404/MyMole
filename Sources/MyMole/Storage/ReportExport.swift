import AppKit
import StorageKit
import SwiftUI
import UniformTypeIdentifiers

/// A report of the map as a CSV or PDF, saved where the user chooses. What
/// it holds is chosen here: how deep, how many files, whole paths or paths
/// from the scanned folder, and hidden items or not.
enum ReportFormat: String, CaseIterable, Identifiable {
    case csv, pdf
    var id: String { rawValue }
    var type: UTType { self == .csv ? .commaSeparatedText : .pdf }

    /// A PDF is read page by page, so it goes three levels and a thousand files deep at most.
    var depths: [Int?] { self == .csv ? [1, 2, 3, nil] : [1, 2, 3] }
    var fileCounts: [Int?] { self == .csv ? [0, 100, 1_000, nil] : [0, 100, 1_000] }
}

struct ReportExportSheet: View {
    let model: StorageModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("report.format") private var format = ReportFormat.csv
    @AppStorage("report.depth") private var depth = 2
    @AppStorage("report.files") private var files = 100
    @AppStorage("report.fullPaths") private var fullPaths = false
    @AppStorage("report.hidden") private var hidden = false
    @State private var counts: (folders: Int, files: Int, leftOut: Int)?

    /// -1 stands for every level or every file in the stored choices.
    private var options: ScanReport.Options {
        let d: Int? = depth < 0 ? nil : depth, f: Int? = files < 0 ? nil : files
        return ScanReport.Options(
            depth: format.depths.contains(d) ? d : 3, files: format.fileCounts.contains(f) ? f : 1_000,
            paths: fullPaths ? .full : .fromScanned, hidden: hidden)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Text("Export Report").font(.title2.bold())
            DSText("A list of the folders and largest files in this map, with their sizes. It's saved only where you choose, and can't be opened as a scan.", .metadata)
            DSFormGrid {
                DSFormRow("Format") {
                    Picker("Format", selection: $format) {
                        Text(verbatim: "CSV").tag(ReportFormat.csv)
                        Text(verbatim: "PDF").tag(ReportFormat.pdf)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                DSFormRow("Folders") {
                    Picker("Folders", selection: Binding(get: { options.depth ?? -1 }, set: { depth = $0 })) {
                        ForEach(format.depths, id: \.self) { d in
                            switch d {
                            case 1?: Text("1 level deep").tag(1)
                            case let d?: Text("\(d) levels deep").tag(d)
                            case nil: Text("Every level").tag(-1)
                            }
                        }
                    }
                    .labelsHidden().fixedSize()
                }
                DSFormRow("Files", help: "Files under 1 MB are counted in their folder, not listed.") {
                    Picker("Files", selection: Binding(get: { options.files ?? -1 }, set: { files = $0 })) {
                        ForEach(format.fileCounts, id: \.self) { f in
                            switch f {
                            case 0?: Text("None").tag(0)
                            case let n?: Text("The largest \(n)").tag(n)
                            case nil: Text("Every listed file").tag(-1)
                            }
                        }
                    }
                    .labelsHidden().fixedSize()
                }
                DSFormRow("Paths") {
                    Picker("Paths", selection: $fullPaths) {
                        Text("From the scanned folder").tag(false)
                        Text("Full paths").tag(true)
                    }
                    .labelsHidden().fixedSize()
                }
                DSFormRow(nil, checkbox: true, help: "Names that start with a dot, and everything in such folders, such as .ssh.") {
                    Toggle("Include hidden items", isOn: $hidden)
                }
            }
            if format == .pdf {
                DSText("A PDF goes three levels and a thousand files deep at most. Choose CSV for every level and file.", .metadata)
            }
            DSActionGroup {
                if let counts {
                    DSText(summary(counts), .metadata)
                }
            } trailing: {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") {
                    let chosen = options, format = format
                    dismiss()
                    model.exportReport(chosen, format: format)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.root == nil || model.scanning)
            }
        }
        .padding(DS.Space.xl)
        .frame(width: DS.Size.reviewWidth)
        .dialogControls()
        .dialogKeyboard()
        .task(id: options) { await count() }
    }

    private func summary(_ c: (folders: Int, files: Int, leftOut: Int)) -> String {
        let listed = String(localized: "\(ReportPDF.folders(c.folders)) and \(ReportPDF.files(c.files))")
        return c.leftOut == 0 ? listed : String(localized: "\(listed); \(c.leftOut) left out by these choices")
    }

    private func count() async {
        guard let root = model.root else { counts = nil; return }
        let options = options
        let report = await Task.detached(priority: .userInitiated) { ScanReport(root: root, options: options) }.value
        guard !Task.isCancelled else { return }
        counts = (report.folders.count, report.files.count, report.foldersLeftOut + report.filesLeftOut)
    }
}

extension StorageModel {
    /// Builds the report off the main thread, asks where to save it and writes it there.
    func exportReport(_ options: ScanReport.Options, format: ReportFormat) {
        guard let root, !scanning else { return }
        let incomplete = incomplete
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.type]
        panel.nameFieldStringValue = String(localized: "\(root.name) report \(Date.now.formatted(date: .numeric, time: .omitted))")
            .replacingOccurrences(of: "/", with: "-") + "." + format.rawValue
        panel.message = String(localized: "Save the report of this map")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let report = await Task.detached(priority: .userInitiated) { ScanReport(root: root, options: options, incomplete: incomplete) }.value
            let data: Data = switch format {
            case .csv: Data(report.csv().utf8)
            case .pdf: ReportPDF.data(report)
            }
            let failed = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    try data.write(to: url, options: .atomic)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            showReportNotice(failed.map { String(localized: "The report couldn't be saved: \($0)") }
                ?? String(localized: "Saved the report to \(url.lastPathComponent)"))
        }
    }
}

/// The report as pages of A4: what was scanned and how the report was
/// chosen, then the folders and the files, a row each.
@MainActor enum ReportPDF {
    static let page = CGSize(width: 595, height: 842)
    static let margin: CGFloat = 40
    /// Printed on white whatever the Mac's appearance.
    static let ink = NSColor.black, quiet = NSColor(white: 0.38, alpha: 1)

    static func folders(_ n: Int) -> String { n == 1 ? String(localized: "1 folder") : String(localized: "\(n) folders") }
    static func files(_ n: Int) -> String { n == 1 ? String(localized: "1 file") : String(localized: "\(n) files") }

    enum Line {
        case title(String), text(String), heading(String), columns, row(ScanReport.Row), gap

        var height: CGFloat {
            switch self {
            case .title: 26
            case .text: 14
            case .heading: 24
            case .columns: 16
            case .row: 13
            case .gap: 8
            }
        }
    }

    static func lines(_ r: ScanReport) -> [Line] {
        let bytes = { (n: Int64) in ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
        var out: [Line] = [.title(String(localized: "Disk Map Report"))]
        out.append(.text(String(localized: "Scanned: \(r.scanned)")))
        out.append(.text(String(localized: "Made \(r.made.formatted(date: .long, time: .shortened))")))
        out.append(.text(String(localized: "\(bytes(r.size)) in \(files(r.fileCount))")))
        if r.incomplete {
            out.append(.text(String(localized: "This map is partial: some folders couldn't be read, or the scan was stopped.")))
        }
        if r.foldersLeftOut + r.filesLeftOut > 0 {
            out.append(.text(String(localized: "Left out by the choices made when exporting: \(folders(r.foldersLeftOut)) and \(files(r.filesLeftOut)).")))
        }
        if !r.options.hidden { out.append(.text(String(localized: "Hidden items are left out."))) }
        out.append(.gap)
        if !r.folders.isEmpty {
            out += [.heading(String(localized: "Folders")), .columns] + r.folders.map(Line.row) + [.gap]
        }
        if !r.files.isEmpty {
            out += [.heading(String(localized: "Largest Files")), .columns] + r.files.map(Line.row)
        }
        return out
    }

    /// Lines in pages: a heading never ends a page, and a page that starts
    /// a new one inside a table repeats the column titles.
    static func pages(_ lines: [Line]) -> [[Line]] {
        let room = page.height - 2 * margin - 20
        var pages: [[Line]] = [[]], used: CGFloat = 0
        for (i, line) in lines.enumerated() {
            var need = line.height
            // A heading keeps its column titles and first row with it.
            if case .heading = line { need += Line.columns.height + 13 }
            if used + need > room, !pages[pages.count - 1].isEmpty {
                pages.append([])
                used = 0
                if case .row = line, i > 0 {
                    pages[pages.count - 1].append(.columns)
                    used += Line.columns.height
                }
            }
            pages[pages.count - 1].append(line)
            used += line.height
        }
        return pages
    }

    static func data(_ report: ScanReport) -> Data {
        let out = NSMutableData()
        var box = CGRect(origin: .zero, size: page)
        guard let consumer = CGDataConsumer(data: out as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextCreator: "MyMole"] as CFDictionary)
        else { return Data() }
        let pages = pages(lines(report))
        for (n, lines) in pages.enumerated() {
            ctx.beginPDFPage(nil)
            ctx.translateBy(x: 0, y: page.height)
            ctx.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            var y = margin
            for line in lines {
                draw(line, at: y)
                y += line.height
            }
            text(String(localized: "Page \(n + 1) of \(pages.count)"), .systemFont(ofSize: 8), quiet,
                 in: CGRect(x: margin, y: page.height - margin, width: page.width - 2 * margin, height: 12), align: .center)
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return out as Data
    }

    private static let columns: (path: CGFloat, size: CGFloat, files: CGFloat, modified: CGFloat) = (40, 340, 420, 480)

    private static func draw(_ line: Line, at y: CGFloat) {
        let width = page.width - 2 * margin
        switch line {
        case .title(let s): text(s, .boldSystemFont(ofSize: 18), ink, in: CGRect(x: margin, y: y, width: width, height: 24))
        case .text(let s): text(s, .systemFont(ofSize: 9.5), ink, in: CGRect(x: margin, y: y, width: width, height: 13))
        case .heading(let s): text(s, .boldSystemFont(ofSize: 12), ink, in: CGRect(x: margin, y: y + 6, width: width, height: 16))
        case .gap: break
        case .columns:
            let f = NSFont.boldSystemFont(ofSize: 8)
            text(String(localized: "Path"), f, quiet, in: CGRect(x: columns.path, y: y + 2, width: 280, height: 11))
            text(String(localized: "Size"), f, quiet, in: CGRect(x: columns.size, y: y + 2, width: 70, height: 11), align: .right)
            text(String(localized: "Files"), f, quiet, in: CGRect(x: columns.files, y: y + 2, width: 50, height: 11), align: .right)
            text(String(localized: "Modified"), f, quiet, in: CGRect(x: columns.modified, y: y + 2, width: 75, height: 11))
        case .row(let r):
            let f = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular)
            let indent = r.isFolder ? min(CGFloat(r.level - 1) * 8, 32) : 0
            text(r.path, f, ink, in: CGRect(x: columns.path + indent, y: y, width: 290 - indent, height: 11), truncate: true)
            text(ByteCountFormatter.string(fromByteCount: r.size, countStyle: .file), f, ink,
                 in: CGRect(x: columns.size, y: y, width: 70, height: 11), align: .right)
            if let files = r.files {
                text(files.formatted(), f, quiet, in: CGRect(x: columns.files, y: y, width: 50, height: 11), align: .right)
            }
            if let modified = r.modified {
                text(modified.formatted(date: .numeric, time: .omitted), f, quiet,
                     in: CGRect(x: columns.modified, y: y, width: 75, height: 11))
            }
        }
    }

    private static func text(_ s: String, _ font: NSFont, _ color: NSColor, in rect: CGRect,
                             align: NSTextAlignment = .left, truncate: Bool = false) {
        let style = NSMutableParagraphStyle()
        style.alignment = align
        style.lineBreakMode = truncate ? .byTruncatingMiddle : .byTruncatingTail
        NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
            .draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}
