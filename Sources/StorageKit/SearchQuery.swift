import Foundation

/// What a filter's text asks for: words to find, words to leave out, and
/// conditions on size, kind, extension, age and hidden items.
///
///     report -draft size:>500MB kind:media ext:mov,mp4 age:>1y hidden:no "two words"
///
/// A word that starts with "-" leaves out what holds it, and "-" before a
/// condition turns it around. Quotes keep a word as it is, spaces and
/// colons included; around a condition's value alone, as in
/// `kind:"Caches & Logs"`, they keep its spaces. A word with a slash is a piece of a path, never a
/// condition. Anything else of the form `name:value` with letters before
/// the colon is a condition, and one the query doesn't know, or with a
/// value it can't read, is a problem: a query with problems lets nothing
/// through, so a mistyped condition never widens a list that rows are
/// chosen from. Prepared once per change of the text.
public struct SearchQuery: Sendable {
    public enum Condition: Sendable, Equatable {
        /// At least `min` and less than `max` bytes; either may be open.
        case size(min: Int64?, max: Int64?)
        case kind(FileKind)
        case folder
        case file
        /// Lower-cased, without the dot.
        case ext([String])
        /// Changed before `cutoff` (older) or on or after it (newer); the
        /// text it was read from is kept to show.
        case age(older: Bool, amount: Double, unit: AgeUnit, cutoff: Date)
        case hidden(Bool)
    }

    public enum AgeUnit: String, Sendable, Equatable {
        case hours, days, weeks, months, years
    }

    public struct Term: Sendable, Equatable {
        public let condition: Condition
        /// Written with "-" before it: what doesn't meet it passes.
        public let negated: Bool
    }

    public enum Problem: Error, Sendable, Equatable {
        /// `name:` isn't a condition.
        case unknown(String)
        /// The condition `name:` has a value it can't read, or none.
        case badValue(name: String, value: String)
    }

    /// What a row is checked against, besides its texts.
    public struct Facts: Sendable {
        public var name: String
        public var size: Int64
        public var modified: Date?
        public var kind: FileKind?
        /// Nil when the list doesn't know, so neither kind:folder nor kind:file passes.
        public var isFolder: Bool?
        public var hidden: Bool

        public init(name: String, size: Int64, modified: Date?, kind: FileKind?, isFolder: Bool?, hidden: Bool) {
            (self.name, self.size, self.modified, self.kind, self.isFolder, self.hidden) = (name, size, modified, kind, isFolder, hidden)
        }
    }

    public let words: [String]
    public let excluded: [String]
    public let terms: [Term]
    public let problems: [Problem]
    /// The words and excluded words, prepared for matching texts.
    public let text: WordSearch

    public static let conditionNames = ["size", "kind", "ext", "age", "hidden"]

    public init(_ query: String, home: String? = nil, now: Date = .now, calendar: Calendar = .current) {
        var words: [String] = [], excluded: [String] = [], terms: [Term] = [], problems: [Problem] = []
        for token in Self.tokens(query) {
            // Quotes from the start keep a word; quotes around the value alone keep its spaces.
            if let (name, value) = Self.condition(token.text), token.quoteStart.map({ $0 > name.count }) ?? true {
                switch Self.parse(name: name, value: value, now: now, calendar: calendar) {
                case .success(let c): terms.append(Term(condition: c, negated: token.negated))
                case .failure(let p): problems.append(p)
                }
            } else if token.negated {
                excluded.append(token.text)
            } else {
                words.append(token.text)
            }
        }
        (self.words, self.excluded, self.terms, self.problems) = (words, excluded, terms, problems)
        text = WordSearch(words: words, excluded: excluded, home: home)
    }

    public var isEmpty: Bool { text.isEmpty && terms.isEmpty && problems.isEmpty }
    /// More than plain words: what the filter field spells out under itself.
    public var needsExplaining: Bool { !terms.isEmpty || !problems.isEmpty || !excluded.isEmpty || words.contains { $0.contains(where: \.isWhitespace) } }
    public var hasConditions: Bool { !terms.isEmpty }

    /// Whether a row with these texts and facts passes.
    public func matches(texts: [String], facts: Facts) -> Bool {
        guard problems.isEmpty else { return false }
        return passes(facts) && text.matches(anyOf: texts)
    }

    /// The conditions alone, for a search that matches the words itself.
    public func passes(_ facts: Facts) -> Bool {
        guard problems.isEmpty else { return false }
        return terms.allSatisfy { Self.meets($0.condition, facts) != $0.negated }
    }

