import Darwin
import Foundation

/// The words of a filter, looked for in names and paths whatever their
/// case. Text is compared as lower-cased bytes: a filter asks for every row
/// of a list and a search for every entry of a scan, and comparing text
/// character by character took most of that time. A name with letters
/// beyond ASCII is compared in its composed form, so an "é" typed as one
/// letter finds one stored as two.
public struct WordSearch: Sendable {
    let words: [[UInt8]]

    public init(_ query: String) {
        var folded: [UInt8] = []
        Self.fold(query, into: &folded)
        words = folded.split(separator: UInt8(ascii: " ")).map(Array.init)
    }

    public var isEmpty: Bool { words.isEmpty }

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

    private static func holds(_ text: [UInt8], _ word: [UInt8]) -> Bool {
        guard word.count <= text.count else { return false }
        return text.withUnsafeBytes { memmem($0.baseAddress, text.count, word, word.count) != nil }
    }

    /// The words among `wanted` that `text` holds, as bits: word 0 is bit 0.
    func mask(of text: String, wanted: UInt64 = .max, scratch: inout [UInt8]) -> UInt64 {
        Self.fold(text, into: &scratch)
        var found: UInt64 = 0
        for (i, word) in words.prefix(Self.maskWidth).enumerated() where wanted & (1 << UInt64(i)) != 0 && Self.holds(scratch, word) {
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
        return words.allSatisfy { Self.holds(scratch, $0) }
    }

    /// Whether every word is in at least one of `texts`: a row's name, or
    /// the folder it's in.
    public func matches(anyOf texts: [String]) -> Bool {
        guard !words.isEmpty else { return true }
        var scratch: [UInt8] = []
        guard let every else {
            let folded = texts.map { text -> [UInt8] in
                Self.fold(text, into: &scratch)
                return scratch
            }
            return words.allSatisfy { word in folded.contains { Self.holds($0, word) } }
        }
        var found: UInt64 = 0
        for text in texts where found != every { found |= mask(of: text, wanted: every & ~found, scratch: &scratch) }
        return found == every
    }
}
