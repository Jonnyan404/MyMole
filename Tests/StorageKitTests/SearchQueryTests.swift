import Foundation
import Testing

@testable import StorageKit

@Suite struct SearchQueryTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func query(_ text: String) -> SearchQuery { SearchQuery(text, now: now, calendar: calendar) }

    private func facts(
        _ name: String = "clip.mov", size: Int64 = 1_000_000, modified: Date? = nil, kind: FileKind? = .media,
        folder: Bool = false, hidden: Bool = false
    ) -> SearchQuery.Facts {
        SearchQuery.Facts(name: name, size: size, modified: modified ?? now, kind: kind, isFolder: folder, hidden: hidden)
    }

    @Test func wordsExclusionsAndQuotesAreSetApart() {
        let q = query(#"report -draft "two words" -"size:big" 10:30 a/b:c - "kind:x""#)
        #expect(q.words == ["report", "two words", "10:30", "a/b:c", "-", "kind:x"])
        #expect(q.excluded == ["draft", "size:big"])
        #expect(q.terms.isEmpty && q.problems.isEmpty)
        #expect(query(#""unclosed quote"#).words == ["unclosed quote"])
        #expect(query("  ").isEmpty && !query("-x").isEmpty)
    }

    @Test func anExcludedWordLeavesOutARowThatHoldsIt() {
        let q = query("report -draft")
        #expect(q.matches(texts: ["Report.pdf", "/synthetic/Documents"], facts: facts()))
        #expect(!q.matches(texts: ["Report draft.pdf", "/synthetic"], facts: facts()))
        // In any of the texts, the folder as well as the name.
        #expect(!q.matches(texts: ["Report.pdf", "/synthetic/Drafts"], facts: facts()))
        #expect(query("-cache").matches(texts: ["notes"], facts: facts()))
        #expect(query(#""two words""#).matches(texts: ["Two Words.txt"], facts: facts()))
        #expect(!query(#""two words""#).matches(texts: ["Two-Words.txt"], facts: facts()))
    }

    @Test(arguments: [
        ("size:>500MB", 500_000_001 as Int64, true), ("size:>500MB", 500_000_000, false),
        ("size:>=500mb", 500_000_000, true), ("size:<1g", 999_999_999, true), ("size:<1g", 1_000_000_000, false),
        ("size:<=1g", 1_000_000_000, true), ("size:1GB", 1_000_000_000, true), ("size:1GB", 999_999_999, false),
        ("size:100mb-2gb", 2_000_000_000, true), ("size:100mb-2gb", 2_000_000_001, false), ("size:100mb-2gb", 99_999_999, false),
        ("size:1.5GB", 1_500_000_000, true), ("size:1,5gb", 1_499_999_999, false), ("size:=10", 10, true),
        ("-size:>1gb", 2_000_000_000, false), ("-size:>1gb", 10, true),
    ])
    func sizesCountInThousands(_ text: String, _ size: Int64, _ passes: Bool) {
        let q = query(text)
        #expect(q.problems.isEmpty)
        #expect(q.passes(facts(size: size)) == passes)
    }

    @Test(arguments: ["size:", "size:big", "size:5XB", "size:2gb-1gb", "size:>-5", "kind:", "kind:spaceship", "ext:", "ext:,",
                      "age:", "age:5", "age:>xd", "age:0d", "age:3q", "hidden:", "hidden:maybe"])
    func aValueThatCantBeReadIsAProblem(_ text: String) {
        let q = query(text)
        #expect(q.problems.count == 1)
        if case .badValue(let name, _) = q.problems.first { #expect(text.hasPrefix(name + ":")) } else { Issue.record("not a bad value") }
        // Nothing passes while the filter has a problem.
        #expect(!q.passes(facts()) && !q.matches(texts: ["anything"], facts: facts()))
    }

    @Test func anUnknownConditionIsAProblemAndQuotesMakeItAWord() {
        #expect(query("colour:red").problems == [.unknown("colour")])
        #expect(query("Colour:Red").problems == [.unknown("colour")])
        #expect(query(#""colour:red""#).problems.isEmpty)
        #expect(query("https://example").problems.isEmpty)
        #expect(query("é:x").problems.isEmpty)
    }

    @Test func kindsReadByNameAndAlias() {
        #expect(query("kind:video").terms.map(\.condition) == [.kind(.media)])
        #expect(query("kind:Archives").terms.map(\.condition) == [.kind(.archives)])
        #expect(query("kind:folder").passes(facts(folder: true)) && !query("kind:folder").passes(facts()))
        #expect(query("kind:file").passes(facts()) && !query("kind:files").passes(facts(folder: true)))
        #expect(!query("kind:docs").passes(facts(kind: nil)))
        #expect(query("-kind:caches").passes(facts(kind: .documents)))
        // A kind's title, in quotes for its spaces.
        for kind in FileKind.allCases { #expect(query("kind:\"\(kind.title)\"").terms.map(\.condition) == [.kind(kind)]) }
        #expect(query(#"size:"1 gb""#).terms.map(\.condition) == [.size(min: 1_000_000_000, max: nil)])
    }

    @Test func extensionsAreMatchedWithoutCaseOrDot() {
        let q = query("ext:MOV,.mp4")
        #expect(q.terms.map(\.condition) == [.ext(["mov", "mp4"])])
        #expect(q.passes(facts("Clip.MOV")) && q.passes(facts("a.b.mp4")) && !q.passes(facts("clip.mkv")))
        #expect(!q.passes(facts(".mov")) && !q.passes(facts("mov")) && !q.passes(facts("clip.")))
        #expect(SearchQuery.extensionOf("Archive.TAR.GZ") == "gz" && SearchQuery.extensionOf(".zshrc") == nil)
    }

    @Test func agesCountBackFromNow() {
        let day: TimeInterval = 86_400
        let older = query("age:>30d"), plain = query("age:30d"), newer = query("age:<7d")
        #expect(older.passes(facts(modified: now - 31 * day)) && !older.passes(facts(modified: now - 29 * day)))
        #expect(plain.passes(facts(modified: now - 31 * day)))
        #expect(newer.passes(facts(modified: now - 6 * day)) && !newer.passes(facts(modified: now - 8 * day)))
        let months = query("age:>6m")
        #expect(months.passes(facts(modified: calendar.date(byAdding: .month, value: -7, to: now)!)))
        #expect(!months.passes(facts(modified: calendar.date(byAdding: .month, value: -5, to: now)!)))
        #expect(query("age:>1.5d").passes(facts(modified: now - 1.6 * day)) && !query("age:>1.5d").passes(facts(modified: now - 1.4 * day)))
        // A date that isn't known is neither old nor new.
        #expect(!older.passes(facts(modified: .distantPast)) && !newer.passes(facts(modified: .distantPast)))
        if case .age(true, 6, .months, _) = months.terms.first?.condition {} else { Issue.record("not read as six months") }
    }

    @Test func hiddenItemsByTheirOwnNameOrAFolders() {
        #expect(query("hidden:yes").passes(facts(hidden: true)) && !query("hidden:yes").passes(facts()))
        #expect(query("hidden:no").passes(facts()) && !query("hidden:no").passes(facts(hidden: true)))
        #expect(SearchQuery.isHidden(name: ".env", folder: "/synthetic"))
        #expect(SearchQuery.isHidden(name: "config", folder: "/synthetic/.cache/tool"))
        #expect(!SearchQuery.isHidden(name: "a.txt", folder: "/synthetic/Documents"))
    }

    @Test func everyConditionMustHold() {
        let q = query("clip size:>500kb kind:media ext:mov -hidden:yes")
        #expect(q.terms.count == 4 && q.problems.isEmpty)
        #expect(q.matches(texts: ["clip.mov"], facts: facts()))
        #expect(!q.matches(texts: ["clip.mov"], facts: facts(hidden: true)))
        #expect(!q.matches(texts: ["clip.mov"], facts: facts(size: 10)))
        #expect(!q.matches(texts: ["other.mov"], facts: facts("other.mov")))
    }

    /// The scan's search takes the excluded words and tells `keep` which
    /// entries are hidden, by their own name or a folder above them.
    @Test func theWholeScanSearchLeavesOutExcludedWordsAndKnowsHidden() {
        let root = Folder(name: "root", parent: nil, rootPath: "/synthetic")
        let cache = Folder(name: ".cache", parent: root)
        let tool = Folder(name: "tool", parent: cache)
        tool.listedFiles = [FileItem(name: "blob.bin", size: 3 << 20, modified: .distantPast, kind: .caches)]
        let docs = Folder(name: "Documents", parent: root)
        docs.listedFiles = [
            FileItem(name: "plan.bin", size: 2 << 20, modified: .distantPast, kind: .documents),
            FileItem(name: "draft plan.bin", size: 1 << 20, modified: .distantPast, kind: .documents),
        ]
        cache.subfolders = [tool]
        root.subfolders = [cache, docs]
        root.finish()
        let index = ScanIndex(root)
        let paths = { (q: String) -> [String] in
            let search = SearchQuery(q, home: nil)
            return index.search(search.text, limit: .max) { e, hidden in
                search.passes(SearchQuery.Facts(name: e.name, size: e.size, modified: e.modified, kind: e.kind, isFolder: e.isFolder, hidden: hidden))
            }.found.map(index.path)
        }
        #expect(paths("plan -draft") == ["/synthetic/Documents/plan.bin"])
        #expect(paths("bin hidden:yes") == ["/synthetic/.cache/tool/blob.bin"])
        #expect(paths("bin -hidden:yes") == ["/synthetic/Documents/plan.bin", "/synthetic/Documents/draft plan.bin"])
        #expect(paths("-documents kind:file") == ["/synthetic/.cache/tool/blob.bin"])
        // A word with a slash puts paths together; an excluded one still leaves rows out.
        #expect(paths("documents/ -draft") == ["/synthetic/Documents/plan.bin"])
        #expect(paths("colour:red").isEmpty)
    }
}
