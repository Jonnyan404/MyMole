import Foundation
import StorageKit

/// Prepare once per filter change, rather than splitting the query for every row.
struct TextQuery: Sendable {
    let query: SearchQuery
    var isEmpty: Bool { query.isEmpty }
    /// The words and excluded words, for a search that matches texts itself.
    var words: WordSearch { query.text }

    /// Paths in the home folder are searched as the lists show them, from "~" on.
    init(_ text: String) { query = SearchQuery(text, home: Home.path) }

    func matches() -> Bool { matches(texts: []) }
    func matches(_ a: String, _ b: String, _ c: String) -> Bool { matches(texts: [a, b, c]) }
    func matches(_ a: String, _ b: String, _ c: String, _ d: String) -> Bool { matches(texts: [a, b, c, d]) }
    func matches(_ a: String, _ b: String, _ c: String, _ d: String, _ e: String) -> Bool { matches(texts: [a, b, c, d, e]) }

    /// A row's name, and its folder: the common case, without a list per row.
    func matches(_ first: String, _ second: String) -> Bool {
        query.problems.isEmpty && !query.hasConditions && query.text.matches(first, second)
    }

    func matches(_ text: String) -> Bool {
        query.problems.isEmpty && !query.hasConditions && query.text.matches(text, "")
    }

    /// Every word is in at least one of the texts and no excluded word in
    /// any. A list whose rows are only texts lets nothing through while the
    /// filter holds a condition, which it couldn't check.
    func matches(texts: [String]) -> Bool {
        query.problems.isEmpty && !query.hasConditions && query.text.matches(anyOf: texts)
    }

    /// As `matches(texts:)`, with the conditions checked against `facts`.
    func matches(texts: [String], facts: SearchQuery.Facts) -> Bool { query.matches(texts: texts, facts: facts) }

    /// The conditions alone, for a search that matches the words itself.
    func passes(_ facts: SearchQuery.Facts) -> Bool { query.passes(facts) }
}

/// How a filter's text was read, in a line under the field: the words,
/// what's left out and each condition, or what's wrong with it.
@MainActor enum QueryExplanation {
    struct Line: Equatable {
        let text: String
        let isProblem: Bool
    }

    /// Nil for plain words, which need no explaining. `conditions` is
    /// whether the list can check size, kind, extension, age and hidden.
    static func line(for text: String, conditions: Bool) -> Line? {
        let q = SearchQuery(text, home: Home.path)
        guard q.needsExplaining else { return nil }
        if let problem = q.problems.first {
            return Line(text: describe(problem) + " " + String(localized: "Nothing is listed until the filter is fixed."), isProblem: true)
        }
        if q.hasConditions, !conditions {
            return Line(text: String(localized: "This list is filtered by its text only. Conditions such as size: and kind: work in lists of files and folders."), isProblem: true)
        }
        var parts = q.words.map { String(localized: "Contains “\($0)”") }
        parts += q.excluded.map { String(localized: "Except “\($0)”") }
        parts += q.terms.map { term in
            let said = describe(term.condition)
            return term.negated ? String(localized: "Except \(said)") : said
        }
        return Line(text: parts.joined(separator: " · "), isProblem: false)
    }

    static let help = String(localized: "Words find names and folders. Put - before a word to leave out what holds it, and quotes around words to keep spaces. Conditions: size:>500MB, size:1GB-5GB, kind:media, kind:folder, ext:mov,mp4, age:>6m, age:<7d, hidden:yes. Put - before a condition to turn it around.")

    static func describe(_ c: SearchQuery.Condition) -> String {
        switch c {
        case .size(let lo, let hi):
            let f = FileCellResources.byteCount
            switch (lo, hi) {
            case (let lo?, let hi?): return String(localized: "Size \(f.string(fromByteCount: lo)) to \(f.string(fromByteCount: hi))")
            case (let lo?, nil): return String(localized: "Size at least \(f.string(fromByteCount: lo))")
            case (nil, let hi?): return String(localized: "Size under \(f.string(fromByteCount: hi))")
            case (nil, nil): return String(localized: "Any size")
            }
        case .kind(let kind): return String(localized: "Kind: \(kind.title)")
        case .folder: return String(localized: "Folders only")
        case .file: return String(localized: "Files only")
        case .ext(let exts):
            return String(localized: "Extension: \(exts.map { "." + $0 }.formatted(.list(type: .or)))")
        case .age(let older, let amount, let unit, _):
            let span = span(amount, unit)
            return older ? String(localized: "Modified more than \(span) ago") : String(localized: "Modified within the last \(span)")
        case .hidden(let on): return on ? String(localized: "Hidden items only") : String(localized: "No hidden items")
        }
    }

    static func describe(_ p: SearchQuery.Problem) -> String {
        switch p {
        case .unknown(let name):
            return String(localized: "“\(name):” isn't a condition. Use size:, kind:, ext:, age: or hidden:, or put the word in quotes.")
        case .badValue(let name, _):
            switch name {
            case "size": return String(localized: "size: needs a size, such as size:>500MB or size:1GB-5GB.")
            case "kind": return String(localized: "kind: needs a kind, such as kind:media, kind:archives or kind:folder.")
            case "ext": return String(localized: "ext: needs an extension, such as ext:mov or ext:mov,mp4.")
            case "age": return String(localized: "age: needs an age, such as age:>6m for older than six months or age:<7d for the last week.")
            default: return String(localized: "hidden: needs yes or no.")
            }
        }
    }

    /// "6 months", "1.5 days", in the language of the interface.
    static func span(_ amount: Double, _ unit: SearchQuery.AgeUnit) -> String {
        let f = DateComponentsFormatter()
        f.unitsStyle = .full
        f.maximumUnitCount = 1
        var c = DateComponents()
        let whole = Int(amount)
        if Double(whole) == amount {
            switch unit {
            case .hours: c.hour = whole
            case .days: c.day = whole
            case .weeks: c.weekOfMonth = whole
            case .months: c.month = whole
            case .years: c.year = whole
            }
            if let s = f.string(from: c) { return s }
        }
        // A fraction: the unit below it, which the formatter shows whole.
        switch unit {
        case .hours: c.minute = Int((amount * 60).rounded())
        case .days: c.hour = Int((amount * 24).rounded())
        case .weeks: c.day = Int((amount * 7).rounded())
        case .months: c.day = Int((amount * 30.44).rounded())
        case .years: c.month = Int((amount * 12).rounded())
        }
        return f.string(from: c) ?? amount.formatted()
    }
}
