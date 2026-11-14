import Darwin
import Foundation
import Testing

@testable import StorageKit

/// Volume boundaries and the places on every disk that are never moved.
@Suite struct VolumeSafetyTests {
    @Test func aMountPointIsToldApartAlthoughItReportsItsParentsDevice() throws {
        // devfs is mounted on /dev on every Mac; the listing reads names only.
        var entries: [String: Entry] = [:]
        #expect(DirectoryReader.read("/") { entries[$0.name] = $0 } == .ok)
        let dev = try #require(entries["dev"])
        #expect(dev.kind == .folder && dev.isMountPoint)
        #expect(entries["usr"]?.isMountPoint == false)
    }

    @Test func aPlainFolderIsNoMountPointAndFilesKeepTheirSizes() throws {
        let box = try Sandbox()
        try box.file("a.bin", bytes: 50_000)
        try box.folder("sub")
        var entries: [String: Entry] = [:]
        #expect(DirectoryReader.read(box.path) { entries[$0.name] = $0 } == .ok)
        #expect(entries["sub"]?.kind == .folder && entries["sub"]?.isMountPoint == false)
        #expect(entries["a.bin"]?.allocated == box.allocated("a.bin"))
    }

    @Test func otherUsersHomesAndEveryDisksSystemFoldersAreProtected() {
        let home = "/Users/me"
        let shared = (home as NSString).deletingLastPathComponent + "/Shared"
        #expect(Trasher.isProtected("/Users/other/Downloads/a.bin", home: home))
        #expect(Trasher.isProtected("/Users/other", home: home))
        #expect(Trasher.isProtected(shared, home: home))
        #expect(!Trasher.isProtected(shared + "/Installers/a.dmg", home: home))
        #expect(!Trasher.isProtected(home + "/Downloads/a.bin", home: home))
        // A name that only begins like the owner's is someone else's.
        #expect(Trasher.isProtected(home + "2/a.bin", home: home))
        for p in [
            "/Volumes/Synthetic Disk/.Spotlight-V100", "/Volumes/Synthetic Disk/.fseventsd/0001",
            "/Volumes/Synthetic Disk/.DocumentRevisions-V100", "/Volumes/Synthetic Disk/.Trashes",
            "/Volumes/.timemachine/synthetic/2026-01-01.backup/a.bin",
            "/Volumes/com.apple.TimeMachine.localsnapshots/Backups.backupdb/a",
        ] {
            #expect(Trasher.isProtected(p, home: home), "\(p)")
        }
        #expect(!Trasher.isProtected("/Volumes/Synthetic Disk/Photos/a.jpg", home: home))
    }

    @Test func aDisksRootAndAReadOnlyDiskRefuseMoves() throws {
        // A disk's own root.
        #expect(Trasher.volumeRefuses("/dev"))
        // On the sealed system disk, which is mounted read-only.
        #expect(Trasher.volumeRefuses("/mymole-synthetic-missing"))
        let box = try Sandbox()
        try box.file("a.bin", bytes: 1_000)
        let real = try #require(Trasher.resolvingParent(box.path + "/a.bin"))
        #expect(!Trasher.volumeRefuses(real))
    }

    @Test func anItemWhoseDiskWentAwayIsSaidToBeGoneNotProtected() throws {
        let box = try Sandbox()
        let gate = TrashGate(still: { _ in true }, protections: TrashGate.keepsNothing)
        let cleared = Trasher.clear([box.path + "/Disconnected/a.bin"], through: gate)
        #expect(cleared.allowed.isEmpty && cleared.refused.map(\.reason) == ["No longer there"])
    }

    @Test func aProtectedFolderWrittenInAnotherCaseIsStillProtected() throws {
        let box = try Sandbox()
        try box.folder("Library/Keychains")
        try box.folder("Documents")
        // Only meaningful where the disk ignores case, as the startup disk does.
        var st = stat()
        guard lstat(box.path + "/library/keychains", &st) == 0 else { return }
        let home = try #require(Trasher.realPath(box.path))
        #expect(Trasher.isProtectedResolved(home + "/library/keychains", home: home))
        #expect(Trasher.isProtectedResolved(home + "/documents", home: home))
        #expect(Trasher.resolvingParent(home + "/library/keychains") == home + "/Library/Keychains")
        // A link is still judged by its own name, not what it points to.
        #expect(symlink(home + "/Library/Keychains", home + "/Documents/keys") == 0)
        #expect(Trasher.resolvingParent(home + "/documents/keys") == home + "/Documents/keys")
    }
}

