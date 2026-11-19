import Darwin
import Foundation

/// The words of a filter, looked for in names and paths whatever their
/// case. Text is compared as lower-cased bytes: a filter asks for every row
/// of a list and a search for every entry of a scan, and comparing text
/// character by character took most of that time. A name with letters
/// beyond ASCII is compared in its composed form, so an "é" typed as one
/// letter finds one stored as two.
///
/// With a home folder given, a path inside it is searched as the lists
/// show it, with the home folder's own path left out ("~/Library/Caches"):
/// the name of the account, or "users", is in every such path and would
/// find every row. A word that holds a slash is a piece of a path, and is
/// looked for in the whole of it; "~" at its start stands for the home folder.
///
/// Words given as excluded leave out a row that holds any of them.
public struct WordSearch: Sendable {
    /// The words a row must hold, then those it mustn't.
    let words: [[UInt8]]
    /// How many of `words`, from the start, a row must hold.
    private let required: Int
    /// For each word, whether it's a piece of a path.
    private let wholePath: [Bool]
    /// The home folder's path, lower-cased as the texts are; empty for none.
    private let home: [UInt8]

    /// The words are what white space of any kind sets apart: a pasted
    /// tab or line break ends a word as a space does.
    public init(_ query: String, home: String? = nil) {
        self.init(words: query.split(whereSeparator: \.isWhitespace).map(String.init), home: home)
    }

    /// Words already set apart, which may hold spaces of their own.
    public init(words: [String], excluded: [String] = [], home: String? = nil) {
        var folded: [UInt8] = []
        var homeBytes: [UInt8] = []
        if let home, home.count > 1, home.hasPrefix("/") { Self.fold(home, into: &homeBytes) }
        let slash = UInt8(ascii: "/"), tilde = UInt8(ascii: "~")
        let given = (words + excluded).filter { !$0.isEmpty }
        self.words = given.map { word in
            Self.fold(word, into: &folded)
            let named = folded.count == 1 || (folded.count > 1 && folded[1] == slash)
            if !homeBytes.isEmpty, folded.first == tilde, named { return homeBytes + folded.dropFirst() }
            return folded
        }
        required = words.filter { !$0.isEmpty }.count
        wholePath = self.words.map { $0.contains(slash) }
        self.home = homeBytes
    }

    public var isEmpty: Bool { words.isEmpty }
    /// Some word is a piece of a path, looked for across the folders' names.
    var hasPathWords: Bool { wholePath.contains(true) }

    /// Whether the words found, as bits, are every required one and none excluded.
    func accepts(_ found: UInt64) -> Bool {
        let n = min(words.count, Self.maskWidth)
        let need: UInt64 = required >= Self.maskWidth ? .max : (1 << UInt64(required)) - 1
        let all: UInt64 = n == Self.maskWidth ? .max : (1 << UInt64(n)) - 1
        return found & need == need && found & (all & ~need) == 0
    }

    /// The most words a mask holds; a longer filter is matched word by word.
    static let maskWidth = 64
    /// Every word of the filter as set bits, when they fit a mask.
    var every: UInt64? {
        words.count > Self.maskWidth ? nil : words.count == Self.maskWidth ? .max : (1 << UInt64(words.count)) - 1
    }

    /// `text` lower-cased as bytes, in `out`, which is reused between calls.
    static func fold(_ text: String, into out: inout [UInt8]) {
        out.removeAll(keepingCapacity: true)
        var text = text
        let ascii = text.withUTF8 { bytes -> Bool in
            out.reserveCapacity(bytes.count)
            for byte in bytes {
                guard byte < 0x80 else { return false }
                out.append(byte &- 0x41 < 26 ? byte | 0x20 : byte)
            }
            return true
        }
        guard !ascii else { return }
        out.removeAll(keepingCapacity: true)
        out.append(contentsOf: text.lowercased().precomposedStringWithCanonicalMapping.utf8)
    }

    private static func holds(_ text: [UInt8], from start: Int, _ word: [UInt8]) -> Bool {
        let count = text.count - start
        guard word.count <= count else { return false }
        return text.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return false }
            return memmem(base + start, count, word, word.count) != nil
        }
    }

    /// Where in `text` a word that is no piece of a path is looked for
    /// from: past the home folder's own path when the text is the home
    /// folder or lies inside it, else from its start.
    private func pastHome(_ text: [UInt8]) -> Int {
        let n = home.count
        guard n > 0, text.count >= n, text.count == n || text[n] == UInt8(ascii: "/") else { return 0 }
        return text.withUnsafeBytes { memcmp($0.baseAddress, home, n) == 0 } ? n : 0
    }

    /// Whether the folded `text` holds word `i`.
    private func holds(_ text: [UInt8], past: Int, word i: Int) -> Bool {
        Self.holds(text, from: wholePath[i] ? 0 : past, words[i])
    }

    /// The words among `wanted` that `text` holds, as bits: word 0 is bit 0.
    func mask(of text: String, wanted: UInt64 = .max, scratch: inout [UInt8]) -> UInt64 {
        Self.fold(text, into: &scratch)
        let past = pastHome(scratch)
        var found: UInt64 = 0
        for i in 0..<min(words.count, Self.maskWidth) where wanted & (1 << UInt64(i)) != 0 && holds(scratch, past: past, word: i) {
            found |= 1 << UInt64(i)
        }
        return found
    }

    /// Whether `text` holds every word.
    public func matches(_ text: String) -> Bool {
        var scratch: [UInt8] = []
        return matches(text, scratch: &scratch)
    }

    /// As `matches(_:)`, for a loop over many texts: `scratch` is reused.
    public func matches(_ text: String, scratch: inout [UInt8]) -> Bool {
        guard !words.isEmpty else { return true }
        Self.fold(text, into: &scratch)
        let past = pastHome(scratch)
        return words.indices.allSatisfy { holds(scratch, past: past, word: $0) == ($0 < required) }
    }

    /// Whether every word is in at least one of `texts`: a row's name, or
    /// the folder it's in.
    public func matches(anyOf texts: [String]) -> Bool {
        guard !words.isEmpty else { return true }
        var scratch: [UInt8] = []
        guard let every else {
            let folded = texts.map { text -> (bytes: [UInt8], past: Int) in
                Self.fold(text, into: &scratch)
                return (scratch, pastHome(scratch))
            }
            return words.indices.allSatisfy { i in folded.contains { holds($0.bytes, past: $0.past, word: i) } == (i < required) }
        }
        var found: UInt64 = 0
        for text in texts where found != every { found |= mask(of: text, wanted: every & ~found, scratch: &scratch) }
        return accepts(found)
    }
}
