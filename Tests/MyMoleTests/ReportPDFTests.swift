import Foundation
import PDFKit
import Testing

@testable import MyMole
@testable import StorageKit

@MainActor @Suite struct ReportPDFTests {
    private func report(folders: Int, files: Int) -> ScanReport {
        let root = Folder(name: "home", parent: nil, rootPath: "/synthetic/home")
        root.subfolders = (0..<folders).map { Folder(name: "Folder \($0)", parent: root) }
        root.listedFiles = (0..<files).map { FileItem(name: "file \($0).bin", size: Int64(files - $0) << 20, modified: .distantPast, kind: .other) }
        root.finish()
        return ScanReport(root: root, options: .init(depth: 1, files: nil, paths: .fromScanned, hidden: true), home: "/synthetic/home")
    }

    @Test func aTableGoingOnToANewPageRepeatsItsColumnTitles() {
        let pages = ReportPDF.pages(ReportPDF.lines(report(folders: 150, files: 120)))
        #expect(pages.count > 2)
        for page in pages.dropFirst() {
            guard case .columns = page.first else { Issue.record("a page doesn't start with the column titles"); continue }
        }
        for page in pages {
            if case .heading = page.last { Issue.record("a page ends with a heading") }
        }
        let rows = pages.joined().filter { if case .row = $0 { true } else { false } }.count
        #expect(rows == 270)
    }

    @Test func thePDFOpensWithEveryPage() throws {
        let r = report(folders: 3, files: 2)
        let data = ReportPDF.data(r)
        let doc = try #require(PDFDocument(data: data))
        #expect(doc.pageCount == ReportPDF.pages(ReportPDF.lines(r)).count)
        let text = doc.string ?? ""
        #expect(text.contains(String(localized: "Disk Map Report")) && text.contains("home/Folder 0") && text.contains("home/file 0.bin"))
    }

    @Test func oneAndMany() {
        #expect(ReportPDF.files(1) == String(localized: "1 file") && ReportPDF.folders(2) == String(localized: "\(2) folders"))
    }
}
