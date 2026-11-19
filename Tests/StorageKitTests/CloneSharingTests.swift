import Darwin
import Foundation
import Testing

@testable import StorageKit

/// Identical copies made to share their storage, in folders of the test's
/// own, with the replaced copy going to the test's own Trash folder.
@Suite struct CloneSharingTests {
    private func copy(_ box: Sandbox, _ from: String, to: String) throws {
        let target = box.url.appending(path: to)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contentsOf: box.url.appending(path: from)).write(to: target)
    }

    private func tag(_ path: String, _ value: String) {
        let data = Array(value.utf8)
        #expect(setxattr(path, "com.example.note", data, data.count, 0, XATTR_NOFOLLOW) == 0)
    }

    private func note(_ path: String) -> String? {
        var buffer = [UInt8](repeating: 0, count: 64)
        let n = getxattr(path, "com.example.note", &buffer, buffer.count, 0, XATTR_NOFOLLOW)
        return n < 0 ? nil : String(decoding: buffer.prefix(n), as: UTF8.self)
    }

    private func setDates(_ path: String, made: Date, changed: Date) throws {
        var url = URL(fileURLWithPath: path)
        var v = URLResourceValues()
        v.creationDate = made
        v.contentModificationDate = changed
        try url.setResourceValues(v)
    }

    private func groups(_ box: Sandbox) -> [DuplicateGroup] {
        DuplicateFinder.find(in: [box.path + "/Documents", box.path + "/Downloads"], minimum: 100_000, workers: 1).groups
    }

    @Test func theCopyThatStaysIsClonedAndWhatCantShareSaysWhy() throws {
        let box = try Sandbox()
        try box.file("Documents/a.bin", bytes: 300_000)
        try copy(box, "Documents/a.bin", to: "Downloads/a.bin")
        try copy(box, "Documents/a.bin", to: "Downloads/b.bin")
        #expect(link(box.path + "/Downloads/b.bin", box.path + "/Downloads/b link.bin") == 0)
        try setDates(box.path + "/Documents/a.bin", made: .distantPast, changed: Date(timeIntervalSince1970: 1_600_000_000))
        let g = try #require(groups(box).first)
        let a = box.path + "/Documents/a.bin", c = box.path + "/Downloads/a.bin"
        // Of the two names, the search lists one.
        let b = try #require(g.files.map(\.path).first { $0.hasPrefix(box.path + "/Downloads/b") })
        let plan = CloneSharing.plan([g], chosen: [c, b], supportsClones: { _ in true })
        #expect(plan.shares.map(\.copy) == [c] && plan.shares.first?.source == a)
        #expect(plan.bytes == g.bytes)
        // b has a second name (the hard link), which only one of them is ever listed by.
        #expect(plan.skipped == [b: .otherNames])
        #expect(CloneSharing.plan([g], chosen: Set(g.files.map(\.path)), supportsClones: { _ in true }).shares.isEmpty)
        #expect(CloneSharing.plan([g], chosen: [c], supportsClones: { _ in false }).skipped[c] == .noClones)
    }

    @Test func aSharedCopyKeepsItsOwnNameDatesAndTagsAndTheOldOneGoesToTheTrash() throws {
        let box = try Sandbox()
        try box.file("Documents/report.bin", bytes: 400_000)
        try copy(box, "Documents/report.bin", to: "Downloads/report.bin")
        let source = box.path + "/Documents/report.bin", target = box.path + "/Downloads/report.bin"
        try setDates(source, made: Date(timeIntervalSince1970: 1_500_000_000), changed: Date(timeIntervalSince1970: 1_500_000_100))
        try setDates(target, made: Date(timeIntervalSince1970: 1_700_000_000), changed: Date(timeIntervalSince1970: 1_700_000_100))
        tag(source, "the source's")
        tag(target, "the copy's")
        try FileManager.default.createDirectory(atPath: box.path + "/Bin", withIntermediateDirectories: true)
        let before = try #require(groups(box).first)
        try #require(before.files.first?.path == source)
        let plan = CloneSharing.plan([before], chosen: [target])
        guard !plan.shares.isEmpty else {
            // Not an APFS disk: nothing can share, and nothing is touched.
            #expect(plan.skipped[target] == .noClones)
            return
        }
        let out = CloneSharing.share(plan, groups: [before], home: box.path, backend: .folder(box.path + "/Bin"))
        #expect(out.shared == [target] && out.skipped.isEmpty && out.trashed.count == 1)
        #expect(try Data(contentsOf: URL(fileURLWithPath: target)) == Data(contentsOf: URL(fileURLWithPath: source)))
        #expect(note(target) == "the copy's" && note(source) == "the source's")
        let v = try URL(fileURLWithPath: target).resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        #expect(v.creationDate == Date(timeIntervalSince1970: 1_700_000_000) && v.contentModificationDate == Date(timeIntervalSince1970: 1_700_000_100))
        // The replaced copy is in the Trash folder by a name that says what it was.
        #expect(out.trashed.first?.original.lastPathComponent == "report (before sharing).bin")
        #expect(FileManager.default.fileExists(atPath: out.trashed.first!.trashed.path))
        // Searched again, both are one clone family: the space of one copy.
        let after = try #require(groups(box).first)
        #expect(after.spare == 0 && after.clones(of: target) == 1)
        // Nothing else is left beside it.
        #expect(try FileManager.default.contentsOfDirectory(atPath: box.path + "/Downloads") == ["report.bin"])
    }

    @Test func aCopyChangedSinceItWasComparedIsLeftAlone() throws {
        let box = try Sandbox()
        try box.file("Documents/a.bin", bytes: 300_000)
        try copy(box, "Documents/a.bin", to: "Downloads/a.bin")
        try FileManager.default.createDirectory(atPath: box.path + "/Bin", withIntermediateDirectories: true)
        let g = try #require(groups(box).first)
        let target = box.path + "/Downloads/a.bin"
        let plan = CloneSharing.plan([g], chosen: [target])
        guard !plan.shares.isEmpty else { return }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: target))
        try handle.seek(toOffset: 10)
        try handle.write(contentsOf: Data([1, 2, 3]))
        try handle.close()
        let out = CloneSharing.share(plan, groups: [g], home: box.path, backend: .folder(box.path + "/Bin"))
        #expect(out.shared.isEmpty && out.skipped[target] == .changed)
        #expect(try FileManager.default.contentsOfDirectory(atPath: box.path + "/Bin").isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: box.path + "/Downloads") == ["a.bin"])
    }

    @Test func freeNamesCountUp() throws {
        let box = try Sandbox()
        try box.file("x/report.pdf", bytes: 10)
        try box.file("x/report (shared).pdf", bytes: 10)
        #expect(CloneSharing.freeName(in: box.path + "/x", for: "report.pdf", marker: "shared") == box.path + "/x/report (shared 2).pdf")
        #expect(CloneSharing.freeName(in: box.path + "/x", for: "notes", marker: "shared") == box.path + "/x/notes (shared)")
    }
}
