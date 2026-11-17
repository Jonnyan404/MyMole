import Darwin
import Foundation
import SynchronizationCompat
import Testing

@testable import StorageKit

/// Disk images standing in for USB sticks and external disks, made,
/// attached and removed by `scripts/volume-tests.sh`: exFAT, FAT32, APFS,
/// Mac OS Extended and its case-sensitive form, one attached read-only and one ejected
/// while it's scanned. Moves go to each disk's own Trash folder, never the
/// user's.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MYMOLE_DISK_EXFAT"] != nil))
struct RemovableDiskTests {
    static let environment = ProcessInfo.processInfo.environment
    /// exFAT and FAT32 keep a file's extra attributes in a `._` file beside
    /// it; Mac OS Extended keeps them in the file.
    static let writable: [(kind: String, path: String)] = [
        ("exfat", environment["MYMOLE_DISK_EXFAT"]), ("msdos", environment["MYMOLE_DISK_FAT32"]),
        ("hfs", environment["MYMOLE_DISK_CASE_SENSITIVE"]), ("apfs", environment["MYMOLE_DISK_APFS"]),
        ("hfs", environment["MYMOLE_DISK_HFS"]),
    ].compactMap { kind, path in path.map { (kind, $0) } }

    /// A folder of this test's own on the disk at `root`.
    func workspace(on root: String) throws -> String {
        let dir = root + "/" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir + "/sub", withIntermediateDirectories: true)
        return dir
    }

    /// Every regular file under `dir`, hidden ones included, as `readdir`
    /// and `lstat` see them: Foundation's enumerator leaves out the `._`
    /// files, and on a local disk `stat` gives the allocation exactly.
    func filesOnDisk(under dir: String) -> (count: Int, bytes: Int64) {
        var count = 0
        var bytes: Int64 = 0
        var stack = [dir]
        while let folder = stack.popLast(), let d = opendir(folder) {
            defer { closedir(d) }
            while let e = readdir(d) {
                let name = withUnsafeBytes(of: e.pointee.d_name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
                guard name != ".", name != ".." else { continue }
                var st = stat()
                guard lstat(folder + "/" + name, &st) == 0 else { continue }
                switch st.st_mode & S_IFMT {
                case S_IFDIR: stack.append(folder + "/" + name)
                case S_IFREG: count += 1; bytes += Int64(st.st_blocks) * 512
                default: continue
                }
            }
        }
        return (count, bytes)
    }

    func write(_ path: String, bytes: Int, seed: UInt8) throws {
        try Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) }).write(to: URL(fileURLWithPath: path))
    }

    @Test func eachDiskIsTheKindItsMadeAsAndCanBeDisconnected() throws {
        #expect(Self.writable.count == 5)
        for disk in Self.writable {
            #expect(fileSystemType(of: disk.path) == disk.kind, "\(disk.path)")
            #expect(Volumes.detachableName(of: disk.path) != nil, "\(disk.kind)")
        }
    }

    @Test func copiesAreFoundOnEachDiskAndSaidToBeOnADetachableOne() throws {
        for disk in Self.writable {
            let dir = try workspace(on: disk.path)
            try write(dir + "/a.bin", bytes: 300_000, seed: 1)
            try write(dir + "/sub/a-copy.bin", bytes: 300_000, seed: 1)
            try write(dir + "/other.bin", bytes: 300_000, seed: 2)
            let listing = DuplicateFinder.find(in: [dir], minimum: 100_000, workers: 2)
            let group = try #require(listing.groups.first, "\(disk.kind)")
            #expect(listing.groups.count == 1 && listing.uncompared == 0 && listing.unreadable.isEmpty, "\(disk.kind)")
            #expect(Set(group.files.map(\.path)) == [dir + "/a.bin", dir + "/sub/a-copy.bin"], "\(disk.kind)")
            #expect(group.files.allSatisfy { $0.detachable != nil }, "\(disk.kind)")
        }
    }

    /// The `._` files exFAT and FAT32 keep for a file's attributes take
    /// room of their own, and are counted.
    @Test func aScanCountsEveryFileOnEachDiskAttributeFilesIncluded() throws {
        for disk in Self.writable {
            let dir = try workspace(on: disk.path)
            try write(dir + "/a.bin", bytes: 300_000, seed: 3)
            try write(dir + "/sub/b.bin", bytes: 700_000, seed: 4)
            #expect(setxattr(dir + "/a.bin", "com.example.mymole-test", "v", 1, 0, 0) == 0)
            let expected = filesOnDisk(under: dir)
            let r = StorageScanner.scan(path: dir)
            #expect(r.root.fileCount == expected.count && r.root.size == expected.bytes, "\(disk.kind)")
            #expect(["hfs", "apfs"].contains(disk.kind) ? expected.count == 2 : expected.count > 2, "\(disk.kind): \(expected.count)")
            #expect(r.deniedPaths.isEmpty, "\(disk.kind)")
        }
    }

    /// The app's own move and its Undo, through the real Trash: on these
    /// disks it's a folder of the disk's own. exFAT has no exclusive
    /// rename, so putting back claims the name first.
    @Test(.enabled(if: environment["MYMOLE_REAL_TRASH"] == "1"))
    func aFileGoesToTheDisksOwnTrashAndComesBackWithItsAttributes() throws {
        for disk in Self.writable {
            let dir = try workspace(on: disk.path)
            let file = dir + "/sub/going.bin"
            try write(file, bytes: 120_000, seed: 5)
            #expect(setxattr(file, "com.example.mymole-test", "kept", 4, 0, 0) == 0)
            let original = try Data(contentsOf: URL(fileURLWithPath: file))
            let out = Trasher.move([file])
            let record = try #require(out.moved.first, "\(disk.kind): \(out.failed)")
            #expect(record.trashed.path.hasPrefix(disk.path + "/.Trashes/"), "\(disk.kind): \(record.trashed.path)")
            #expect(!FileManager.default.fileExists(atPath: file))
            #expect(Trasher.restore(out.moved).isEmpty, "\(disk.kind)")
            #expect(try Data(contentsOf: URL(fileURLWithPath: file)) == original, "\(disk.kind)")
            var value = [UInt8](repeating: 0, count: 8)
            #expect(getxattr(file, "com.example.mymole-test", &value, value.count, 0, 0) == 4, "\(disk.kind)")
            #expect(!FileManager.default.fileExists(atPath: record.trashed.path), "\(disk.kind)")
        }
    }

    /// On a disk that tells case apart, `t.bin` and `T.bin` are two files,
    /// each opened by its own name, and compared like any others.
    @Test func namesDifferingOnlyByCaseAreTwoFilesWhereTheDiskTellsCaseApart() throws {
        let root = try #require(Self.environment["MYMOLE_DISK_CASE_SENSITIVE"])
        let dir = try workspace(on: root)
        try write(dir + "/t.bin", bytes: 200_000, seed: 6)
        try write(dir + "/T.bin", bytes: 200_000, seed: 7)
        try write(dir + "/sub/t-copy.bin", bytes: 200_000, seed: 6)
        try write(dir + "/sub/T-copy.bin", bytes: 200_000, seed: 7)
        let listing = DuplicateFinder.find(in: [dir], minimum: 100_000, workers: 2)
        #expect(listing.unreadable.isEmpty)
        #expect(Set(listing.groups.map { Set($0.files.map(\.path)) }) == [
            [dir + "/t.bin", dir + "/sub/t-copy.bin"], [dir + "/T.bin", dir + "/sub/T-copy.bin"],
        ])
    }

    /// An external APFS disk shares a clone's blocks with its original:
    /// the clone is found as a copy, and moving it alone frees next to nothing.
    @Test func aCloneOnAnExternalAPFSDiskIsACopyThatFreesNothingAlone() throws {
        let root = try #require(Self.environment["MYMOLE_DISK_APFS"])
        let dir = try workspace(on: root)
        try write(dir + "/a.bin", bytes: 400_000, seed: 8)
        #expect(clonefile(dir + "/a.bin", dir + "/sub/a-clone.bin", 0) == 0)
        let listing = DuplicateFinder.find(in: [dir], minimum: 100_000, workers: 2)
        let group = try #require(listing.groups.first)
        #expect(Set(group.files.map(\.path)) == [dir + "/a.bin", dir + "/sub/a-clone.bin"])
        #expect(group.clones(of: dir + "/a.bin") == 1)
        let alone = try #require(group.freed(going: [dir + "/sub/a-clone.bin"])[dir + "/sub/a-clone.bin"])
        #expect(alone < group.bytes / 10)
    }

    @Test(.enabled(if: environment["MYMOLE_REAL_TRASH"] == "1"))
    func aReadOnlyDiskIsScannedAndNothingLeavesIt() throws {
        let ro = try #require(Self.environment["MYMOLE_DISK_READ_ONLY"])
        let r = StorageScanner.scan(path: ro)
        #expect(r.root.fileCount >= 1 && !r.cancelled)
        #expect(Trasher.volumeRefuses(ro + "/fixed.bin"))
        let outcome = Trasher.move([ro + "/fixed.bin"])
        #expect(outcome.moved.isEmpty && outcome.failed.count == 1)
        #expect(FileManager.default.fileExists(atPath: ro + "/fixed.bin"))
    }

    /// The disk goes as soon as the first of its folders is read: the scan
    /// still ends, saying what it couldn't read.
    @Test func aDiskEjectedMidScanEndsTheScanWithWhatItRead() throws {
        let root = try #require(Self.environment["MYMOLE_DISK_EJECT"])
        final class Once: Sendable { let fired = Atomic<Bool>(false) }
        let eject = Once()
        let r = StorageScanner.scan(path: root, workers: 1, onSubtree: { _ in
            guard !eject.fired.exchange(true, ordering: .relaxed) else { return }
            let detach = Process()
            detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            detach.arguments = ["detach", "-quiet", "-force", root]
            try? detach.run()
            detach.waitUntilExit()
        })
        let ejected = eject.fired.load(ordering: .relaxed)
        #expect(ejected)
        #expect(!r.cancelled)
        #expect(!r.deniedPaths.isEmpty)
        #expect(r.root.subfolders.count >= 400)
        #expect(Volumes.detachableName(of: root) == nil)
    }
}
