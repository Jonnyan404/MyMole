import Foundation
import Testing

@testable import StorageKit

@Suite struct WordSearchTests {
    /// What the byte search replaced: lower-cased text, word by word.
    private func plainly(_ query: String, _ text: String) -> Bool {
        let lowered = text.lowercased()
        return query.lowercased().split(separator: " ").allSatisfy { lowered.contains($0) }
    }

    @Test(arguments: [
        ("", "anything"), ("report", "Annual Report.pdf"), ("REPORT annual", "Annual Report.pdf"), ("report 2024", "Annual Report.pdf"),
        ("  spaced   out ", "Spaced Out"), ("ö", "Sjöfågel"), ("SJÖ", "sjöfågel"), ("日本", "日本語のメモ"), ("x", ""), ("longer than the text", "short"),
        (".app", "Canvas.app"), ("a/b", "a/b/c"), ("é", "Café"),
    ]) func matchesAsLowerCasedTextDoes(_ query: String, _ text: String) {
        #expect(WordSearch(query).matches(text) == plainly(query, text))
    }

    @Test func aLetterStoredAsTwoIsFoundByTheLetterTypedAsOne() {
        let composed = "Caf\u{E9}", decomposed = "Cafe\u{301}"
        #expect(WordSearch(composed).matches(decomposed) && WordSearch(decomposed).matches(composed))
        #expect(WordSearch("ÅNGSTRÖM").matches("A\u{30A}ngstro\u{308}m.txt"))
    }

    /// A filter pasted with a tab, a line break or a non-breaking space
    /// between its words asks for the same words as one typed with spaces.
    @Test(arguments: ["annual\treport", "annual\nreport", "annual\u{A0}report", " \tannual \r\n report\n"])
    func anyWhiteSpaceSetsWordsApart(_ query: String) {
        let search = WordSearch(query)
        #expect(search.words.count == 2 && search.matches("Annual Report.pdf") && !search.matches("Annual Summary.pdf"))
        #expect(WordSearch(" \t\n").isEmpty)
    }

    /// A path in the home folder is searched as the lists show it, from
    /// "~" on: the account's name and "users" are in every such path, and
    /// would find every row.
    @Test func theHomeFoldersOwnPathFindsNothingByItself() {
        let home = "/Users/synthetic"
        let rows = [("report.pdf", home + "/Documents"), ("synthetic-notes.txt", home + "/Desktop"), ("users.csv", "/Volumes/Disk/Exports")]
        func found(_ query: String) -> [String] {
            let search = WordSearch(query, home: home)
            return rows.filter { search.matches(anyOf: [$0.0, $0.1]) }.map(\.0)
        }
        #expect(found("users") == ["users.csv"])
        #expect(found("synthetic") == ["synthetic-notes.txt"])
        #expect(found("documents") == ["report.pdf"] && found("DESKTOP notes") == ["synthetic-notes.txt"])
        // Without a home folder every word is looked for in the whole path.
        #expect(WordSearch("users").matches(home + "/Documents"))
        // A piece of a path is looked for in the whole of it, and "~" is the home folder.
        #expect(found("/users/synthetic/doc") == ["report.pdf"])
        #expect(found("~/Desktop") == ["synthetic-notes.txt"])
        #expect(found("~") == ["report.pdf", "synthetic-notes.txt"])
        #expect(found("~/Documents report") == ["report.pdf"] && found("~/Documents notes").isEmpty)
        // The home folder itself, and a folder whose name only begins like its name.
        #expect(!WordSearch("synthetic", home: home).matches(home))
        #expect(WordSearch("synthetic", home: home).matches(home + "-other/file"))
        // A name that begins with "~" is a name.
        #expect(WordSearch("~$draft", home: home).matches("~$draft.docx"))
        // More words than a mask holds follow the same rule.
        let many = (0..<70).map { "w\($0)" }.joined(separator: " ")
        #expect(!WordSearch(many + " users", home: home).matches(anyOf: [many, home + "/Documents"]))
        #expect(WordSearch(many + " documents", home: home).matches(anyOf: [many, home + "/Documents"]))
    }