@Suite struct RestoreWithoutExclusiveRenameTests {
    /// The path exFAT takes back from its Trash: a name already taken stays as it is.
    @Test func aNameIsClaimedBeforeTheMoveAndNeverOverwritten() throws {
        let box = try Sandbox()
        try box.file("trash/a.bin", bytes: 1_000)
        try box.file("trash/b", bytes: 1_000)
        try box.folder("trash/folder/inside")
        try box.file("home/b", bytes: 10)
        let dir = open(box.path + "/home", O_RDONLY | O_DIRECTORY)
        #expect(dir >= 0)
        defer { close(dir) }
        #expect(Trasher.renameClaimingName(box.path + "/trash/a.bin", into: dir, "a.bin"))
        #expect(box.allocated("home/a.bin") > 0 && Trasher.identity(of: box.path + "/trash/a.bin") == nil)
        #expect(Trasher.renameClaimingName(box.path + "/trash/folder", into: dir, "folder"))
        #expect(Trasher.identity(of: box.path + "/home/folder/inside")?.type == S_IFDIR)
        // Taken: nothing moves, and what was there is untouched.
        #expect(!Trasher.renameClaimingName(box.path + "/trash/b", into: dir, "b"))
        #expect(try Data(contentsOf: box.url.appending(path: "home/b")).count == 10)
        #expect(Trasher.identity(of: box.path + "/trash/b") != nil)
    }
}

@Suite struct DuplicateIdentityTests {
    @Test func aCopyWithAnotherNameOutsideTheSearchFreesNothing() throws {
        let box = try Sandbox()
        try box.file("Library/a.bin", bytes: 300_000)
        try FileManager.default.createDirectory(at: box.url.appending(path: "Documents"), withIntermediateDirectories: true)
        #expect(link(box.path + "/Library/a.bin", box.path + "/Documents/a.bin") == 0)
        try FileManager.default.createDirectory(at: box.url.appending(path: "Downloads"), withIntermediateDirectories: true)
        try Data(contentsOf: box.url.appending(path: "Library/a.bin")).write(to: box.url.appending(path: "Downloads/a.bin"))
        let roots = [box.path + "/Documents", box.path + "/Downloads"]
        let g = try #require(DuplicateFinder.find(in: roots, minimum: 100_000, workers: 1).groups.first)
        let linked = box.path + "/Documents/a.bin", copy = box.path + "/Downloads/a.bin"
        #expect(g.files.count == 2)
        #expect(g.freed(going: [linked]) == [linked: 0])
        #expect(g.sharedOutside(linked) == 0)
        #expect(g.freed(going: [copy]) == [copy: g.bytes])
        #expect(g.spare == g.bytes)
    }

    @Test func copiesInsideLibrariesAndPlugInsAreLeftAlone() throws {
        let box = try Sandbox()
        try box.file("Pictures/a.jpg", bytes: 200_000)
        for package in ["Catalog Previews.lrdata", "Tool.appex", "App.dSYM"] {
            try FileManager.default.createDirectory(at: box.url.appending(path: "Pictures/" + package), withIntermediateDirectories: true)
            try Data(contentsOf: box.url.appending(path: "Pictures/a.jpg")).write(to: box.url.appending(path: "Pictures/\(package)/a.jpg"))
        }
        #expect(DuplicateFinder.find(in: [box.path], minimum: 100_000, workers: 1).groups.isEmpty)
    }

    @Test func aPackageTypeOutsideTheListOrAFolderMarkedAsABundleIsOneThing() throws {
        let box = try Sandbox()
        try box.file("Documents/a.bin", bytes: 200_000)
        // A script bundle is declared as a package by macOS itself.
        let marked = box.path + "/Documents/Marked"
        for folder in ["Documents/Tool.scptd", "Documents/Marked"] {
            try FileManager.default.createDirectory(at: box.url.appending(path: folder), withIntermediateDirectories: true)
            try Data(contentsOf: box.url.appending(path: "Documents/a.bin")).write(to: box.url.appending(path: folder + "/a.bin"))
        }
        var info = [UInt8](repeating: 0, count: 32)
        info[8] = 0x20  // kHasBundle, big-endian folder flags
        #expect(setxattr(marked, "com.apple.FinderInfo", info, info.count, 0, 0) == 0)
        #expect(DuplicateFinder.isPackage(box.path + "/Documents/Tool.scptd") && DuplicateFinder.isPackage(marked))
        #expect(!DuplicateFinder.isPackage(box.path + "/Documents"))
        #expect(DuplicateFinder.find(in: [box.path], minimum: 100_000, workers: 1).groups.isEmpty)
        // Chosen as a root, a package is still one thing.
        #expect(DuplicateFinder.find(in: [marked], minimum: 100_000, workers: 1).excluded == [marked])
    }

