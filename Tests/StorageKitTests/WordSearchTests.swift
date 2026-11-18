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
}
