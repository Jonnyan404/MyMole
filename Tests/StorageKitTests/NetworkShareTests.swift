import Darwin
import Foundation
import Testing

@testable import StorageKit

/// A server whose disk tells case apart can hold two files whose names
/// differ only by case. A Mac reaching it over SMB opens one of them by
/// either name, so neither name says which file's content was read.
@Suite struct CaseTwinNameTests {
    @Test func namesThatDifferOnlyByCaseOrComposedFormAreTwins() {
        let twins = DuplicateFinder.caseTwins(["photo.jpg", "Photo.JPG", "notes.txt", "Cafe\u{301}.txt", "Café.txt", "other.txt"])
        #expect(twins == ["photo.jpg", "Photo.JPG", "Cafe\u{301}.txt", "Café.txt"])
    }

    @Test func distinctNamesHaveNoTwins() {
        #expect(DuplicateFinder.caseTwins(["a.txt", "b.txt", "a.txt.bak"]).isEmpty)
    }
}

/// The volume a path is on, as the system names its kind.
func fileSystemType(of path: String) -> String? {
    var fs = statfs()
    guard statfs(path, &fs) == 0 else { return nil }
    return withUnsafeBytes(of: fs.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
}

/// What the volume allocates for each regular file under `dir`, hidden ones
/// included, as the Mac reads it file by file.
func allocatedFiles(under dir: String) throws -> (count: Int, bytes: Int64) {
    var count = 0
    var bytes: Int64 = 0
    let all = FileManager.default.enumerator(atPath: dir)
    while let name = all?.nextObject() as? String {
        let values = try URL(fileURLWithPath: dir + "/" + name).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
        count += 1
        bytes += Int64(values.totalFileAllocatedSize ?? 0)
    }
    return (count, bytes)
}

/// A real SMB share, served by Samba with a case-sensitive Linux disk
/// behind it. Started, seeded and torn down by `scripts/volume-tests.sh`.
/// The files read here are written on the server before the share is
/// mounted: the Mac shows a file it has just written with its own times
/// until its cache expires, then with the server's, a few milliseconds
/// apart, and a file whose times move between listing and reading is
/// rightly never compared.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MYMOLE_SMB_SHARE"] != nil))
struct NetworkShareTests {
    let share = ProcessInfo.processInfo.environment["MYMOLE_SMB_SHARE"] ?? ""

    func seeded(_ folder: String) throws -> String {
        let dir = share + "/server-made/" + folder
        var st = stat()
        try #require(lstat(dir, &st) == 0 || errno == EACCES, "Seed the share with scripts/volume-tests.sh")
        return dir
    }

    @Test func theShareIsMountedOverTheNetwork() throws {
        #expect(fileSystemType(of: share) == "smbfs")
        #expect(Volumes.detachableName(of: share) != nil)
    }

    /// Each file at what the server allocates for it, as the Mac reads it
    /// file by file, and no room for folders: `stat` over SMB gives each
    /// folder 16 KiB that no disk holds.
    @Test func aScanCountsWhatTheServerAllocatesAndNoFolderSpace() throws {
        let dir = try seeded("sizes")
        let expected = try allocatedFiles(under: dir)
        let r = StorageScanner.scan(path: dir)
        #expect(expected.count == 3 && r.root.fileCount == 3)
        #expect(r.root.size == expected.bytes)
        #expect(r.deniedPaths.isEmpty && r.loops.isEmpty && !r.cancelled)
    }

    @Test func copiesOnTheShareAreFoundAndSaidToBeOnADetachableDisk() throws {
        let dir = try seeded("copies")
        let listing = DuplicateFinder.find(in: [dir], minimum: 100_000, workers: 2)
        let group = try #require(listing.groups.first)
        #expect(listing.groups.count == 1 && listing.uncompared == 0)
        #expect(Set(group.files.map(\.path)) == [dir + "/one.bin", dir + "/two.bin"])
        #expect(group.files.allSatisfy { $0.detachable != nil })
    }

    @Test func caseTwinsAreNeverComparedAndAreReportedUnread() throws {
        let collide = try seeded("collide")
        let twins: Set<String> = [collide + "/photo.bin", collide + "/Photo.bin"]
        // Each twin has an exact copy beside it, so whichever file the Mac
        // opens by either name, an unguarded search finds a match for it.
        let listing = DuplicateFinder.find(in: [collide], minimum: 100_000, workers: 2)
        for group in listing.groups {
            #expect(twins.isDisjoint(with: group.files.map(\.path)), "A case twin was offered as a copy: \(group.files.map(\.path))")
        }
        #expect(twins.isSubset(of: listing.unreadable))
    }

    /// `loop/inner/back` links to `loop`, and Samba follows it: the Mac
    /// sees `loop/inner/back/inner/back/…` as real folders until the path
    /// is too long, with every file again at each level.
    @Test func aLinkBackUpThatTheServerFollowsIsWalkedOnce() throws {
        let dir = try seeded("loop")
        let real = try #require(try URL(fileURLWithPath: dir + "/inner/a.bin").resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize)
        let r = StorageScanner.scan(path: dir)
        #expect(r.loops == [dir + "/inner/back"])
        #expect(r.root.fileCount == 1 && r.root.size == Int64(real))
        let listing = DuplicateFinder.find(in: [dir], minimum: 100_000, workers: 2)
        #expect(listing.groups.isEmpty && listing.unreadable.isEmpty && listing.uncompared == 0)
    }

    @Test func aFolderTheGuestCantOpenIsReportedAndNotCounted() throws {
        let denied = try seeded("denied")
        let r = StorageScanner.scan(path: share + "/server-made")
        #expect(r.deniedPaths.contains(denied))
        #expect(r.root.find(path: denied)?.size == 0)
        let listing = DuplicateFinder.find(in: [share + "/server-made"], minimum: 100_000, workers: 2)
        #expect(listing.unreadable.contains(denied))
    }

    /// Names a Linux server keeps and Windows forbids: `:` `\` `*` `?` `|`,
    /// a trailing dot or space. Each is listed, counted and opened by the
    /// name it's listed under.
    @Test func namesWindowsForbidsAreListedCountedAndOpened() throws {
        let dir = try seeded("names")
        var names: [String] = []
        #expect(DirectoryReader.read(dir) { names.append($0.name) } == .ok)
        #expect(names.count == 7)
        for name in names {
            var st = stat()
            #expect(lstat(dir + "/" + name, &st) == 0 && st.st_size == 4096, "\(name)")
        }
        let r = StorageScanner.scan(path: dir)
        let expected = try allocatedFiles(under: dir)
        #expect(r.root.fileCount == 7 && r.deniedPaths.isEmpty)
        #expect(r.root.size == expected.bytes)
    }

    /// The real system Trash, on request (MYMOLE_REAL_TRASH=1, which the
    /// script sets): an SMB share has none, so the file stays where it is.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MYMOLE_REAL_TRASH"] == "1"))
    func theSystemTrashRefusesAShareWithoutOneAndLeavesTheFile() throws {
        let dir = try seeded("keep")
        let outcome = Trasher.move([dir + "/keep.bin"])
        #expect(outcome.moved.isEmpty && outcome.failed.count == 1)
        #expect(FileManager.default.fileExists(atPath: dir + "/keep.bin"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MYMOLE_REAL_TRASH"] == "1"))
    func aReadOnlyShareIsScannedAndNothingLeavesIt() throws {
        let ro = try #require(ProcessInfo.processInfo.environment["MYMOLE_SMB_READ_ONLY"])
        let r = StorageScanner.scan(path: ro)
        #expect(r.root.fileCount == 1 && r.deniedPaths.isEmpty)
        let outcome = Trasher.move([ro + "/fixed.bin"])
        #expect(outcome.moved.isEmpty && outcome.failed.count == 1)
        #expect(FileManager.default.fileExists(atPath: ro + "/fixed.bin"))
    }
}

/// A WebDAV share, served by this Mac's own Apache from a temporary folder
/// by `scripts/volume-tests.sh`. Its times are whole seconds and its file
/// numbers are the client's own; reading a file downloads it.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MYMOLE_WEBDAV_SHARE"] != nil))
struct WebDAVShareTests {
    let share = ProcessInfo.processInfo.environment["MYMOLE_WEBDAV_SHARE"] ?? ""

    @Test func theShareIsMountedOverTheNetwork() {
        #expect(fileSystemType(of: share) == "webdav")
        #expect(Volumes.detachableName(of: share) != nil)
    }

    @Test func aScanCountsEveryFile() throws {
        let expected = try allocatedFiles(under: share + "/copies")
        let r = StorageScanner.scan(path: share + "/copies")
        #expect(r.root.fileCount == 3 && expected.count == 3)
        #expect(r.root.size == expected.bytes)
        #expect(r.deniedPaths.isEmpty && r.loops.isEmpty)
    }

    @Test func copiesAreFoundAndSaidToBeOnADetachableDisk() throws {
        let dir = share + "/copies"
        let listing = DuplicateFinder.find(in: [dir], minimum: 100_000, workers: 2)
        let group = try #require(listing.groups.first)
        #expect(listing.groups.count == 1 && listing.uncompared == 0)
        #expect(Set(group.files.map(\.path)) == [dir + "/one.bin", dir + "/two.bin"])
        #expect(group.files.allSatisfy { $0.detachable != nil })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MYMOLE_REAL_TRASH"] == "1"))
    func theSystemTrashRefusesAShareWithoutOneAndLeavesTheFile() {
        let outcome = Trasher.move([share + "/keep/keep.bin"])
        #expect(outcome.moved.isEmpty && outcome.failed.count == 1)
        #expect(FileManager.default.fileExists(atPath: share + "/keep/keep.bin"))
    }
}

/// An NFSv4 export, served by the Linux kernel in a throwaway container by
/// `scripts/volume-tests.sh`. Unlike SMB, NFS gives the server's own file
/// numbers and link counts, shows links as links, and keeps names that
/// differ only by case apart, as the server does.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MYMOLE_NFS_SHARE"] != nil))
struct NFSShareTests {
    let share = ProcessInfo.processInfo.environment["MYMOLE_NFS_SHARE"] ?? ""

    @Test func theShareIsMountedOverTheNetwork() {
        #expect(fileSystemType(of: share) == "nfs")
        #expect(Volumes.detachableName(of: share) != nil)
    }

    /// `one-link.bin` is a second name of `one.bin`: its blocks count once.
    @Test func aScanCountsAFileWithTwoNamesOnce() throws {
        let dir = share + "/copies"
        var inodes = Set<UInt64>()
        var expected: Int64 = 0
        for name in ["one.bin", "one-link.bin", "two.bin", "other.bin"] {
            var st = stat()
            try #require(lstat(dir + "/" + name, &st) == 0)
            if inodes.insert(UInt64(st.st_ino)).inserted { expected += Int64(st.st_blocks) * 512 }
        }
        #expect(inodes.count == 3)
        let r = StorageScanner.scan(path: dir)
        #expect(r.root.fileCount == 3 && r.root.size == expected)
        #expect(r.deniedPaths.isEmpty && r.loops.isEmpty)
    }

    /// The copy with a second name frees nothing when it goes: the other
    /// name keeps its blocks.
    @Test func aCopyWithASecondNameIsSaidToFreeNothing() throws {
        let dir = share + "/copies"
        let listing = DuplicateFinder.find(in: [dir], minimum: 100_000, workers: 2)
        let group = try #require(listing.groups.first)
        #expect(listing.groups.count == 1 && listing.uncompared == 0)
        let paths = Set(group.files.map(\.path))
        #expect(paths.count == 2 && paths.contains(dir + "/two.bin"))
        let linked = try #require(paths.subtracting([dir + "/two.bin"]).first)
        #expect([dir + "/one.bin", dir + "/one-link.bin"].contains(linked))
        #expect(group.freed(going: [linked])[linked] == 0)
        #expect(group.freed(going: [dir + "/two.bin"])[dir + "/two.bin"] == group.bytes)
        #expect(group.files.allSatisfy { $0.detachable != nil })
    }

    @Test func aLinkBackUpIsShownAsALinkAndNotFollowed() throws {
        let dir = share + "/loop"
        var st = stat()
        #expect(lstat(dir + "/inner/back", &st) == 0 && st.st_mode & S_IFMT == S_IFLNK)
        let r = StorageScanner.scan(path: dir)
        #expect(r.root.fileCount == 1 && r.loops.isEmpty)
        #expect(DuplicateFinder.find(in: [dir], minimum: 100_000, workers: 2).groups.isEmpty)
    }

    /// NFS tells case apart, so `photo.bin` and `Photo.bin` are two files,
    /// each opened by its own name and compared like any others.
    @Test func namesDifferingOnlyByCaseAreTwoFiles() {
        let dir = share + "/collide"
        #expect(pathconf(dir, _PC_CASE_SENSITIVE) == 1)
        let listing = DuplicateFinder.find(in: [dir], minimum: 100_000, workers: 2)
        #expect(listing.unreadable.isEmpty)
        #expect(Set(listing.groups.map { Set($0.files.map(\.path)) }) == [
            [dir + "/photo.bin", dir + "/copy-of-lower.bin"], [dir + "/Photo.bin", dir + "/copy-of-upper.bin"],
        ])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MYMOLE_REAL_TRASH"] == "1"))
    func theSystemTrashRefusesAShareWithoutOneAndLeavesTheFile() {
        let outcome = Trasher.move([share + "/keep/keep.bin"])
        #expect(outcome.moved.isEmpty && outcome.failed.count == 1)
        #expect(FileManager.default.fileExists(atPath: share + "/keep/keep.bin"))
    }
}