    /// The search of a whole scan follows the same rule, whether it reads
    /// each entry's words off its folder or puts the path together.
    @Test func aScanOfTheHomeFolderIsntFoundWholeByItsOwnPath() {
        let home = "/Users/synthetic"
        let root = Folder(name: "synthetic", parent: nil, rootPath: home)
        let documents = Folder(name: "Documents", parent: root)
        documents.listedFiles = [
            FileItem(name: "synthetic-plan.bin", size: 2 << 20, modified: .distantPast, kind: .other),
            FileItem(name: "other.bin", size: 1 << 20, modified: .distantPast, kind: .other),
        ]
        root.subfolders = [documents]
        root.finish()
        let index = ScanIndex(root)
        #expect(index.search("synthetic", home: home).found.map(index.path) == [home + "/Documents/synthetic-plan.bin"])
        #expect(index.search("users", home: home).found.isEmpty)
        #expect(index.search("users", home: nil).found.count == 3)
        #expect(index.search("~/documents other", home: home).found.map(index.path) == [home + "/Documents/other.bin"])
        #expect(index.search("~", home: home).found.count == 3)
    }

    @Test func everyWordMustBeInOneOfSeveralTexts() {
        let search = WordSearch("notes archive")
        #expect(search.matches(anyOf: ["Project notes.txt", "/synthetic/Archive"]))
        #expect(!search.matches(anyOf: ["Project notes.txt", "/synthetic/Desktop"]))
        #expect(WordSearch("").matches(anyOf: []) && !search.matches(anyOf: []))
        // More words than a mask holds are still each looked for.
        let many = (0..<70).map { "w\($0)" }.joined(separator: " ")
        #expect(WordSearch(many).matches(anyOf: [many]) && !WordSearch(many + " absent").matches(anyOf: [many]))
        #expect(WordSearch(many).matches(many))
    }

    /// The search over a scan gives every entry its folder's words instead
    /// of putting each path together; both ways must find the same entries.
    @Test(arguments: ["", "file", "FILE-1", "inner file-2", "outer inner", "synthetic", "synthetic file-0", "absent", "outer/inner", "é", "file-1 é"])
    func aScanIsSearchedAsItsFullPathsWouldBe(_ query: String) {
        let root = Folder(name: "root", parent: nil, rootPath: "/synthetic/root")
        for outer in ["Outer", "Caf\u{E9}"] {
            let a = Folder(name: outer, parent: root)
            for inner in ["Inner", "Other"] {
                let b = Folder(name: inner, parent: a)
                b.listedFiles = (0..<3).map { FileItem(name: "File-\($0).bin", size: Int64($0 + 1) << 20, modified: .distantPast, kind: .other) }
                a.subfolders.append(b)
            }
            root.subfolders.append(a)
        }
        root.finish()
        let index = ScanIndex(root, limit: .max)
        let expected = index.entries.indices.filter { index.entries[$0].parent >= 0 && plainly(query, index.path($0)) }
        #expect(Set(index.search(query, limit: .max).found) == Set(expected))
        // A filter on the entries applies as before.
        let files = index.search(query, limit: .max) { !$0.isFolder }.found
        #expect(Set(files) == Set(expected.filter { !index.entries[$0].isFolder }))
    }

    /// Text folded on the stack and text folded into a buffer give the same
    /// answers: short and long, plain and beyond ASCII, in the home folder or not.
    @Test func everyFoldingPathAnswersTheSame() {
        let long = String(repeating: "x", count: WordSearch.stackLimit + 10) + "Report"
        let search = WordSearch(words: ["report"], excluded: ["draft"], home: "/synthetic/home")
        #expect(search.matches(long, ""))
        #expect(!search.matches(long + " DRAFT", ""))
        #expect(search.matches("Report.pdf", "/synthetic/home/Documents"))
        #expect(!search.matches("Report.pdf", "/synthetic/home/Drafts"))
        #expect(search.matches("Café report", ""))
        #expect(WordSearch("café").matches("CAFÉ.txt", ""))
        // The home folder's own path isn't searched: "home" is in every such path.
        #expect(!WordSearch("home", home: "/synthetic/home").matches("a.txt", "/synthetic/home/Documents"))
        #expect(WordSearch("~/documents", home: "/synthetic/home").matches("a.txt", "/synthetic/home/Documents"))
        for (name, folder) in [("Report.pdf", "/synthetic/home/Docs"), ("x", "y"), (long, "/tmp"), ("Café", "/synthetic/home")] {
            #expect(search.matches(name, folder) == search.matches(anyOf: [name, folder]))
        }
    }
}