    // MARK: Reading the text

    struct Token: Equatable {
        var text: String
        /// Where in `text` the first quote opened, if any did.
        var quoteStart: Int?
        var quoted: Bool { quoteStart != nil }
        /// It started with "-", which isn't part of the text.
        var negated = false
    }

    /// Words set apart by white space, with a quoted stretch, spaces and
    /// all, kept in one word; an unclosed quote runs to the end. A "-"
    /// before a word, outside quotes, leaves it out; a "-" alone is a word.
    static func tokens(_ query: String) -> [Token] {
        var out: [Token] = []
        var current = Token(text: "")
        var inQuotes = false, started = false
        func end() {
            if current.negated, current.text.isEmpty, !current.quoted { out.append(Token(text: "-")) }
            else if !current.text.isEmpty { out.append(current) }
            current = Token(text: "")
            started = false
        }
        for ch in query {
            if ch == "\"" {
                inQuotes.toggle()
                if current.quoteStart == nil { current.quoteStart = current.text.count }
                started = true
            } else if ch.isWhitespace, !inQuotes {
                end()
            } else if ch == "-", !started {
                current.negated = true
                started = true
            } else {
                current.text.append(ch)
                started = true
            }
        }
        end()
        return out
    }

    /// `name` and `value` of a word that reads as a condition.
    static func condition(_ word: String) -> (String, String)? {
        guard !word.contains("/"), let colon = word.firstIndex(of: ":") else { return nil }
        let name = word[..<colon]
        guard !name.isEmpty, name.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        return (name.lowercased(), String(word[word.index(after: colon)...]))
    }

    static func parse(name: String, value: String, now: Date, calendar: Calendar) -> Result<Condition, Problem> {
        let bad = Problem.badValue(name: name, value: value)
        let v = value.lowercased()
        switch name {
        case "size":
            return size(v).map { .success(.size(min: $0.min, max: $0.max)) } ?? .failure(bad)
        case "kind":
            return kind(v).map { .success($0) } ?? .failure(bad)
        case "ext":
            let exts = v.split(separator: ",").map { $0.hasPrefix(".") ? String($0.dropFirst()) : String($0) }.filter { !$0.isEmpty }
            return exts.isEmpty ? .failure(bad) : .success(.ext(exts))
        case "age":
            return age(v, now: now, calendar: calendar).map { .success($0) } ?? .failure(bad)
        case "hidden":
            switch v {
            case "yes", "true", "only", "1": return .success(.hidden(true))
            case "no", "false", "0": return .success(.hidden(false))
            default: return .failure(bad)
            }
        default:
            return .failure(.unknown(name))
        }
    }

    /// ">500mb", ">=1g", "<2gb", "100mb-2gb", or "1gb" for at least that much.
    /// Sizes count in thousands, as the lists show them.
    static func size(_ v: String) -> (min: Int64?, max: Int64?)? {
        if let dash = v.firstIndex(of: "-"), dash != v.startIndex {
            guard let lo = bytes(String(v[..<dash])), let hi = bytes(String(v[v.index(after: dash)...])), lo <= hi else { return nil }
            return (lo, hi == .max ? nil : hi + 1)
        }
        let (op, rest) = comparison(v)
        guard let n = bytes(rest) else { return nil }
        switch op {
        case ">": return (n == .max ? .max : n + 1, nil)
        case ">=", "": return (n, nil)
        case "<": return (nil, n)
        case "<=": return (nil, n == .max ? nil : n + 1)
        default: return nil
        }
    }

    static func comparison(_ v: String) -> (String, String) {
        for op in [">=", "<=", ">", "<", "="] where v.hasPrefix(op) {
            return (op == "=" ? "" : op, String(v.dropFirst(op.count)))
        }
        return ("", v)
    }

    static func bytes(_ v: String) -> Int64? {
        let digits = v.prefix { $0.isNumber || $0 == "." || $0 == "," }
        guard let n = Double(digits.replacingOccurrences(of: ",", with: ".")), n >= 0 else { return nil }
        let unit: Double
        switch v.dropFirst(digits.count).trimmingCharacters(in: .whitespaces) {
        case "", "b", "byte", "bytes": unit = 1
        case "k", "kb": unit = 1e3
        case "m", "mb": unit = 1e6
        case "g", "gb": unit = 1e9
        case "t", "tb": unit = 1e12
        default: return nil
        }
        let total = n * unit
        return total >= Double(Int64.max) ? .max : Int64(total.rounded())
    }

