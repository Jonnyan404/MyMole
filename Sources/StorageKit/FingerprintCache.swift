import Foundation
import Synchronization

/// Picture fingerprints worked out before, so a search again reads only
/// pictures that are new or changed. An entry counts only for the same
/// file as it was: volume, file number, length and last change to the
/// nanosecond, and the same way of working out the fingerprint. At most
/// `limit` entries are kept, the most recently used. A move to the Trash
/// still checks the file itself, whatever the cache says.
public struct FingerprintCache: Sendable {
    /// Raise when the fingerprint is worked out differently.
    public static let algorithm = 1
    public static let limit = 50_000

    struct Key: Hashable, Codable, Sendable {
        let device: Int32
        let inode: UInt64
        let length: Int64
        let modified: Double
    }

    struct Entry: Codable, Sendable {
        let print: UInt64
        let width: Int
        let height: Int
        var used: Double
    }

    private struct File: Codable {
        let algorithm: Int
        let entries: [Key: Entry]
    }

    private(set) var entries: [Key: Entry] = [:]

    public init() {}

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "MyMole/Fingerprints/pictures.bin")
    }

    /// Where an earlier build kept the cache, as JSON: read once when there
    /// is no file of the current kind, and removed by the next save.
    public static func earlierFile(of url: URL) -> URL? {
        url.pathExtension == "bin" ? url.deletingPathExtension().appendingPathExtension("json") : nil
    }

    /// The file: a header, then one fixed record per entry. A search reads
    /// and writes it every time, so it's a copy of memory, not a document;
    /// 50,000 entries as JSON took a quarter of a second each way.
    private enum Format {
        static let magic: UInt32 = 0x4D4D_4650  // "MMFP"
        static let version: UInt32 = 1
        static let header = 16
        static let record = 52
    }

    /// The saved cache, or an empty one when there's none, it's damaged,
    /// or it was made another way.
    public static func load(from url: URL) -> FingerprintCache {
        if let d = try? Data(contentsOf: url, options: .mappedIfSafe) { return decode(d) ?? FingerprintCache() }
        guard let earlier = earlierFile(of: url), let d = try? Data(contentsOf: earlier),
              let f = try? JSONDecoder().decode(File.self, from: d), f.algorithm == algorithm else { return FingerprintCache() }
        var c = FingerprintCache()
        c.entries = f.entries
        return c
    }

    public func save(to url: URL) {
        var kept = entries
        if kept.count > Self.limit {
            let newest = kept.sorted { $0.value.used > $1.value.used }.prefix(Self.limit)
            kept = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? Self.encode(kept).write(to: url, options: .atomic)) != nil else { return }
        SavedResults.removeEarlierFingerprints(besides: url)
    }

    static func encode(_ entries: [Key: Entry]) -> Data {
        var d = Data(capacity: Format.header + entries.count * Format.record)
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        put(Format.magic)
        put(Format.version)
        put(UInt32(algorithm))
        put(UInt32(entries.count))
        for (k, e) in entries {
            put(k.device)
            put(k.inode)
            put(k.length)
            put(k.modified.bitPattern)
            put(e.print)
            put(Int32(clamping: e.width))
            put(Int32(clamping: e.height))
            put(e.used.bitPattern)
        }
        return d
    }

    /// Nil for a file of another kind, version or fingerprint, or one cut short.
    static func decode(_ d: Data) -> FingerprintCache? {
        d.withUnsafeBytes { raw -> FingerprintCache? in
            func get<T: FixedWidthInteger>(_ offset: Int, _: T.Type) -> T { T(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: T.self)) }
            guard raw.count >= Format.header, get(0, UInt32.self) == Format.magic, get(4, UInt32.self) == Format.version,
                  get(8, UInt32.self) == UInt32(algorithm) else { return nil }
            let count = Int(get(12, UInt32.self))
            guard raw.count == Format.header + count * Format.record else { return nil }
            var c = FingerprintCache()
            c.entries.reserveCapacity(count)
            for i in 0..<count {
                let o = Format.header + i * Format.record
                let key = Key(device: get(o, Int32.self), inode: get(o + 4, UInt64.self), length: get(o + 12, Int64.self),
                              modified: Double(bitPattern: get(o + 20, UInt64.self)))
                c.entries[key] = Entry(print: get(o + 28, UInt64.self), width: Int(get(o + 36, Int32.self)),
                                       height: Int(get(o + 40, Int32.self)), used: Double(bitPattern: get(o + 44, UInt64.self)))
            }
            return c
        }
    }

    static func key(device: Int32, inode: UInt64, length: Int64, modified: Date) -> Key {
        Key(device: device, inode: inode, length: length, modified: modified.timeIntervalSince1970)
    }

    mutating func look(_ key: Key, now: Date = .now) -> (UInt64, Int, Int)? {
        guard var e = entries[key] else { return nil }
        e.used = now.timeIntervalSince1970
        entries[key] = e
        return (e.print, e.width, e.height)
    }

    mutating func store(_ key: Key, print: UInt64, width: Int, height: Int, now: Date = .now) {
        entries[key] = Entry(print: print, width: width, height: height, used: now.timeIntervalSince1970)
    }

    public var count: Int { entries.count }
}

/// A cache several readers share during one search.
public final class SharedFingerprints: Sendable {
    let cache: Mutex<FingerprintCache>
    public init(_ cache: FingerprintCache) { self.cache = Mutex(cache) }
    public var current: FingerprintCache { cache.withLock { $0 } }
}
