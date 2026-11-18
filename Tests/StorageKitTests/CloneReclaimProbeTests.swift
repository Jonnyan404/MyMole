import Darwin
import Foundation
import Testing

@testable import StorageKit

/// What removing clones really frees on APFS, against what `Reclaim`
/// counts and what comparing the files' physical blocks would count. Off
/// unless MYMOLE_CLONE_PROBE=1: it writes a few hundred megabytes and reads
/// the volume's free space, so it runs alone and prints one line a case.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MYMOLE_CLONE_PROBE"] == "1"))
struct CloneReclaimProbeTests {
    static let mb = 1 << 20
    static let size = 128 * mb
    static let region = 16 * mb

    final class Place {
        /// A quiet APFS volume of its own when MYMOLE_CLONE_PROBE_DIR names one, so
        /// nothing else writing to the disk blurs the free space read.
        let url = (ProcessInfo.processInfo.environment["MYMOLE_CLONE_PROBE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory).appending(path: "clone-probe-\(UUID().uuidString)")
        var dir: String { url.path }
        init() throws { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(at: url) }
        func path(_ name: String) -> String { dir + "/" + name }
    }

    // MARK: Making files

    static func write(_ path: String, size: Int = size) {
        let fd = open(path, O_CREAT | O_WRONLY | O_TRUNC, 0o644)
        var chunk = [UInt8](repeating: 0, count: 8 * mb)
        for _ in 0..<(size / chunk.count) {
            arc4random_buf(&chunk, chunk.count)
            _ = Darwin.write(fd, chunk, chunk.count)
        }
        fsync(fd)
        close(fd)
    }

    /// New bytes over `length` at `offset`, as a booted simulator does to its image.
    static func rewrite(_ path: String, at offset: Int, length: Int = region) {
        let fd = open(path, O_WRONLY)
        var chunk = [UInt8](repeating: 0, count: length)
        arc4random_buf(&chunk, chunk.count)
        _ = pwrite(fd, chunk, chunk.count, off_t(offset))
        fsync(fd)
        close(fd)
    }

    // MARK: Counting

    /// What `Reclaim` says removing `going` frees, file by file as a scan adds them.
    static func today(_ going: [String]) -> Int64 {
        going.compactMap { Reclaim.file(at: $0) }.reduce(Reclaim()) { $0 + $1 }.bytes
    }

    /// The file's blocks as physical ranges on the device.
    static func extents(_ path: String) -> [Range<Int64>] {
        let fd = open(path, O_RDONLY)
        defer { close(fd) }
        var st = stat()
        fstat(fd, &st)
        var out: [Range<Int64>] = []
        var offset: Int64 = 0
        while offset < Int64(st.st_size) {
            var l2p = log2phys()
            l2p.l2p_devoffset = off_t(offset)
            l2p.l2p_contigbytes = off_t(Int64(st.st_size) - offset)
            guard fcntl(fd, F_LOG2PHYS_EXT, &l2p) != -1, l2p.l2p_contigbytes > 0 else { break }
            out.append(Int64(l2p.l2p_devoffset)..<Int64(l2p.l2p_devoffset) + Int64(l2p.l2p_contigbytes))
            offset += Int64(l2p.l2p_contigbytes)
        }
        return out
    }

    static func union(_ ranges: [Range<Int64>]) -> [Range<Int64>] {
        var out: [Range<Int64>] = []
        for r in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = out.last, r.lowerBound <= last.upperBound {
                out[out.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
            } else {
                out.append(r)
            }
        }
        return out
    }

    static func bytes(_ ranges: [Range<Int64>]) -> Int64 { ranges.reduce(0) { $0 + Int64($1.count) } }

    /// The blocks of `going` that no file staying (among `known`) uses.
    static func byExtents(_ going: [String], known: [String]) -> Int64 {
        let gone = union(going.flatMap(extents))
        let kept = union(known.filter { !going.contains($0) }.flatMap(extents))
        var freed: Int64 = 0
        for g in gone {
            var covered: Int64 = 0
            for k in kept where k.overlaps(g) { covered += Int64(g.clamped(to: k).count) }
            freed += Int64(g.count) - covered
        }
        return freed
    }

    /// The device's free space, once it has settled after a change.
    static func free(_ path: String) -> Int64 {
        var last: Int64 = -1
        for _ in 0..<40 {
            sync()
            var s = statfs()
            statfs(path, &s)
            let now = Int64(s.f_bavail) * Int64(s.f_bsize)
            if now == last { return now }
            last = now
            usleep(250_000)
        }
        return last
    }

    /// Removes `going` and says how much the volume got back.
    static func actual(_ going: [String], in dir: String) -> Int64 {
        let before = free(dir)
        for p in going { unlink(p) }
        return free(dir) - before
    }

    static func report(_ name: String, going: [String], known: [String], in place: Place) {
        let naive = going.reduce(Int64(0)) { sum, p in
            var st = stat()
            lstat(p, &st)
            return sum + Int64(st.st_blocks) * 512
        }
        let t = today(going)
        let e = byExtents(going, known: known)
        let a = actual(going, in: place.dir)
        func m(_ b: Int64) -> String { String(format: "%6.1f", Double(b) / Double(mb)) }
        print("clone \(name.padding(toLength: 46, withPad: " ", startingAt: 0)) allocated \(m(naive))  today \(m(t))  extents \(m(e))  actual \(m(a))")
    }

    // MARK: Cases

    @Test func everyCase() throws {
        do {
            let p = try Place()
            Self.write(p.path("A"))
            Self.report("1 plain file", going: [p.path("A")], known: [p.path("A")], in: p)
        }
        do {
            let p = try Place()
            Self.write(p.path("A"))
            let d = p.path("D")
            _ = copyfile(p.path("A"), d, nil, copyfile_flags_t(COPYFILE_DATA))
            Self.report("2 independent copy, one goes", going: [d], known: [p.path("A"), d], in: p)
        }
        do {
            let p = try Place()
            Self.write(p.path("A"))
            _ = clonefile(p.path("A"), p.path("B"), 0)
            Self.report("3 whole clones A,B: B goes", going: [p.path("B")], known: [p.path("A"), p.path("B")], in: p)
        }
        do {
            let p = try Place()
            Self.write(p.path("A"))
            _ = clonefile(p.path("A"), p.path("B"), 0)
            Self.report("4 whole clones A,B: both go", going: [p.path("A"), p.path("B")], known: [p.path("A"), p.path("B")], in: p)
        }
        do {
            let p = try Place()
            Self.write(p.path("A"))
            _ = clonefile(p.path("A"), p.path("B"), 0)
            _ = clonefile(p.path("A"), p.path("C"), 0)
            let all = ["A", "B", "C"].map(p.path)
            Self.report("5 whole clones A,B,C: A,B go", going: [p.path("A"), p.path("B")], known: all, in: p)
        }
        do {
            let p = try Place()
            Self.write(p.path("A"))
            _ = clonefile(p.path("A"), p.path("B"), 0)
            _ = clonefile(p.path("A"), p.path("C"), 0)
            Self.rewrite(p.path("C"), at: 32 * Self.mb)
            let all = ["A", "B", "C"].map(p.path)
            Self.report("6 C rewritten in part: A,B go", going: [p.path("A"), p.path("B")], known: all, in: p)
        }
        do {
            let p = try Place()
            Self.write(p.path("A"))
            _ = clonefile(p.path("A"), p.path("B"), 0)
            _ = clonefile(p.path("A"), p.path("C"), 0)
            Self.rewrite(p.path("C"), at: 32 * Self.mb)
            let all = ["A", "B", "C"].map(p.path)
            Self.report("7 C rewritten in part: C goes", going: [p.path("C")], known: all, in: p)
        }
        do {
            let p = try Place()
            Self.write(p.path("A"))
            _ = clonefile(p.path("A"), p.path("B"), 0)
            _ = clonefile(p.path("A"), p.path("C"), 0)
            Self.rewrite(p.path("C"), at: 32 * Self.mb)
            let all = ["A", "B", "C"].map(p.path)
            Self.report("8 C rewritten in part: all go", going: all, known: all, in: p)
        }
        do {
            // Each clone rewritten in its own place: what A shares with B isn't what it shares with C.
            let p = try Place()
            Self.write(p.path("A"))
            _ = clonefile(p.path("A"), p.path("B"), 0)
            _ = clonefile(p.path("A"), p.path("C"), 0)
            Self.rewrite(p.path("B"), at: 16 * Self.mb)
            Self.rewrite(p.path("C"), at: 64 * Self.mb)
            let all = ["A", "B", "C"].map(p.path)
            Self.report("9 B and C rewritten apart: A goes", going: [p.path("A")], known: all, in: p)
        }
        do {
            let p = try Place()
            Self.write(p.path("A"))
            _ = clonefile(p.path("A"), p.path("B"), 0)
            _ = clonefile(p.path("A"), p.path("C"), 0)
            Self.rewrite(p.path("B"), at: 16 * Self.mb)
            Self.rewrite(p.path("C"), at: 64 * Self.mb)
            let all = ["A", "B", "C"].map(p.path)
            Self.report("10 B and C rewritten apart: A,B go", going: [p.path("A"), p.path("B")], known: all, in: p)
        }
        do {
            // A clone of a clone, each rewritten in part.
            let p = try Place()
            Self.write(p.path("A"))
            _ = clonefile(p.path("A"), p.path("C"), 0)
            Self.rewrite(p.path("C"), at: 32 * Self.mb)
            _ = clonefile(p.path("C"), p.path("E"), 0)
            Self.rewrite(p.path("E"), at: 96 * Self.mb)
            let all = ["A", "C", "E"].map(p.path)
            Self.report("11 chain A→C→E rewritten: A,C go", going: [p.path("A"), p.path("C")], known: all, in: p)
        }
        do {
            // The rewritten clone outside what was read: extents can't see it either.
            let p = try Place()
            Self.write(p.path("A"))
            _ = clonefile(p.path("A"), p.path("B"), 0)
            _ = clonefile(p.path("A"), p.path("C"), 0)
            Self.rewrite(p.path("C"), at: 32 * Self.mb)
            Self.report("12 C rewritten, not read: A,B go", going: [p.path("A"), p.path("B")], known: [p.path("A"), p.path("B")], in: p)
        }
        do {
            let p = try Place()
            Self.write(p.path("A"))
            _ = link(p.path("A"), p.path("L"))
            Self.report("13 hard link: one name goes", going: [p.path("L")], known: [p.path("A"), p.path("L")], in: p)
        }
        do {
            let p = try Place()
            Self.write(p.path("A"))
            _ = clonefile(p.path("A"), p.path("B"), 0)
            Self.rewrite(p.path("B"), at: 0, length: Self.size)
            Self.report("14 clone rewritten whole: B goes", going: [p.path("B")], known: [p.path("A"), p.path("B")], in: p)
        }
    }
}