    static func kind(_ v: String) -> Condition? {
        switch v {
        case "folder", "folders", "dir", "directory": return .folder
        case "file", "files": return .file
        case "app", "apps", "application", "applications": return .kind(.apps)
        case "dev", "developer", "code": return .kind(.developer)
        case "cache", "caches", "log", "logs": return .kind(.caches)
        case "media", "photo", "photos", "image", "images", "picture", "pictures", "music", "audio", "video", "videos", "movie", "movies":
            return .kind(.media)
        case "doc", "docs", "document", "documents": return .kind(.documents)
        case "archive", "archives", "installer", "installers": return .kind(.archives)
        case "system", "library", "libraries": return .kind(.system)
        case "other": return .kind(.other)
        default:
            // A kind's own title, as the Kind column shows it in any language.
            return FileKind.allCases.first { $0.title.lowercased() == v }.map { .kind($0) }
        }
    }

    /// ">30d" older than 30 days, "<1w" newer than a week; "6m" alone is
    /// older than six months.
    static func age(_ v: String, now: Date, calendar: Calendar) -> Condition? {
        let (op, rest) = comparison(v)
        let older: Bool
        switch op {
        case ">", ">=", "": older = true
        case "<", "<=": older = false
        default: return nil
        }
        let digits = rest.prefix { $0.isNumber || $0 == "." }
        guard let amount = Double(digits), amount > 0 else { return nil }
        let unit: AgeUnit
        let component: Calendar.Component
        switch rest.dropFirst(digits.count) {
        case "h", "hour", "hours": (unit, component) = (.hours, .hour)
        case "d", "day", "days": (unit, component) = (.days, .day)
        case "w", "week", "weeks": (unit, component) = (.weeks, .weekOfYear)
        case "m", "mo", "month", "months": (unit, component) = (.months, .month)
        case "y", "year", "years": (unit, component) = (.years, .year)
        default: return nil
        }
        let whole = amount.rounded(.down)
        guard whole == amount, whole < 100_000, let cutoff = calendar.date(byAdding: component, value: -Int(whole), to: now) else {
            // A fraction counts in the unit's usual length.
            let seconds: Double = switch unit {
            case .hours: 3_600
            case .days: 86_400
            case .weeks: 604_800
            case .months: 2_629_746
            case .years: 31_556_952
            }
            guard amount * seconds < 1e11 else { return nil }
            return .age(older: older, amount: amount, unit: unit, cutoff: now.addingTimeInterval(-amount * seconds))
        }
        return .age(older: older, amount: amount, unit: unit, cutoff: cutoff)
    }

    // MARK: Checking a row

    static func meets(_ c: Condition, _ f: Facts) -> Bool {
        switch c {
        case .size(let lo, let hi): return (lo.map { f.size >= $0 } ?? true) && (hi.map { f.size < $0 } ?? true)
        case .kind(let k): return f.kind == k
        case .folder: return f.isFolder == true
        case .file: return f.isFolder == false
        case .ext(let exts): return extensionOf(f.name).map(exts.contains) ?? false
        case .age(let older, _, _, let cutoff):
            guard let m = f.modified, m != .distantPast else { return false }
            return older ? m < cutoff : m >= cutoff
        case .hidden(let wanted): return f.hidden == wanted
        }
    }

    /// The lower-cased extension of a name; none for ".zshrc" or "README".
    public static func extensionOf(_ name: String) -> String? {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        let ext = name[name.index(after: dot)...]
        return ext.isEmpty ? nil : ext.lowercased()
    }

    /// The facts of a row known by its path, with its kind from its name.
    public static func facts(path: String, size: Int64, modified: Date?, kind: FileKind? = nil, isFolder: Bool?) -> Facts {
        let name = (path as NSString).lastPathComponent
        let folder = (path as NSString).deletingLastPathComponent
        let kind = kind ?? (isFolder == true ? Classifier.kind(ofFolder: name) : Classifier.kind(ofFile: name))
        return Facts(name: name, size: size, modified: modified, kind: kind, isFolder: isFolder, hidden: isHidden(name: name, folder: folder))
    }

    /// Whether a name, or a folder on the path it's in, starts with a dot.
    public static func isHidden(name: String, folder: String) -> Bool {
        name.hasPrefix(".") || folder.contains("/.")
    }
}
