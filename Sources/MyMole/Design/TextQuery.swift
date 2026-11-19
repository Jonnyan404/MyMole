import Foundation
import StorageKit

/// Prepare once per filter change, rather than splitting the query for every row.
struct TextQuery: Sendable {
    private let search: WordSearch
    var isEmpty: Bool { search.isEmpty }

    /// Paths in the home folder are searched as the lists show them, from "~" on.
    init(_ text: String) { search = WordSearch(text, home: Home.path) }

    func matches(_ texts: String...) -> Bool { matches(texts: texts) }

    /// Every word is in at least one of the texts.
    func matches(texts: [String]) -> Bool { search.matches(anyOf: texts) }
}
