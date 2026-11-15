import Darwin
import Foundation
import Synchronization

/// Clone families that clones rewritten since still share blocks with.
///
/// APFS counts a family by the files that hold all of its blocks. A clone
/// rewritten in part gets a family of its own and drops out of that count,
/// yet keeps sharing the blocks it didn't rewrite: a family can look whole
/// while such a file elsewhere still holds most of its copy. Nothing the
/// volume reports ties the two together, so a scan compares where their
/// blocks are on the device (`F_LOG2PHYS_EXT`) and records, per family,
/// how much each rewritten clone still holds.
///
/// Only families such a file overlaps are kept, so the record stays small.
/// It knows the files scans have read: a rewritten clone outside every
/// scan is unknown, and the family's copy is counted as freed.
public enum CloneOverlaps {
    struct Entry: Sendable, Equatable {
        /// Paths of the whole members, the files the volume counts.
        var members: Set<String>
        /// How many files the volume counts in the family.
        var total: Int
        /// The family's shared copy.
        var copy: Int64
        /// Rewritten clones by path, with the bytes of the copy each still holds.
        var holders: [String: Int64]
    }

    private static let entries = Mutex([CloneFamily: Entry]())

    static var isEmpty: Bool { entries.withLock { $0.isEmpty } }

    /// Of the families completed with their copies, what rewritten clones
    /// still hold, wherever they are; at most each family's copy.
    static func held(completing families: [CloneFamily: Int64]) -> Int64 {
        entries.withLock { known in
            families.reduce(0) { sum, item in
                guard let entry = known[item.key] else { return sum }
                return sum + min(item.value, entry.holders.values.reduce(0, +))
            }
        }
    }

    /// What rewritten clones outside `folder` hold of the families whose
    /// members are all inside it: removing the folder leaves those blocks.
    static func held(inside folder: String) -> Int64 {
        entries.withLock { known in
            guard !known.isEmpty else { return 0 }
            return known.values.reduce(0) { sum, entry in
                guard entry.members.count >= entry.total, entry.members.allSatisfy({ Self.path($0, isIn: folder) }) else { return sum }
                let outside = entry.holders.filter { !Self.path($0.key, isIn: folder) }.values.reduce(0, +)
                return sum + min(entry.copy, outside)
            }
        }
    }

    static func path(_ path: String, isIn folder: String) -> Bool {
        folder == "/" || path == folder || path.hasPrefix(folder + "/")
    }

    /// One whole member of a family, as a scan reads it.
    struct Member: Sendable {
        let family: CloneFamily
        let path: String
        let total: Int
        let copy: Int64
    }

    /// A file sharing some of its blocks with files the volume doesn't name.
    struct Holder: Sendable {
        let device: Int32
        let path: String
    }

    /// Most files a scan compares. A volume with more rewritten clones keeps
    /// what earlier scans recorded and counts the rest as the volume does.
    static let compareLimit = 4_096
    /// Most extents read for one comparison.
    static let extentLimit = 2_000_000

    /// Compares the blocks of `holders` with those of the families `members`
    /// belong to, all read by a scan of `root`, and records the overlaps.
    /// Overlaps recorded for files outside `root` stay: the scan couldn't
    /// see them.
    static func record(scanOf root: String, members: [Member], holders: [Holder], stop: () -> Bool = { false }) {
        var families: [CloneFamily: (paths: Set<String>, total: Int, copy: Int64)] = [:]
        for m in members {
            families[m.family, default: ([], m.total, m.copy)].paths.insert(m.path)
        }
        var found: [CloneFamily: [String: Int64]] = [:]
        if !holders.isEmpty, !families.isEmpty, holders.count + families.count <= compareLimit,
           let overlaps = compare(families: families.mapValues { $0.paths.sorted().first! }, holders: holders, stop: stop) {
            found = overlaps
        } else if !holders.isEmpty, !families.isEmpty {
            return
        }
        guard !stop() else { return }
        entries.withLock { known in
            for (family, seen) in families {
                var holders = (known[family]?.holders ?? [:]).filter { !path($0.key, isIn: root) }
                for (p, bytes) in found[family] ?? [:] { holders[p] = bytes }
                guard !holders.isEmpty else {
                    known[family] = nil
                    continue
                }
                let members = (known[family]?.members ?? []).filter { !path($0, isIn: root) }.union(seen.paths)
                known[family] = Entry(members: members, total: seen.total, copy: seen.copy, holders: holders)
            }
        }
    }

