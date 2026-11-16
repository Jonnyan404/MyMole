import Darwin
import Foundation
import Synchronization

/// Blocks that clones rewritten since share, by which files hold them.
///
/// APFS counts a clone family by the files that hold all of its blocks. A
/// clone rewritten in part gets a family of its own and drops out of that
/// count, yet keeps sharing the blocks it didn't rewrite; and once every
/// clone is rewritten somewhere, the volume names no family at all. Nothing
/// it reports ties such files together, so after a walk the scan compares
/// where their blocks are on the device (`F_LOG2PHYS_EXT`) and records each
/// stretch of shared blocks with the files holding it: a group. A group
/// works like a family (`CloneFamily.Kind.blocks`): its bytes are freed once
/// every file holding them goes, whichever folders or files they are chosen
/// in. A whole family the volume counts frees its copy less what groups
/// with other files hold of it.
///
/// It knows the files scans have read. A rewritten clone's private size is
/// read across the volume, so when it is less than what the clone holds
/// apart from every file read, a file outside the scans holds the rest: its
/// groups then stay open, never counted as freed. So do the groups of a
/// family whose members weren't all read. Whole clones rewritten outside
/// every scan leave no such trace, and what they share is counted as freed.
public enum CloneOverlaps {
    struct Family: Sendable, Equatable {
        /// Paths of the whole members, the files the volume counts.
        var members: Set<String>
        /// How many files the volume counts in the family.
        var total: Int
        /// The family's shared copy.
        var copy: Int64
        /// Groups holding part of the copy with other files.
        var groups: Set<UInt64> = []
    }

    struct Group: Sendable, Equatable {
        let device: Int32
        /// Every file holding the group's blocks: families' members and
        /// rewritten clones.
        var files: Set<String>
        var bytes: Int64
        /// A file no scan read holds the blocks too, so choosing every
        /// file here doesn't free them.
        var outside = false
        /// How many files hold the blocks, counting one unread for `outside`.
        var holders: Int { files.count + (outside ? 1 : 0) }
    }

    private struct State {
        var families: [CloneFamily: Family] = [:]
        var groups: [UInt64: Group] = [:]
        var next: UInt64 = 1
        /// Every file of a group or family, sorted, to find those inside a folder.
        var index: [(path: String, group: UInt64?, family: CloneFamily?)] = []

        mutating func reindex() {
            var out: [(path: String, group: UInt64?, family: CloneFamily?)] = []
            for (id, g) in groups { for f in g.files { out.append((f, id, nil)) } }
            for (key, f) in families { for m in f.members { out.append((m, nil, key)) } }
            index = out.sorted { $0.path < $1.path }
        }

        /// The entries for the file at `folder` and the files under it. A
        /// sibling such as "pair-x" sorts between "pair" and "pair/", so the
        /// path itself and what's under it are looked up apart.
        func inside(_ folder: String) -> [(path: String, group: UInt64?, family: CloneFamily?)] {
            if folder == "/" { return index }
            func first(atLeast key: String) -> Int {
                var low = 0, high = index.count
                while low < high {
                    let mid = (low + high) / 2
                    if index[mid].path < key { low = mid + 1 } else { high = mid }
                }
                return low
            }
            var out: [(path: String, group: UInt64?, family: CloneFamily?)] = []
            var i = first(atLeast: folder)
            while i < index.count, index[i].path == folder { out.append(index[i]); i += 1 }
            let prefix = folder + "/"
            i = first(atLeast: prefix)
            while i < index.count, index[i].path.hasPrefix(prefix) { out.append(index[i]); i += 1 }
            return out
        }
    }

    private static let state = Mutex(State())

    static var isEmpty: Bool { state.withLock { $0.groups.isEmpty } }

    /// Of the families completed with their copies, the bytes groups with
    /// other files hold; at most each family's copy.
    static func sharedOutside(completing families: [CloneFamily: Int64]) -> Int64 {
        state.withLock { s in
            families.reduce(0) { sum, item in
                guard let family = s.families[item.key] else { return sum }
                let held = family.groups.reduce(Int64(0)) { $0 + (s.groups[$1]?.bytes ?? 0) }
                return sum + min(item.value, held)
            }
        }
    }

