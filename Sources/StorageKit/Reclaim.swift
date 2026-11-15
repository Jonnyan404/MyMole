import Darwin
import Foundation

/// Files that hold the same blocks on one volume: clones of one another
/// (`FileSpace.Sharing.cloneID`), or the names of one hard-linked file.
public struct CloneFamily: Sendable, Hashable, Codable {
    public enum Kind: UInt8, Sendable, Codable {
        /// Whole clones: the members are files, `id` their clone ID.
        case clones
        /// One file's names: `id` is its file number, the members its names.
        case names
    }

    public let device: Int32
    public let id: UInt64
    public let kind: Kind

    public init(device: Int32, id: UInt64, kind: Kind = .clones) {
        self.device = device
        self.id = id
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey { case device, id, kind }

    /// Saved before hard links were counted, a family is one of clones.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        device = try c.decode(Int32.self, forKey: .device)
        id = try c.decode(UInt64.self, forKey: .id)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .clones
    }
}

/// Whole clones of one family counted so far, against the volume's count.
public struct CloneMembers: Sendable, Hashable, Codable {
    public internal(set) var count: Int
    /// Files the volume says hold the family's blocks.
    public let total: Int
    /// The blocks they share: one copy.
    public internal(set) var bytes: Int64
}

/// What removing a set of files frees, as opposed to what they occupy.
///
/// Each file counts the blocks it holds alone: its allocated size, or its
/// private size when the volume flags it as sharing blocks. Whole clones of
/// one another add their shared copy once every file the volume counts in
/// the family is in the set; until then they stay `open`, so sets can be
/// combined in any order. The names of a hard-linked file work the same
/// way: its blocks go with the last of them.
///
/// A file rewritten in part after cloning gets a family of its own and
/// counts only its private bytes, and the volume no longer counts it in the
/// old family: that family can complete while the rewritten file still
/// holds most of its copy. A scan compares their blocks (`CloneOverlaps`),
/// and `bytes` leaves out what such files still hold of a family the set
/// completes.
public struct Reclaim: Sendable, Hashable, Codable {
    /// Families tracked per set; past this the smallest are dropped, which
    /// only ever lowers the estimate.
    static let openLimit = 4_096
    /// Completed clone families kept to check against `CloneOverlaps`;
    /// smaller copies aren't worth the check.
    static let checkedCopy: Int64 = 1 << 20

    /// What the set frees as the volume counts it, before rewritten clones
    /// outside it are allowed for.
    public private(set) var counted: Int64
    public private(set) var open: [CloneFamily: CloneMembers]
    /// Clone families the set holds whole, with the copy each one added.
    public private(set) var completed: [CloneFamily: Int64]

    /// What removing the set frees. Of each family it completes, the blocks
    /// a clone rewritten since still holds stay, wherever that clone is.
    public var bytes: Int64 {
        guard !completed.isEmpty else { return counted }
        return max(0, counted - CloneOverlaps.held(completing: completed))
    }

    public init(bytes: Int64 = 0) {
        self.counted = max(bytes, 0)
        self.open = [:]
        self.completed = [:]
    }

    init(bytes: Int64, open: [CloneFamily: CloneMembers], completed: [CloneFamily: Int64] = [:]) {
        self.counted = max(bytes, 0)
        self.open = open
        self.completed = completed
    }