    /// For each family (by one member's path), the bytes each holder's
    /// blocks overlap it; nil when the files are too many to compare.
    private static func compare(families: [CloneFamily: String], holders: [Holder], stop: () -> Bool) -> [CloneFamily: [String: Int64]]? {
        var budget = extentLimit
        var out: [CloneFamily: [String: Int64]] = [:]
        // Device offsets mean something within one volume only.
        for (device, here) in Dictionary(grouping: holders, by: \.device) {
            let theirs = families.filter { $0.key.device == device }
            guard !theirs.isEmpty else { continue }
            guard let found = sweep(families: theirs, holders: here.map(\.path), budget: &budget, stop: stop) else { return nil }
            out.merge(found) { a, _ in a }
        }
        return out
    }

    /// One volume's comparison: every file's blocks as ranges of device
    /// offsets, walked in order, adding up where a family's and a holder's
    /// ranges cover the same blocks.
    private static func sweep(families: [CloneFamily: String], holders: [String], budget: inout Int, stop: () -> Bool) -> [CloneFamily: [String: Int64]]? {
        enum Owner { case family(CloneFamily), holder(String) }
        var events: [(at: Int64, start: Bool, owner: Int)] = []
        var owners: [Owner] = []
        func add(_ path: String, as owner: Owner) -> Bool {
            guard let ranges = FileSpace.extents(path, limit: budget) else { return budget > 0 }
            budget -= ranges.count
            let index = owners.count
            owners.append(owner)
            for r in ranges {
                events.append((r.lowerBound, true, index))
                events.append((r.upperBound, false, index))
            }
            return true
        }
        for (family, path) in families {
            guard !stop(), add(path, as: .family(family)) else { return nil }
        }
        for path in holders {
            guard !stop(), add(path, as: .holder(path)) else { return nil }
        }
        events.sort { $0.at != $1.at ? $0.at < $1.at : (!$0.start && $1.start) }
        var activeFamilies = Set<Int>(), activeHolders = Set<Int>()
        var out: [CloneFamily: [String: Int64]] = [:]
        var last: Int64 = 0
        for e in events {
            if e.at > last, !activeFamilies.isEmpty, !activeHolders.isEmpty {
                for f in activeFamilies {
                    guard case .family(let family) = owners[f] else { continue }
                    for h in activeHolders {
                        guard case .holder(let path) = owners[h] else { continue }
                        out[family, default: [:]][path, default: 0] += e.at - last
                    }
                }
            }
            last = e.at
            switch (owners[e.owner], e.start) {
            case (.family, true): activeFamilies.insert(e.owner)
            case (.family, false): activeFamilies.remove(e.owner)
            case (.holder, true): activeHolders.insert(e.owner)
            case (.holder, false): activeHolders.remove(e.owner)
            }
        }
        return out
    }

    /// Forgets every overlap; for tests.
    static func removeAll() { entries.withLock { $0.removeAll() } }
}

extension FileSpace {
    /// Where the file's data is on the device, as ranges of device offsets,
    /// read without following a link and without downloading it; nil when
    /// it can't be opened or has more than `limit` extents.
    static func extents(_ path: String, limit: Int = .max) -> [Range<Int64>]? {
        withoutDownloading { readExtents(path, limit: limit) }
    }

    private static func readExtents(_ path: String, limit: Int) -> [Range<Int64>]? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
        var out: [Range<Int64>] = []
        var offset: Int64 = 0
        let size = Int64(st.st_size)
        while offset < size {
            var l2p = log2phys()
            l2p.l2p_devoffset = off_t(offset)
            l2p.l2p_contigbytes = off_t(size - offset)
            guard fcntl(fd, F_LOG2PHYS_EXT, &l2p) != -1, l2p.l2p_contigbytes > 0 else { break }
            let start = Int64(l2p.l2p_devoffset)
            out.append(start..<start + Int64(l2p.l2p_contigbytes))
            guard out.count <= limit else { return nil }
            offset += Int64(l2p.l2p_contigbytes)
        }
        return out
    }
}
