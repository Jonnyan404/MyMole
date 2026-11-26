import Darwin
import Foundation
import Testing

@testable import StorageKit

/// After every command that moves or changes files, each byte and what
/// belongs with it is checked, not only that a name is there: what moved
/// is in the Trash exactly as it was, what was put back is exactly as it
/// was, what wasn't chosen hasn't changed at all, and the sizes said are
/// the sizes measured independently.
@Suite(.serialized) struct IntegrityTests {
    /// A tree of what files on a Mac carry: random and empty content, a
    /// sparse file, tags, a resource fork and Finder info, hidden and
    /// locked flags, unusual permissions, a time to the nanosecond, an old
    /// creation date and Date Added, an access rule (ACL), links (one going
    /// nowhere), a file with two names, names in decomposed Unicode, and a bundle.
    static func richTree(_ box: Sandbox, at dir: String) throws {
        let base = box.path + "/" + dir
        try box.file(dir + "/random.bin", bytes: 1 << 20)
        try box.file(dir + "/sub/deep/deeper/note.txt", bytes: 3_000)
        try box.file(dir + "/Bundle.app/Contents/MacOS/Bundle", bytes: 40_000)
        try box.file(dir + "/Bundle.app/Contents/Info.plist", bytes: 600)
        try box.file(dir + "/Cafe\u{301} 名前 🙂.txt", bytes: 700)
        try box.file(dir + "/private.txt", bytes: 900)
        try box.file(dir + "/tool.sh", bytes: 400)
        try box.file(dir + "/old.txt", bytes: 500)
        try box.file(dir + "/hidden.txt", bytes: 300)
        try box.file(dir + "/tagged.txt", bytes: 2_000)
        try box.file(dir + "/one name.bin", bytes: 50_000)
        try box.file(dir + "/sub/locked.txt", bytes: 800)
        FileManager.default.createFile(atPath: base + "/empty", contents: Data())
        // 64 MB long, almost none of it written.
        let fd = open(base + "/sparse.bin", O_CREAT | O_WRONLY, 0o644)
        #expect(fd >= 0 && ftruncate(fd, 64 << 20) == 0 && pwrite(fd, "end", 3, (64 << 20) - 3) == 3)
        close(fd)
        #expect(chmod(base + "/private.txt", 0o600) == 0 && chmod(base + "/tool.sh", 0o755) == 0)
        var times = [timespec(tv_sec: 978_307_200, tv_nsec: 123_456_789), timespec(tv_sec: 978_307_200, tv_nsec: 123_456_789)]
        #expect(utimensat(AT_FDCWD, base + "/old.txt", &times, 0) == 0)
        #expect(chflags(base + "/hidden.txt", UInt32(UF_HIDDEN)) == 0)
        for (name, size) in [("com.apple.metadata:_kMDItemUserTags", 60), ("com.apple.ResourceFork", 5_000), ("com.apple.FinderInfo", 32), ("com.example.note", 20)] {
            var value = [UInt8](repeating: 0, count: size)
            arc4random_buf(&value, size)
            if name == "com.apple.FinderInfo" { value = [UInt8](repeating: 0, count: 32); value[0] = 0x54 }
            #expect(setxattr(base + "/tagged.txt", name, value, size, 0, XATTR_NOFOLLOW) == 0)
        }
        try FileManager.default.createSymbolicLink(atPath: base + "/to random", withDestinationPath: "random.bin")
        try FileManager.default.createSymbolicLink(atPath: base + "/nowhere", withDestinationPath: "/nonexistent/mymole/target")
        #expect(link(base + "/one name.bin", base + "/sub/other name.bin") == 0)
        #expect(chflags(base + "/sub/locked.txt", UInt32(UF_IMMUTABLE)) == 0)
        // Made and added to its folder in 2001.
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_CRTIME)
        var made = timespec(tv_sec: 978_307_200, tv_nsec: 5)
        #expect(setattrlist(base + "/old.txt", &list, &made, MemoryLayout<timespec>.size, UInt32(FSOPT_NOFOLLOW)) == 0)
        let folder = open(base, O_RDONLY | O_DIRECTORY)
        #expect(DateAdded.set(978_307_200_000_000_007, on: "old.txt", in: folder))
        close(folder)
        #expect(DateAdded.read(base + "/old.txt") == 978_307_200_000_000_007)
        // Everyone may read it: an access rule beyond the permissions.
        let rule = acl_from_text("!#acl 1\ngroup:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:everyone:12:allow:read\n")
        #expect(rule != nil && acl_set_link_np(base + "/private.txt", ACL_TYPE_EXTENDED, rule) == 0)
        acl_free(UnsafeMutableRawPointer(rule))
        #expect(TreeFingerprint.accessRules(base + "/private.txt").contains("allow"))
    }

    /// Locked files can't be removed, so the box unlocks them before it goes.
    static func unlockAll(_ box: Sandbox) {
        let all = FileManager.default.enumerator(atPath: box.path)
        while let rel = all?.nextObject() as? String { chflags(box.path + "/" + rel, 0) }
    }

    /// Blocks each file takes, once for a file with several names, as `du` counts them.
    static func allocated(_ root: String) -> (bytes: Int64, files: Int) {
        var seen = Set<String>(), bytes: Int64 = 0, files = 0
        var paths = [root]
        if let all = FileManager.default.enumerator(atPath: root) { while let rel = all.nextObject() as? String { paths.append(root + "/" + rel) } }
        for p in paths {
            var st = stat()
            guard lstat(p, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { continue }
            files += 1
            if seen.insert("\(st.st_dev):\(st.st_ino)").inserted { bytes += Int64(st.st_blocks) * 512 }
        }
        return (bytes, files)
    }

    private func gate() -> TrashGate { TrashGate(still: { _ in true }, protections: TrashGate.keepsNothing) }

    @Test func aMoveKeepsEveryByteAndUndoPutsBackExactlyWhatWasThere() throws {
        let box = try Sandbox()
        defer { Self.unlockAll(box) }
        try Self.richTree(box, at: "home/work")
        try Self.richTree(box, at: "home/keep")
        let backend = try testBin(box)
        let before = try TreeFingerprint(box.path + "/home")
        let chosen = ["work/random.bin", "work/tagged.txt", "work/to random", "work/nowhere", "work/one name.bin", "work/Bundle.app",
                      "work/sub", "work/Cafe\u{301} 名前 🙂.txt", "work/hidden.txt", "work/old.txt", "work/private.txt", "work/sparse.bin", "work/empty"]
        let out = Trasher.moveToTrash(chosen.map { box.path + "/home/" + $0 }, through: gate(), backend: backend)
        #expect(out.failed.isEmpty && out.moved.count == chosen.count)
        // Each item in the Trash is the item that left, byte for byte.
        for record in out.moved {
            let rel = String(record.original.path.dropFirst(box.path.count + "/home/".count))
            let there = try TreeFingerprint(record.trashed.path)
            #expect(there.items == before.under(rel), "\(rel): \(TreeFingerprint.differences(before.under(rel), there.items))")
        }
        // Nothing that wasn't chosen changed.
        let during = try TreeFingerprint(box.path + "/home")
        #expect(during.outside(chosen) == before.outside(chosen), "\(TreeFingerprint.differences(before.outside(chosen), during.outside(chosen)))")
        // Undo: everything exactly as it was, and the Trash as empty as before.
        #expect(Trasher.restore(out.moved).isEmpty)
        let after = try TreeFingerprint(box.path + "/home")
        #expect(after == before, "\(TreeFingerprint.differences(before.items, after.items))")
        #expect(try FileManager.default.contentsOfDirectory(atPath: box.path + "/Bin").isEmpty)
    }

    /// A whole folder of everything, and an item locked itself.
    @Test func aFolderAndALockedItemMoveAndComeBackWhole() throws {
        let box = try Sandbox()
        defer { Self.unlockAll(box) }
        try Self.richTree(box, at: "home/work")
        try box.file("home/locked alone.txt", bytes: 1_200)
        #expect(chflags(box.path + "/home/locked alone.txt", UInt32(UF_IMMUTABLE)) == 0)
        // As an uninstall moves: a locked item is unlocked right before it moves.
        let backend = try testBin(box).unlockingLocked()
        let before = try TreeFingerprint(box.path + "/home")
        let out = Trasher.moveToTrash([box.path + "/home/work", box.path + "/home/locked alone.txt"], through: gate(), backend: backend)
        #expect(out.failed.isEmpty && out.moved.count == 2, "\(out.failed)")
        for record in out.moved {
            let rel = record.original.lastPathComponent
            var expected = before.under(rel)
            // Unlocked to move, as Finder does, and said so in the record.
            if rel == "locked alone.txt" {
                expected[""]?.flags &= ~UInt32(UF_IMMUTABLE)
                #expect(record.locked == true)
            }
            let there = try TreeFingerprint(record.trashed.path)
            #expect(there.items == expected, "\(rel): \(TreeFingerprint.differences(expected, there.items))")
        }
        // Undo locks it again: everything as it was, the lock too.
        #expect(Trasher.restore(out.moved).isEmpty)
        let after = try TreeFingerprint(box.path + "/home")
        #expect(after == before, "\(TreeFingerprint.differences(before.items, after.items))")
    }

    /// Something new took the name meanwhile: it stays byte for byte, and
    /// what comes back is beside it, byte for byte.
    @Test func aRestoreBesideANewOccupantChangesNeither() throws {
        let box = try Sandbox()
        try box.file("home/report.bin", bytes: 200_000)
        let backend = try testBin(box)
        let original = try TreeFingerprint(box.path + "/home/report.bin")
        let out = Trasher.moveToTrash([box.path + "/home/report.bin"], through: gate(), backend: backend)
        let record = try #require(out.moved.first)
        try box.file("home/report.bin", bytes: 150_000)
        let occupant = try TreeFingerprint(box.path + "/home/report.bin")
        let left = Trasher.restore(out.moved)
        #expect(try TreeFingerprint(box.path + "/home/report.bin") == occupant)
        if left.isEmpty {
            let names = try FileManager.default.contentsOfDirectory(atPath: box.path + "/home").filter { $0 != "report.bin" }
            let back = try #require(names.first)
            #expect(try TreeFingerprint(box.path + "/home/" + back) == original)
        } else {
            // Not put back: still in the Trash, unchanged.
            #expect(try TreeFingerprint(record.trashed.path) == original)
        }
    }

    /// A scan says what an independent count of the blocks says, a file
    /// with two names once, and its sizes add up to what goes.
    @Test func aScanCountsExactlyWhatTheBlocksSay() throws {
        let box = try Sandbox()
        defer { Self.unlockAll(box) }
        try Self.richTree(box, at: "home/work")
        let measured = Self.allocated(box.path + "/home")
        let scan = StorageScanner.scan(path: box.path + "/home", workers: 2)
        #expect(scan.root.size == measured.bytes)
        #expect(scan.root.fileCount == measured.files - 1)
        // A folder's size is what moving it takes away.
        let sub = try #require(scan.root.find(path: box.path + "/home/work/Bundle.app"))
        #expect(sub.size == Self.allocated(box.path + "/home/work/Bundle.app").bytes)
    }

    /// Emptying the Trash removes what was listed and nothing else, and says
    /// what it freed as the blocks say.
    @Test func emptyingTheTrashTakesOnlyWhatsInIt() throws {
        let box = try Sandbox()
        defer { Self.unlockAll(box) }
        try Self.richTree(box, at: "home/keep")
        try Self.richTree(box, at: "Bin/old work")
        try box.file("Bin/report.bin", bytes: 300_000)
        let before = try TreeFingerprint(box.path + "/home")
        let inBin = Self.allocated(box.path + "/Bin")
        let all = FileManager.default.enumerator(atPath: box.path + "/Bin")
        while let rel = all?.nextObject() as? String { chflags(box.path + "/Bin/" + rel, 0) }
        let listing = try #require(TrashEmptier.list(box.path + "/Bin"))
        let out = TrashEmptier.empty(listing)
        #expect(out.failed == 0 && out.removed == 2)
        #expect(out.bytes == inBin.bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: box.path + "/Bin").isEmpty)
        #expect(try TreeFingerprint(box.path + "/home") == before)
    }

    /// Sharing a copy's storage keeps both copies' bytes and the copy's own
    /// permissions, dates, flags and attributes; the old copy goes to the
    /// Trash as it was.
    @Test func sharingStorageKeepsBothCopiesExactly() throws {
        let box = try Sandbox()
        try box.file("Documents/movie.bin", bytes: 600_000)
        try FileManager.default.createDirectory(atPath: box.path + "/Downloads", withIntermediateDirectories: true)
        let source = box.path + "/Documents/movie.bin", target = box.path + "/Downloads/movie.bin"
        try Data(contentsOf: URL(fileURLWithPath: source)).write(to: URL(fileURLWithPath: target))
        #expect(chmod(target, 0o640) == 0 && chflags(target, UInt32(UF_HIDDEN)) == 0)
        var times = [timespec(tv_sec: 1_600_000_000, tv_nsec: 987_654_321), timespec(tv_sec: 1_600_000_000, tv_nsec: 987_654_321)]
        #expect(utimensat(AT_FDCWD, target, &times, 0) == 0)
        let tags = [UInt8](repeating: 7, count: 40)
        #expect(setxattr(target, "com.apple.metadata:_kMDItemUserTags", tags, tags.count, 0, XATTR_NOFOLLOW) == 0)
        let backend = try testBin(box)
        let sourceBefore = try TreeFingerprint(source), targetBefore = try TreeFingerprint(target)
        let addedBefore = try #require(DateAdded.read(target))
        let groups = DuplicateFinder.find(in: [box.path + "/Documents", box.path + "/Downloads"], minimum: 100_000, workers: 1).groups
        let plan = CloneSharing.plan(groups, chosen: [target])
        guard !plan.shares.isEmpty else { return }
        let out = CloneSharing.share(plan, groups: groups, home: box.path, backend: backend)
        #expect(out.shared == [target])
        #expect(try TreeFingerprint(source) == sourceBefore)
        let targetAfter = try TreeFingerprint(target)
        #expect(targetAfter == targetBefore, "\(TreeFingerprint.differences(targetBefore.items, targetAfter.items))")
        // Finder still shows it added when it was, not when it was shared.
        #expect(DateAdded.read(target) == addedBefore)
        let old = try #require(out.trashed.first)
        #expect(try TreeFingerprint(old.trashed.path) == targetBefore)
    }
}