    /// The groups that files under `folder` hold blocks of, with how many
    /// of each group's files are there, and the families it holds whole.
    static func within(_ folder: String) -> (open: [CloneFamily: CloneMembers], freed: Int64, completed: [CloneFamily: Int64]) {
        state.withLock { s in
            var counts: [UInt64: Int] = [:], members: [CloneFamily: Int] = [:]
            for entry in s.inside(folder) {
                if let g = entry.group { counts[g, default: 0] += 1 }
                if let f = entry.family { members[f, default: 0] += 1 }
            }
            var open: [CloneFamily: CloneMembers] = [:], freed: Int64 = 0, completed: [CloneFamily: Int64] = [:]
            for (id, count) in counts {
                guard let g = s.groups[id] else { continue }
                if count >= g.holders {
                    freed += g.bytes
                } else {
                    open[CloneFamily(device: g.device, id: id, kind: .blocks)] = CloneMembers(count: count, total: g.holders, bytes: g.bytes)
                }
            }
            for (key, count) in members {
                guard let f = s.families[key], count >= f.members.count, f.members.count >= f.total else { continue }
                completed[key] = f.copy
            }
            return (open, freed, completed)
        }
    }

    /// The groups the file at `path` holds blocks of, one file of each.
    static func groups(of path: String) -> [CloneFamily: CloneMembers] {
        state.withLock { s in
            var out: [CloneFamily: CloneMembers] = [:]
            for entry in s.inside(path) where entry.path == path {
                guard let id = entry.group, let g = s.groups[id] else { continue }
                out[CloneFamily(device: g.device, id: id, kind: .blocks)] = CloneMembers(count: 1, total: g.holders, bytes: g.bytes)
            }
            return out
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
        /// What the volume says the file holds alone.
        var privateBytes: Int64 = 0
    }

    /// Most files a scan compares. A volume with more rewritten clones keeps
    /// what earlier scans recorded and counts the rest as the volume does.
    static let compareLimit = 4_096
    /// Most extents read for one comparison.
    static let extentLimit = 2_000_000
    /// Most groups kept; past this the smallest go, and what they hold is
    /// counted as the volume counts it.
    static let groupLimit = 20_000
    /// How far a file's blocks held apart from every file read may exceed
    /// its private size before a file outside the scan is taken to hold them.
    static let outsideSlack: Int64 = 64 << 10

    /// Compares the blocks of `holders` with each other and with those of
    /// the families `members` belong to, all read by a scan of `root`, and
    /// records the groups. Groups holding a file outside `root` stay: the
    /// scan couldn't see all of their files.
    static func record(scanOf root: String, members: [Member], holders: [Holder], stop: () -> Bool = { false }) {
        guard holders.count <= compareLimit else { return }
        var families: [CloneFamily: Family] = [:]
        for m in members {
            families[m.family, default: Family(members: [], total: m.total, copy: m.copy)].members.insert(m.path)
        }
        // Members earlier scans read outside this one hold the same blocks.
        let known = state.withLock { s in
            families.keys.reduce(into: [CloneFamily: Set<String>]()) { out, key in
                out[key] = s.families[key]?.members.filter { !path($0, isIn: root) }
            }
        }
        var found: [(device: Int32, files: Set<String>, families: Set<CloneFamily>, bytes: Int64, outside: Bool)] = []
        if !holders.isEmpty {
            var read = families
            for (key, outside) in known { read[key]?.members.formUnion(outside) }
            guard let groups = compare(families: read, holders: holders, stop: stop) else { return }
            found = groups
        }
        guard !stop() else { return }
        // Files outside `root` this scan read as well: its groups of them
        // replace those an earlier scan recorded.
        let reread = Set(known.values.joined())
        state.withLock { s in
            // What this scan saw again goes; what reaches past it stays.
            for (id, g) in s.groups where g.files.allSatisfy({ path($0, isIn: root) || reread.contains($0) }) { s.groups[id] = nil }
            for g in found {
                let id = s.next
                s.next += 1
                s.groups[id] = Group(device: g.device, files: g.files, bytes: g.bytes, outside: g.outside)
                for key in g.families { families[key]?.groups.insert(id) }
            }
            if s.groups.count > groupLimit {
                for (id, _) in s.groups.sorted(by: { $0.value.bytes < $1.value.bytes }).prefix(s.groups.count - groupLimit) { s.groups[id] = nil }
            }
            for (key, family) in families {
                var kept: Set<UInt64> = s.families[key]?.groups.filter { s.groups[$0] != nil } ?? []
                kept.formUnion(family.groups)
                let outside = (s.families[key]?.members ?? []).filter { !path($0, isIn: root) }
                s.families[key] = Family(members: family.members.union(outside), total: family.total, copy: family.copy, groups: kept)
            }
            for (key, family) in s.families {
                let live = family.groups.filter { s.groups[$0] != nil }
                s.families[key]?.groups = live
                if live.isEmpty { s.families[key] = nil }
            }
            s.reindex()
        }
    }

    /// Per volume, every stretch of blocks that a rewritten clone shares
    /// with another file, gathered by the files holding it; nil when the
    /// files are too many to compare.
    private static func compare(families: [CloneFamily: Family], holders: [Holder], stop: () -> Bool)
        -> [(device: Int32, files: Set<String>, families: Set<CloneFamily>, bytes: Int64, outside: Bool)]? {
        var budget = extentLimit
        var out: [(device: Int32, files: Set<String>, families: Set<CloneFamily>, bytes: Int64, outside: Bool)] = []
        // Device offsets mean something within one volume only.
        for (device, here) in Dictionary(grouping: holders, by: \.device) {
            let theirs = families.filter { $0.key.device == device }
            guard let found = sweep(families: theirs, holders: here.map(\.path), budget: &budget, stop: stop) else { return nil }
            // A file holding more apart from every file read than the volume
            // says it holds alone shares the rest with a file outside.
            let reaching = Set(here.filter { (found.apart[$0.path] ?? 0) > $0.privateBytes + outsideSlack }.map(\.path))
            for (owners, bytes) in found.groups {
                var files = Set(owners.holders)
                var outside = !owners.holders.isDisjoint(with: reaching)
                for key in owners.families {
                    let family = theirs[key]
                    files.formUnion(family?.members ?? [])
                    if (family?.members.count ?? 0) < (family?.total ?? 0) { outside = true }
                }
                out.append((device, files, owners.families, bytes, outside))
            }
        }
        return out
    }

    private struct Owners: Hashable {
        var families: Set<CloneFamily>
        var holders: Set<String>
    }

    /// One volume's comparison: every file's blocks as ranges of device
    /// offsets, walked in order. A stretch held by a rewritten clone and at
    /// least one other file (a family counting as its members) is added to
    /// the group of exactly those files; one held by a rewritten clone alone
    /// is added to what that clone holds apart.
    private static func sweep(families: [CloneFamily: Family], holders: [String], budget: inout Int, stop: () -> Bool)
        -> (groups: [Owners: Int64], apart: [String: Int64])? {
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
        // Whole members hold the same blocks: one of each family is read.
        for (key, family) in families {
            guard !stop(), let one = family.members.sorted().first, add(one, as: .family(key)) else { return nil }
        }
        for path in holders {
            guard !stop(), add(path, as: .holder(path)) else { return nil }
        }
        events.sort { $0.at != $1.at ? $0.at < $1.at : (!$0.start && $1.start) }
        var active = Set<Int>()
        var out: [Owners: Int64] = [:], apart: [String: Int64] = [:]
        var last: Int64 = 0
        for e in events {
            if e.at > last, active.count == 1, let i = active.first, case .holder(let path) = owners[i] {
                apart[path, default: 0] += e.at - last
            }
            if e.at > last, active.count > 1 {
                var held = Owners(families: [], holders: [])
                for i in active {
                    switch owners[i] {
                    case .family(let key): held.families.insert(key)
                    case .holder(let path): held.holders.insert(path)
                    }
                }
                // A family's own copy, or one file's own blocks, the volume counts.
                if !held.holders.isEmpty { out[held, default: 0] += e.at - last }
            }
            last = e.at
            if e.start { active.insert(e.owner) } else { active.remove(e.owner) }
        }
        return (out, apart)
    }

    /// Forgets every group; for tests.
    static func removeAll() { state.withLock { $0 = State() } }
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
            // A hole of a sparse file has no blocks: its offset reads -1.
            let start = Int64(l2p.l2p_devoffset)
            if start >= 0 { out.append(start..<start + Int64(l2p.l2p_contigbytes)) }
            guard out.count <= limit else { return nil }
            offset += Int64(l2p.l2p_contigbytes)
        }
        return out
    }
}