    /// A file of `allocated` bytes on `device`, as the volume reports its
    /// sharing. With `links` above 1 it is one of that many names of file
    /// number `inode`, and frees its blocks only with all of them.
    public static func file(allocated: Int64, device: Int32, sharing: FileSpace.Sharing?, inode: UInt64 = 0, links: UInt32 = 1) -> Reclaim {
        let allocated = max(allocated, 0)
        guard links <= 1 else {
            // What the file frees once no name is left; the clones it may
            // share with stay out of it, which only lowers the count.
            let alone = sharing?.privateBytes.map { min($0, allocated) } ?? allocated
            return Reclaim(bytes: 0, open: [CloneFamily(device: device, id: inode, kind: .names): CloneMembers(count: 1, total: Int(links), bytes: alone)])
        }
        // Without the sharing flag the private size means nothing: a
        // compressed file reports none and frees its allocated size.
        guard let sharing, let privateBytes = sharing.privateBytes else { return Reclaim(bytes: allocated) }
        let alone = min(privateBytes, allocated)
        var reclaim = Reclaim(bytes: alone)
        guard sharing.sharesAllBlocks, let id = sharing.cloneID, let count = sharing.cloneCount, count > 0 else { return reclaim }
        let family = CloneFamily(device: device, id: id)
        if count == 1 {
            reclaim.complete(family, copy: allocated - alone)
            return reclaim
        }
        reclaim.open[family] = CloneMembers(count: 1, total: Int(count), bytes: allocated - alone)
        return reclaim
    }

    /// The file at `path`, read now; nil when nothing is there. A folder
    /// reads as its own entry only: a tree needs a scan.
    public static func file(at path: String) -> Reclaim? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let allocated = Int64(st.st_blocks) * 512
        guard st.st_mode & S_IFMT == S_IFREG else { return Reclaim(bytes: allocated) }
        return file(allocated: allocated, device: st.st_dev, sharing: FileSpace.sharing(path), inode: UInt64(st.st_ino), links: UInt32(st.st_nlink))
    }

    /// The bytes that are shared, with `allocated` the space the set
    /// occupies, as the volume counts them.
    public func shared(of allocated: Int64) -> Int64 { max(0, allocated - counted) }

    /// The family's shared copy is freed with the set.
    private mutating func complete(_ family: CloneFamily, copy: Int64) {
        counted += copy
        guard family.kind == .clones, copy >= Self.checkedCopy, completed.count < Self.openLimit else { return }
        completed[family] = copy
    }

    /// Adds another set, disjoint from this one. A family whose every
    /// counted member is now in the set frees its shared copy.
    public mutating func add(_ other: Reclaim) {
        counted += other.counted
        for (family, copy) in other.completed where completed.count < Self.openLimit { completed[family] = copy }
        guard !other.open.isEmpty else { return }
        if open.isEmpty && other.open.count <= Self.openLimit {
            open = other.open
            closeComplete()
            return
        }
        for (family, members) in other.open {
            if var mine = open[family] {
                mine.count += members.count
                mine.bytes = max(mine.bytes, members.bytes)
                if mine.count >= mine.total {
                    complete(family, copy: mine.bytes)
                    open[family] = nil
                } else {
                    open[family] = mine
                }
            } else if members.count >= members.total {
                complete(family, copy: members.bytes)
            } else {
                open[family] = members
            }
        }
        trim()
    }

    public static func + (lhs: Reclaim, rhs: Reclaim) -> Reclaim {
        var sum = lhs
        sum.add(rhs)
        return sum
    }

    /// Takes away a set that was added, as when it is pruned from a tree.
    /// Families it closed stay counted: the result is an estimate until
    /// the place is read again.
    public mutating func subtract(_ other: Reclaim) {
        counted = max(0, counted - other.counted)
    }

    private mutating func closeComplete() {
        for (family, members) in open where members.count >= members.total {
            complete(family, copy: members.bytes)
            open[family] = nil
        }
    }

    private enum CodingKeys: String, CodingKey { case bytes, open, completed }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        counted = max(try c.decode(Int64.self, forKey: .bytes), 0)
        open = try c.decodeIfPresent([CloneFamily: CloneMembers].self, forKey: .open) ?? [:]
        completed = try c.decodeIfPresent([CloneFamily: Int64].self, forKey: .completed) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(counted, forKey: .bytes)
        try c.encode(open, forKey: .open)
        if !completed.isEmpty { try c.encode(completed, forKey: .completed) }
    }

    private mutating func trim() {
        guard open.count > Self.openLimit else { return }
        let kept = open.sorted { $0.value.bytes > $1.value.bytes }.prefix(Self.openLimit)
        open = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }
}
