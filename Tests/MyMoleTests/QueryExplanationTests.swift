import Foundation
import StorageKit
import Testing

@testable import MyMole

@MainActor @Suite struct QueryExplanationTests {
    @Test func plainWordsNeedNoLine() {
        #expect(QueryExplanation.line(for: "", conditions: true) == nil)
        #expect(QueryExplanation.line(for: "annual report", conditions: false) == nil)
    }

    @Test func eachPartIsSpelledOut() throws {
        let line = try #require(QueryExplanation.line(for: #"report -draft size:>=1GB kind:folder ext:mov,mp4 -hidden:yes"#, conditions: true))
        #expect(!line.isProblem)
        let parts = line.text.components(separatedBy: " · ")
        #expect(parts.count == 6)
        #expect(parts[0].contains("report") && parts[1].contains("draft"))
        #expect(parts[2].contains(FileCellResources.byteCount.string(fromByteCount: 1_000_000_000)))
        #expect(parts[4].contains(".mov") && parts[4].contains(".mp4"))
        #expect(parts[5] == String(localized: "Except \(String(localized: "Hidden items only"))"))
    }

    @Test func aProblemSaysWhatsWrongAndThatNothingIsListed() throws {
        let unknown = try #require(QueryExplanation.line(for: "colour:red", conditions: true))
        #expect(unknown.isProblem && unknown.text.contains("colour:"))
        let bad = try #require(QueryExplanation.line(for: "size:big", conditions: true))
        #expect(bad.isProblem && bad.text.contains("size:>500MB"))
        #expect(bad.text.hasSuffix(String(localized: "Nothing is listed until the filter is fixed.")))
    }

    /// A list of texts only can't check a condition, so it says so and
    /// lists nothing rather than seeming to have filtered by it.
    @Test func aListOfTextsOnlyTurnsAConditionAway() throws {
        let line = try #require(QueryExplanation.line(for: "notes size:>1GB", conditions: false))
        #expect(line.isProblem)
        #expect(!TextQuery("notes size:>1GB").matches("notes.txt"))
        #expect(TextQuery("notes -old").matches("notes.txt") && !TextQuery("notes -old").matches("old notes.txt"))
        #expect(QueryExplanation.line(for: "notes -old", conditions: false)?.isProblem == false)
    }

    @Test(arguments: [(1.0, SearchQuery.AgeUnit.days), (6, .months), (2, .years), (1.5, .days), (3, .weeks), (12, .hours)])
    func spansAreWrittenOut(_ amount: Double, _ unit: SearchQuery.AgeUnit) {
        let s = QueryExplanation.span(amount, unit)
        #expect(!s.isEmpty && s.contains(where: \.isNumber))
    }

    /// The folder filter of Disk Map checks the conditions against each row.
    @Test func theFolderFilterChecksConditions() {
        // Any folder will do as the row's own; an empty one the system keeps is read in no time.
        let someFolder = StorageScanner.scan(path: "/var/empty", workers: 1).root
        func entry(_ name: String, size: Int64, folder: Bool = false) -> DiskEntry {
            DiskEntry(path: "/synthetic/" + name, name: name, size: size, modified: .now, kind: .media, kindTitle: "",
                      items: 0, folder: folder ? someFolder : nil, pending: false)
        }
        let rows = [entry("clip.mov", size: 2_000_000_000), entry("small.mov", size: 10), entry(".hidden.mov", size: 3_000_000_000),
                    entry("Movies", size: 5_000_000_000, folder: true)]
        let names = { (q: String) in rows.filter(BrowseFilter(query: q).matcher()).map(\.name) }
        #expect(names("mov size:>1gb -hidden:yes") == ["clip.mov", "Movies"])
        #expect(names("mov size:>1gb -hidden:yes kind:file") == ["clip.mov"])
        #expect(names("kind:folder") == ["Movies"])
        #expect(names("ext:mov hidden:yes") == [".hidden.mov"])
        #expect(names("mov ext:") == [])
    }
}