    @Test func finderTagsAreReadWithEachCopy() throws {
        let box = try Sandbox()
        try box.file("Documents/a.bin", bytes: 200_000)
        try Data(contentsOf: box.url.appending(path: "Documents/a.bin")).write(to: box.url.appending(path: "Downloads.bin"))
        var tagged = box.url.appending(path: "Documents/a.bin")
        var values = URLResourceValues()
        values.tagNames = ["Synthetic Blue", "Synthetic Red"]
        try tagged.setResourceValues(values)
        let g = try #require(DuplicateFinder.find(in: [box.path], minimum: 100_000, workers: 1).groups.first)
        #expect(g.files.first { $0.name == "a.bin" }?.tags == ["Synthetic Blue", "Synthetic Red"])
        #expect(g.tagsDiffer)
        #expect(g.tagsLost(going: [tagged.path]) == ["Synthetic Blue", "Synthetic Red"])
        #expect(g.tagsLost(going: [box.path + "/Downloads.bin"]).isEmpty)
        #expect(g.files.allSatisfy { $0.detachable == nil })
    }

    @Test func emptyFilesAreNeverDuplicates() throws {
        let box = try Sandbox()
        for name in ["a.txt", "b.txt", "c.txt"] {
            #expect(FileManager.default.createFile(atPath: box.path + "/" + name, contents: Data()))
        }
        #expect(DuplicateFinder.find(in: [box.path], minimum: 0, workers: 1).groups.isEmpty)
    }

    @Test func readingWithoutDownloadsRestoresTheThreadsPolicy() {
        let type = IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES
        let before = getiopolicy_np(type, IOPOL_SCOPE_THREAD)
        let inside = FileSpace.withoutDownloading { getiopolicy_np(type, IOPOL_SCOPE_THREAD) }
        #expect(inside == IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        #expect(getiopolicy_np(type, IOPOL_SCOPE_THREAD) == before)
    }
}

/// A disk without a Trash, stood in for: the system says it can't, and the
/// item stays where it is.
@Suite struct NoTrashVolumeTests {
    private final class Calls: @unchecked Sendable {
        var count = 0
    }

    @Test(arguments: [true, false]) func anItemOnADiskWithoutATrashStaysAndIsNeverDeleted(_ unsupported: Bool) throws {
        let box = try Sandbox()
        let url = try box.file("share/report.bin", bytes: 4_000)
        let calls = Calls()
        let trash = SystemTrash(
            trashItem: { _ in
                calls.count += 1
                throw unsupported ? NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)
                    : NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError)
            },
            isLocal: { _ in unsupported ? nil : false })
        guard case .failure(let failure) = trash.move(url) else { Issue.record("moved"); return }
        #expect(failure.reason == SystemTrash.noTrash && failure.error != nil)
        #expect(calls.count == 1)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func anotherFailureOnALocalDiskKeepsItsOwnReason() throws {
        let box = try Sandbox()
        let url = try box.file("a.bin", bytes: 1_000)
        let trash = SystemTrash(trashItem: { _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)) }, isLocal: { _ in true })
        guard case .failure(let failure) = trash.move(url) else { Issue.record("moved"); return }
        #expect(failure.reason != SystemTrash.noTrash)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}

/// A cloud file that isn't downloaded, stood in for by its flag: never
/// listed, read, counted as space or taken for the copy it was.
@Suite struct EvictedFileTests {
    @Test func theDatalessFlagMeansNoContentHere() {
        var st = stat()
        st.st_blocks = 2_048
        #expect(DuplicateFinder.holdsContent(st) && DirectoryReader.allocated(st) == 2_048 * 512)
        st.st_flags |= UInt32(SF_DATALESS)
        #expect(!DuplicateFinder.holdsContent(st) && DirectoryReader.allocated(st) == 0)
    }

    @Test func anEvictedCopyIsNeverListedHashedOrPassedBeforeAMove() throws {
        let box = try Sandbox()
        try box.file("Documents/a.bin", bytes: 300_000)
        try Data(contentsOf: box.url.appending(path: "Documents/a.bin")).write(to: box.url.appending(path: "Documents/b.bin"))
        let evicted = try #require(Trasher.identity(of: box.path + "/Documents/b.bin")).inode
        func holds(_ st: stat) -> Bool { st.st_ino != evicted && DuplicateFinder.holdsContent(st) }
        var seen = Set<DuplicateFinder.FileID>(), unreadable: [String] = [], listed: [String] = []
        DuplicateFinder.walk(box.path, minimum: 1, progress: ScanProgress(), seen: &seen, unreadable: &unreadable, holdsContent: holds) {
            listed.append(($0.path as NSString).lastPathComponent)
        }
        #expect(listed == ["a.bin"])
        // Found while downloaded, evicted before the move: the check right before it refuses.
        let g = try #require(DuplicateFinder.find(in: [box.path], minimum: 1, workers: 1).groups.first)
        let file = try #require(g.files.first { $0.name == "b.bin" })
        #expect(DuplicateFinder.isUnchanged(file, length: g.length, holdsContent: DuplicateFinder.holdsContent))
        #expect(!DuplicateFinder.isUnchanged(file, length: g.length, holdsContent: holds))
    }
}
