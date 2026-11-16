import Darwin
import Foundation
import Testing

@testable import StorageKit

/// What removal frees where APFS clones share blocks, with real clones in a
/// test's own folder and synthetic families.
@Suite struct ReclaimTests {
    private func clone(_ box: Sandbox, _ from: String, to: String) throws {
        let target = box.url.appending(path: to)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(clonefile(box.url.appending(path: from).path, target.path, 0) == 0)
    }

    private func copy(_ box: Sandbox, _ from: String, to: String) throws {
        let target = box.url.appending(path: to)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contentsOf: box.url.appending(path: from)).write(to: target)
    }

    @Test func aFolderOfClonesOfAFileOutsideItFreesAboutNothing() throws {
        let box = try Box()
        try box.sandbox.file("runtime/base.bin", bytes: 2_000_000)
        try clone(box.sandbox, "runtime/base.bin", to: "devices/one/base.bin")
        try clone(box.sandbox, "runtime/base.bin", to: "devices/two/base.bin")
        let copy = box.sandbox.allocated("runtime/base.bin")

        let whole = StorageScanner.scan(path: box.path, workers: 2).root
        let devices = try #require(whole.find(path: box.path + "/devices"))
        // It occupies two copies, as du counts, and frees nothing while the runtime stays.
        #expect(devices.size == 2 * copy && devices.sharedBytes == 2 * copy)
        #expect(devices.reclaim.bytes == 0)
        // The runtime goes too: the family is complete and one copy is freed.
        #expect(whole.reclaim.bytes == copy && whole.size == 3 * copy)

        // Scanned alone, the clones still know their family isn't all there.
        let alone = StorageScanner.scan(path: box.path + "/devices", workers: 2).root
        #expect(alone.size == 2 * copy && alone.reclaim.bytes == 0)
        let file = try #require(alone.subfolders.first?.listedFiles.first)
        #expect(file.size == copy && file.shared == copy && file.reclaim.bytes == 0)
    }

    @Test func aFolderHoldingAnOriginalAndItsCloneFreesOneCopy() throws {
        let box = try Box()
        try box.sandbox.file("project/a/model.bin", bytes: 1_500_000)
        try clone(box.sandbox, "project/a/model.bin", to: "project/b/model.bin")
        try box.sandbox.file("project/b/notes.bin", bytes: 40_000)
        let copy = box.sandbox.allocated("project/a/model.bin"), notes = box.sandbox.allocated("project/b/notes.bin")

        let root = StorageScanner.scan(path: box.path, workers: 2).root
        let project = try #require(root.find(path: box.path + "/project"))
        let a = try #require(project.find(path: project.path + "/a")), b = try #require(project.find(path: project.path + "/b"))
        #expect(project.size == 2 * copy + notes)
        #expect(project.reclaim.bytes == copy + notes)
        // Either half alone leaves the blocks with the other.
        #expect(a.reclaim.bytes == 0 && b.reclaim.bytes == notes)
        // Chosen together, in either order, they free the copy once.
        #expect((a.reclaim + b.reclaim).bytes == copy + notes)
        #expect((b.reclaim + a.reclaim).bytes == copy + notes)
    }

    @Test func anIndependentCopyAndARewrittenCloneFreeWhatTheyHoldAlone() throws {
        let box = try Box()
        try box.sandbox.file("a.bin", bytes: 1_048_576)
        try copy(box.sandbox, "a.bin", to: "copies/full.bin")
        try clone(box.sandbox, "a.bin", to: "copies/partly.bin")
        // The same bytes written over part of the clone make those blocks its own.
        let path = box.path + "/copies/partly.bin"
        let region = try Data(contentsOf: box.sandbox.url.appending(path: "a.bin"))[0..<131_072]
        let fd = open(path, O_WRONLY)
        #expect(fd >= 0)
        let written = region.withUnsafeBytes { pwrite(fd, $0.baseAddress, region.count, 0) }
        #expect(fsync(fd) == 0 && close(fd) == 0 && written == region.count)

        let copies = try #require(StorageScanner.scan(path: box.path, workers: 1).root.find(path: box.path + "/copies"))
        let own = try #require(FileSpace.sharing(path)?.privateBytes)
        #expect(own >= 131_072 && own < 1_048_576 / 2)
        #expect(copies.reclaim.bytes == box.sandbox.allocated("copies/full.bin") + own)
    }

    @Test func pruningAClonedFolderLeavesItsFamilyOpen() throws {
        let box = try Box()
        try box.sandbox.file("project/a/model.bin", bytes: 1_500_000)
        try clone(box.sandbox, "project/a/model.bin", to: "project/b/model.bin")
        let copy = box.sandbox.allocated("project/a/model.bin")
        let root = StorageScanner.scan(path: box.path, workers: 1).root
        let project = try #require(root.find(path: box.path + "/project"))
        let a = try #require(project.find(path: project.path + "/a")), b = try #require(project.find(path: project.path + "/b"))
        #expect(project.reclaim.bytes == copy)

        // In the Trash its clone still holds the blocks: what stays frees nothing.
        project.remove(a)
        #expect(project.size == copy && project.reclaim.bytes == 0 && root.reclaim.bytes == 0)
        #expect(project.reclaim.open.values.map(\.count) == [1])
        project.restore(a)
        #expect(project.size == 2 * copy && project.reclaim.bytes == copy && root.reclaim.bytes == copy)

        let file = try #require(b.listedFiles.first)
        b.removeFile(named: file.name)
        #expect(project.reclaim.bytes == 0)
        b.restoreFile(file)
        #expect(project.reclaim.bytes == copy && b.reclaim.bytes == 0)
    }

    @Test func emptyingTheTrashCountsWhatClonesElsewhereKeep() throws {
        let box = try Box()
        try box.sandbox.file("Documents/film.mov", bytes: 1_200_000)
        try clone(box.sandbox, "Documents/film.mov", to: "Trash/film copy.mov")
        try clone(box.sandbox, "Documents/film.mov", to: "Trash/folder/film again.mov")
        try box.sandbox.file("Trash/folder/own.bin", bytes: 300_000)
        let copy = box.sandbox.allocated("Documents/film.mov"), own = box.sandbox.allocated("Trash/folder/own.bin")
        let listing = try #require(TrashEmptier.list(box.path + "/Trash"))
        #expect(listing.bytes >= 2 * copy + own)
        #expect(listing.frees >= own && listing.frees < own + copy / 2)
        #expect(listing.entries.first { $0.name == "film copy.mov" }?.reclaim.bytes == 0)
    }

    @Test func projectEntriesFreeWhatTheirFoldersFree() throws {
        let box = try Box()
        try box.sandbox.file("store/package.bin", bytes: 1_100_000)
        try clone(box.sandbox, "store/package.bin", to: "app/node_modules/package.bin")
        let copy = box.sandbox.allocated("store/package.bin")
        let measured = try #require(ProjectAttribution.measure(box.path + "/app/node_modules"))
        #expect(measured.bytes == copy && measured.frees == 0)
        let file = try #require(ProjectAttribution.measure(box.path + "/app/node_modules/package.bin"))
        #expect(file.bytes == copy && file.frees == 0)
        // Read before reclaim was kept, an entry frees its size.
        let old = try JSONDecoder().decode(FootprintEntry.self, from: Data(#"{"path":"/synthetic/a","bytes":5,"modified":0}"#.utf8))
        #expect(old.reclaim == nil && old.frees == 5)
    }

    @Test func familiesCompleteInAnyOrderAndOnlyOnce() {
        let family = FileSpace.Sharing(cloneID: 7, cloneCount: 3, privateBytes: 0, sharesAllBlocks: true)
        let member = Reclaim.file(allocated: 1_000, device: 1, sharing: family)
        let elsewhere = Reclaim.file(allocated: 1_000, device: 2, sharing: family)
        #expect(member.bytes == 0 && (member + member).bytes == 0)
        #expect((member + member + member).bytes == 1_000)
        #expect(((member + member) + (member + elsewhere)).bytes == 1_000)
        // The same clone ID on another volume is another family.
        #expect((member + member + elsewhere).bytes == 0)
    }

    @Test func onlyAFileFlaggedAsSharingCountsItsPrivateSize() {
        // A compressed file reports no private size and no flag: it frees what it takes.
        let compressed = FileSpace.Sharing(cloneID: 9, cloneCount: 0, privateBytes: nil)
        #expect(Reclaim.file(allocated: 4_096, device: 1, sharing: compressed).bytes == 4_096)
        #expect(Reclaim.file(allocated: 4_096, device: 1, sharing: nil).bytes == 4_096)
        // The last of a family holds every block alone.
        let last = FileSpace.Sharing(cloneID: 9, cloneCount: 1, privateBytes: 0, sharesAllBlocks: true)
        #expect(Reclaim.file(allocated: 4_096, device: 1, sharing: last).bytes == 4_096)
        // A partly shared clone counts what it holds alone and joins no family.
        let partly = FileSpace.Sharing(cloneID: 9, cloneCount: 1, privateBytes: 512, sharesAllBlocks: false)
        let reclaim = Reclaim.file(allocated: 4_096, device: 1, sharing: partly)
        #expect(reclaim.bytes == 512 && reclaim.open.isEmpty)
    }

    @Test func manyOpenFamiliesOnlyLowerTheEstimate() {
        var sum = Reclaim()
        for id in 0..<UInt64(Reclaim.openLimit + 10) {
            let sharing = FileSpace.Sharing(cloneID: id, cloneCount: 2, privateBytes: 0, sharesAllBlocks: true)
            sum.add(.file(allocated: 100 + Int64(id), device: 1, sharing: sharing))
        }
        #expect(sum.open.count == Reclaim.openLimit && sum.bytes == 0)
        #expect(sum.open.keys.contains { $0.id == UInt64(Reclaim.openLimit + 9) })
    }

    /// New bytes over `length` at `offset`, as a booted simulator writes to its image.
    private func rewrite(_ box: Sandbox, _ rel: String, at offset: Int, length: Int) {
        let fd = open(box.url.appending(path: rel).path, O_WRONLY)
        #expect(fd >= 0)
        var bytes = [UInt8](repeating: 0, count: length)
        arc4random_buf(&bytes, length)
        #expect(pwrite(fd, bytes, length, off_t(offset)) == length && fsync(fd) == 0 && close(fd) == 0)
    }

    @Test func aHardLinkedFileFreesItsBlocksWithItsLastName() throws {
        let box = try Box()
        try box.sandbox.file("a/film.bin", bytes: 1_500_000)
        try box.sandbox.folder("b")
        let a = box.path + "/a/film.bin", b = box.path + "/b/film link.bin"
        #expect(link(a, b) == 0)
        let copy = box.sandbox.allocated("a/film.bin")

        let root = StorageScanner.scan(path: box.path, workers: 2).root
        let first = try #require(root.find(path: box.path + "/a")), second = try #require(root.find(path: box.path + "/b"))
        // Counted once, like du, and freed only when both names go.
        #expect(root.size == copy && root.reclaim.bytes == copy)
        #expect(first.reclaim.bytes == 0 && second.reclaim.bytes == 0)
        #expect((first.reclaim + second.reclaim).bytes == copy)
        // Chosen one by one, the same.
        let one = try #require(Reclaim.file(at: a)), other = try #require(Reclaim.file(at: b))
        #expect(one.bytes == 0 && other.bytes == 0 && (one + other).bytes == copy)
    }

    @Test func namesOfOneFileCompleteLikeAFamily() {
        let name = Reclaim.file(allocated: 1_000, device: 1, sharing: nil, inode: 5, links: 2)
        #expect(name.bytes == 0 && (name + name).bytes == 1_000)
        let ofThree = Reclaim.file(allocated: 1_000, device: 1, sharing: nil, inode: 6, links: 3)
        #expect((ofThree + ofThree).bytes == 0 && (ofThree + ofThree + ofThree).bytes == 1_000)
        // A clone with a second name frees what it holds alone, once both go.
        let cloned = FileSpace.Sharing(cloneID: 8, cloneCount: 2, privateBytes: 100, sharesAllBlocks: false)
        let linked = Reclaim.file(allocated: 1_000, device: 1, sharing: cloned, inode: 7, links: 2)
        #expect((linked + linked).bytes == 100)
    }

    @Test func aCloneRewrittenElsewhereKeepsWhatItStillShares() throws {
        let box = try Box()
        let mb = 1 << 20
        try box.sandbox.file("sims/one/disk.img", bytes: 4 * mb)
        try clone(box.sandbox, "sims/one/disk.img", to: "sims/two/disk.img")
        try clone(box.sandbox, "sims/one/disk.img", to: "elsewhere/three/disk.img")
        rewrite(box.sandbox, "elsewhere/three/disk.img", at: mb, length: mb)
        let copy = box.sandbox.allocated("sims/one/disk.img")
        let three = box.path + "/elsewhere/three/disk.img"
        let own = try #require(FileSpace.sharing(three)?.privateBytes)
        // The rewritten clone still holds the rest of the copy.
        let kept = box.sandbox.allocated("elsewhere/three/disk.img") - own
        #expect(own >= Int64(mb) && kept >= Int64(2 * mb))

        let root = StorageScanner.scan(path: box.path, workers: 2).root
        let sims = try #require(root.find(path: box.path + "/sims")), elsewhere = try #require(root.find(path: box.path + "/elsewhere"))
        // The two whole clones look like a whole family, yet free only
        // the part the third rewrote.
        #expect(sims.reclaim.bytes == copy - kept)
        #expect(elsewhere.reclaim.bytes == own)
        // All three go: the copy and what the third holds alone.
        #expect(root.reclaim.bytes == copy + own)
        // Chosen apart, the folders free the same together.
        #expect((sims.reclaim + elsewhere.reclaim).bytes == copy + own)
        #expect((elsewhere.reclaim + sims.reclaim).bytes == copy + own)
        // The two files chosen on their own, the same.
        let one = try #require(Reclaim.file(at: box.path + "/sims/one/disk.img"))
        let two = try #require(Reclaim.file(at: box.path + "/sims/two/disk.img"))
        #expect((one + two).bytes == copy - kept)
        let third = try #require(Reclaim.file(at: three))
        #expect((one + two + third).bytes == copy + own && (third + two + one).bytes == copy + own)
        // A later scan of the two alone still knows what the third keeps.
        let alone = StorageScanner.scan(path: box.path + "/sims", workers: 1).root
        #expect(alone.reclaim.bytes == copy - kept)
    }

    @Test func clonesRewrittenApartFreeWhatOnlyTheyHold() throws {
        let box = try Box()
        let mb = 1 << 20
        try box.sandbox.file("pair/a.img", bytes: 4 * mb)
        try clone(box.sandbox, "pair/a.img", to: "pair/b.img")
        // Beside it, a folder whose name sorts between "pair" and "pair/".
        try clone(box.sandbox, "pair/a.img", to: "pair-x/c.img")
        // Each clone rewrites a part of its own: no file holds the whole
        // copy any more, so the volume names no family at all.
        rewrite(box.sandbox, "pair/b.img", at: 0, length: mb)
        rewrite(box.sandbox, "pair-x/c.img", at: 2 * mb, length: mb)
        let copy = box.sandbox.allocated("pair/a.img")
        let ownB = try #require(FileSpace.sharing(box.path + "/pair/b.img")?.privateBytes)
        let ownC = try #require(FileSpace.sharing(box.path + "/pair-x/c.img")?.privateBytes)
        #expect(ownB >= Int64(mb) && ownC >= Int64(mb))

        let root = StorageScanner.scan(path: box.path, workers: 2).root
        let pair = try #require(root.find(path: box.path + "/pair")), other = try #require(root.find(path: box.path + "/pair-x"))
        // a and b go: b's own part, and the part of a's blocks c rewrote,
        // which only a and b still hold.
        #expect(pair.reclaim.bytes == ownB + ownC)
        #expect(other.reclaim.bytes == ownC)
        #expect(root.reclaim.bytes == copy + ownB + ownC)
        #expect((pair.reclaim + other.reclaim).bytes == copy + ownB + ownC)
        let a = try #require(Reclaim.file(at: box.path + "/pair/a.img")), b = try #require(Reclaim.file(at: box.path + "/pair/b.img"))
        #expect(a.bytes == 0 && (a + b).bytes == ownB + ownC)
    }

    @Test func holesOfSparseClonesAreNotSharedBlocks() throws {
        let box = try Box()
        let mb = 1 << 20
        // A sparse image like a simulator's: 4 MB of data in 96 MB.
        try box.sandbox.folder("a")
        let a = box.path + "/a/disk.img"
        let fd = open(a, O_CREAT | O_WRONLY, 0o644)
        var data = [UInt8](repeating: 0, count: 4 * mb)
        arc4random_buf(&data, data.count)
        #expect(ftruncate(fd, off_t(96 * mb)) == 0 && pwrite(fd, data, data.count, off_t(32 * mb)) == data.count && fsync(fd) == 0 && close(fd) == 0)
        try clone(box.sandbox, "a/disk.img", to: "b/disk.img")
        rewrite(box.sandbox, "b/disk.img", at: 33 * mb, length: mb)
        let allocated = box.sandbox.allocated("a/disk.img")
        #expect(allocated < Int64(16 * mb))
        let ownA = try #require(FileSpace.sharing(a)?.privateBytes)
        let ownB = try #require(FileSpace.sharing(box.path + "/b/disk.img")?.privateBytes)

        let root = StorageScanner.scan(path: box.path, workers: 2).root
        let first = try #require(root.find(path: box.path + "/a")), second = try #require(root.find(path: box.path + "/b"))
        // Only blocks on the device count: the holes hold nothing.
        #expect(first.reclaim.bytes == ownA && second.reclaim.bytes == ownB)
        #expect(root.reclaim.bytes == allocated + ownB)
        #expect((first.reclaim + second.reclaim).bytes == allocated + ownB)
    }

    @Test func blocksAlsoHeldOutsideTheScanAreNotCountedFreed() throws {
        let box = try Box()
        let mb = 1 << 20
        try box.sandbox.file("pair/a.img", bytes: 4 * mb)
        try clone(box.sandbox, "pair/a.img", to: "pair/b.img")
        try clone(box.sandbox, "pair/a.img", to: "unscanned/c.img")
        rewrite(box.sandbox, "pair/b.img", at: 0, length: mb)
        rewrite(box.sandbox, "unscanned/c.img", at: 2 * mb, length: mb)
        let ownB = try #require(FileSpace.sharing(box.path + "/pair/b.img")?.privateBytes)
        // a holds the part b rewrote with c alone: its private size, read
        // across the volume, says so although the scan never reads c.
        #expect(FileSpace.sharing(box.path + "/pair/a.img")?.privateBytes == 0)

        let pair = StorageScanner.scan(path: box.path + "/pair", workers: 2).root
        // Of a and b, only what the volume says b holds alone is sure to be
        // freed; the blocks they share may be c's too.
        #expect(pair.reclaim.bytes == ownB)
        let a = try #require(Reclaim.file(at: box.path + "/pair/a.img")), b = try #require(Reclaim.file(at: box.path + "/pair/b.img"))
        #expect((a + b).bytes == ownB)
    }

    @Test func blocksOfAFamilyWithAMemberOutsideTheScanAreNotCountedFreed() throws {
        let box = try Box()
        let mb = 1 << 20
        try box.sandbox.file("seen/a.img", bytes: 4 * mb)
        try clone(box.sandbox, "seen/a.img", to: "unscanned/b.img")
        try clone(box.sandbox, "seen/a.img", to: "seen/h.img")
        rewrite(box.sandbox, "seen/h.img", at: 0, length: mb)
        let ownH = try #require(FileSpace.sharing(box.path + "/seen/h.img")?.privateBytes)

        let seen = StorageScanner.scan(path: box.path + "/seen", workers: 2).root
        // b keeps every block a has, whatever h shares with a.
        #expect(seen.reclaim.bytes == ownH)
        let a = try #require(Reclaim.file(at: box.path + "/seen/a.img")), h = try #require(Reclaim.file(at: box.path + "/seen/h.img"))
        #expect((a + h).bytes == ownH)
    }

    @Test func aWholePairFreesLessWhatAClonePastTheScanStillHolds() throws {
        let box = try Box()
        let mb = 1 << 20
        try box.sandbox.file("pair/a.img", bytes: 4 * mb)
        try clone(box.sandbox, "pair/a.img", to: "pair/b.img")
        try clone(box.sandbox, "pair/a.img", to: "unscanned/c.img")
        rewrite(box.sandbox, "unscanned/c.img", at: 0, length: mb)
        let c = box.path + "/unscanned/c.img"
        let copy = box.sandbox.allocated("pair/a.img")
        let sharedC = box.sandbox.allocated("unscanned/c.img") - (try #require(FileSpace.sharing(c)?.privateBytes))
        // The pair reads as any whole pair: nothing the volume says of a or b names c.
        #expect(FileSpace.sharing(box.path + "/pair/a.img")?.cloneCount == 2)

        // A folder Spotlight leaves out keeps c unknown.
        #expect(StorageScanner.scan(path: box.path + "/pair", workers: 2).root.reclaim.bytes == copy)
        SameSizeFiles.indexedForTests.withLock { _ = $0.insert(c) }
        defer { SameSizeFiles.indexedForTests.withLock { _ = $0.remove(c) } }
        let pair = StorageScanner.scan(path: box.path + "/pair", workers: 2).root
        #expect(pair.reclaim.bytes == copy - sharedC)
        let a = try #require(Reclaim.file(at: box.path + "/pair/a.img")), b = try #require(Reclaim.file(at: box.path + "/pair/b.img"))
        #expect((a + b).bytes == copy - sharedC)
        let withC = try #require(Reclaim.file(at: c))
        #expect((a + b + withC).bytes == copy + box.sandbox.allocated("unscanned/c.img") - sharedC)
    }

    @Test func scanningAFolderAgainRecordsItsSharedBlocksOnce() throws {
        let box = try Box()
        let mb = 1 << 20
        try box.sandbox.file("seen/a.img", bytes: 4 * mb)
        try clone(box.sandbox, "seen/a.img", to: "other/b.img")
        try clone(box.sandbox, "seen/a.img", to: "seen/h.img")
        rewrite(box.sandbox, "seen/h.img", at: 0, length: mb)
        let ownH = try #require(FileSpace.sharing(box.path + "/seen/h.img")?.privateBytes)
        let copy = box.sandbox.allocated("seen/a.img")

        _ = StorageScanner.scan(path: box.path, workers: 2)
        // b, read by the first scan, is outside the next ones.
        for _ in 0..<2 { _ = StorageScanner.scan(path: box.path + "/seen", workers: 2) }
        let files = try ["seen/a.img", "other/b.img", "seen/h.img"].map { try #require(Reclaim.file(at: box.path + "/" + $0)) }
        #expect(files.reduce(Reclaim(bytes: 0), +).bytes == copy + ownH)
    }

    @Test func rescanningForgetsTheBlocksOfARewrittenCloneSinceRemoved() throws {
        let box = try Box()
        let mb = 1 << 20
        try box.sandbox.file("pair/a.img", bytes: 4 * mb)
        try clone(box.sandbox, "pair/a.img", to: "pair/b.img")
        try clone(box.sandbox, "pair/a.img", to: "other/c.img")
        rewrite(box.sandbox, "other/c.img", at: 0, length: mb)
        let copy = box.sandbox.allocated("pair/a.img")
        let first = StorageScanner.scan(path: box.path, workers: 1).root
        #expect(try #require(first.find(path: box.path + "/pair")).reclaim.bytes < copy)
        try FileManager.default.removeItem(atPath: box.path + "/other/c.img")
        #expect(StorageScanner.scan(path: box.path + "/pair", workers: 1).root.reclaim.bytes == copy)
    }

    @Test func rescanningFilesNoLongerSharingForgetsWhatTheyShared() throws {
        let box = try Box()
        let mb = 1 << 20
        try box.sandbox.file("a.img", bytes: 4 * mb)
        try clone(box.sandbox, "a.img", to: "b.img")
        rewrite(box.sandbox, "a.img", at: 0, length: mb)
        rewrite(box.sandbox, "b.img", at: mb, length: mb)
        _ = StorageScanner.scan(path: box.path, workers: 1)
        rewrite(box.sandbox, "a.img", at: 0, length: 4 * mb)
        rewrite(box.sandbox, "b.img", at: 0, length: 4 * mb)
        let second = StorageScanner.scan(path: box.path, workers: 1).root
        #expect(second.reclaim.bytes == second.size)
    }

    @Test func reclaimSavedBeforeNamesWereCountedStillReads() throws {
        let json = #"{"bytes":7,"open":[{"device":1,"id":9},{"count":1,"total":2,"bytes":3}]}"#
        let old = try JSONDecoder().decode(Reclaim.self, from: Data(json.utf8))
        #expect(old.bytes == 7 && old.open[CloneFamily(device: 1, id: 9)]?.total == 2)
        let back = try JSONDecoder().decode(Reclaim.self, from: JSONEncoder().encode(old))
        #expect(back == old)
    }

    /// A sandbox whose real path is used throughout, so scanned paths match.
    private struct Box {
        let sandbox: Sandbox
        let path: String
        init() throws {
            sandbox = try Sandbox()
            path = URL(fileURLWithPath: sandbox.path).resolvingSymlinksInPath().path
        }
    }
}
