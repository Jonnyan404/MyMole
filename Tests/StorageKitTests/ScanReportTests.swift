import Foundation
import Testing

@testable import StorageKit

@Suite struct ScanReportTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day = Date(timeIntervalSince1970: 1_790_000_000)

    /// /synthetic/home/Documents/{Work/{plan.pdf}, big.mov}, /synthetic/home/.ssh/{key}
    private func tree() -> Folder {
        let root = Folder(name: "home", parent: nil, rootPath: "/synthetic/home")
        let docs = Folder(name: "Documents", parent: root)
        let work = Folder(name: "Work", parent: docs)
        work.listedFiles = [FileItem(name: "plan.pdf", size: 2 << 20, modified: day, kind: .documents)]
        docs.listedFiles = [FileItem(name: "big, \"final\".mov", size: 9 << 20, modified: day, kind: .media)]
        docs.subfolders = [work]
        let ssh = Folder(name: ".ssh", parent: root)
        ssh.listedFiles = [FileItem(name: "key", size: 1 << 20, modified: day, kind: .other)]
        root.subfolders = [docs, ssh]
        root.finish()
        return root
    }

    @Test func foldersByLevelAndTheLargestFiles() {
        let r = ScanReport(root: tree(), options: .init(depth: 1, files: 1, paths: .fromScanned, hidden: false),
                           home: "/synthetic/home", now: now)
        #expect(r.scanned == "~")
        #expect(r.folders.map(\.path) == ["home/Documents"])
        #expect(r.files.map(\.path) == ["home/Documents/big, \"final\".mov"])
        // Work below the level, .ssh hidden; plan.pdf past the one file, the key hidden.
        #expect(r.foldersLeftOut == 2 && r.filesLeftOut == 2)
    }

    @Test func everythingWhenAskedWithFullPaths() {
        let r = ScanReport(root: tree(), options: .init(depth: nil, files: nil, paths: .full, hidden: true), home: "/synthetic/home", now: now)
        #expect(r.scanned == "/synthetic/home")
        #expect(r.folders.map(\.path) == ["/synthetic/home/Documents", "/synthetic/home/Documents/Work", "/synthetic/home/.ssh"])
        #expect(r.files.map(\.path) == ["/synthetic/home/Documents/big, \"final\".mov", "/synthetic/home/Documents/Work/plan.pdf",
                                        "/synthetic/home/.ssh/key"])
        #expect(r.foldersLeftOut == 0 && r.filesLeftOut == 0)
        #expect(r.folders[1].level == 2 && r.folders[0].files == 2)
    }

    @Test func noFilesAtAll() {
        let r = ScanReport(root: tree(), options: .init(depth: nil, files: 0, hidden: true), home: nil, now: now)
        #expect(r.files.isEmpty && r.filesLeftOut == 0)
        // Outside the home folder the scanned folder goes by its name alone.
        #expect(r.scanned == "home")
    }

    @Test func theCSVIsOneTableAnyLocaleReads() {
        let r = ScanReport(root: tree(), options: .init(depth: 1, files: 1, paths: .fromScanned, hidden: false),
                           home: "/synthetic/home", now: now)
        let lines = r.csv(kind: { "\($0)" }).components(separatedBy: "\r\n")
        #expect(lines[0] == "Type,Path,Bytes,Files,Modified,Kind")
        #expect(lines[1].hasPrefix("scan,~,\(r.size),3,2027-01-15T08:00:00Z"))
        // The synthetic tree has no byte totals of its own; the row carries what the map says.
        #expect(lines[2] == "folder,home/Documents,\(r.folders[0].size),2,,")
        #expect(lines[3] == "file,\"home/Documents/big, \"\"final\"\".mov\",\(9 << 20),,2026-09-21T14:13:20Z,media")
        #expect(lines.count == 5 && lines[4].isEmpty)
    }

    @Test func aCellThatLooksLikeAFormulaStaysText() {
        #expect(ScanReport.cell("=HYPERLINK(1)") == "'=HYPERLINK(1)")
        #expect(ScanReport.cell("+1") == "+1" && ScanReport.cell("-5") == "-5")
        #expect(ScanReport.cell("@sum") == "'@sum" && ScanReport.cell("-x") == "'-x")
        #expect(ScanReport.cell("a\nb") == "\"a\nb\"" && ScanReport.cell("plain") == "plain")
    }
}
