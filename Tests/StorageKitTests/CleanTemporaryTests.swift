import Darwin
import Foundation
import Testing

@testable import StorageKit

/// Temporary folders lie outside the home folder and hold what running
/// programs work with: only what its owner has left alone is offered.
@Suite struct CleanTemporaryTests {
    private static let big = 2 << 20

    /// Sets when each path, and every folder given, was last changed.
    private func age(_ box: Sandbox, _ paths: [String], days: Double) throws {
        let date = Date().addingTimeInterval(-days * 86_400)
        for path in paths { try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: box.path + "/" + path) }
    }

    private func roots(_ box: Sandbox) throws -> (home: String, temp: String) {
        let real = try #require(Trasher.realPath(box.path))
        try box.folder("home/Library")
        try box.folder("temp")
        return (real + "/home", real + "/temp")
    }

    @Test func onlyWhatWasLeftAloneForDaysIsOfferedAndNoneIsSafe() throws {
        let box = try Sandbox()
        let (home, temp) = try roots(box)
        try box.file("temp/old-build/out/a.bin", bytes: Self.big)
        try box.file("temp/old-file.log", bytes: Self.big)
        try box.file("temp/old-but-small/a.bin", bytes: 8_192)
        try box.file("temp/fresh-work/a.bin", bytes: Self.big)
        try box.file("temp/old-outside-new-inside/deep/a.bin", bytes: Self.big)
        try box.file("temp/com.apple.launchd.synthetic/state.bin", bytes: Self.big)
        try box.file("temp/.hidden/a.bin", bytes: Self.big)
        try box.file("temp/TemporaryItems/a.bin", bytes: Self.big)
        try box.file("elsewhere/a.bin", bytes: 8_192)
        try FileManager.default.createSymbolicLink(atPath: temp + "/linked", withDestinationPath: box.path + "/elsewhere")
        try age(box, ["temp/old-build/out/a.bin", "temp/old-build/out", "temp/old-build", "temp/old-file.log",
                      "temp/old-but-small/a.bin", "temp/old-but-small",
                      "temp/old-outside-new-inside/deep", "temp/old-outside-new-inside",
                      "temp/com.apple.launchd.synthetic/state.bin", "temp/com.apple.launchd.synthetic",
                      "temp/.hidden/a.bin", "temp/.hidden", "temp/TemporaryItems/a.bin", "temp/TemporaryItems"], days: 5)

        let found = CleanScanner.temporary(in: [temp], workers: 1, inUse: [])
        #expect(found.candidates.map(\.name).sorted() == ["old-build", "old-file.log"])
        #expect(found.candidates.allSatisfy { $0.category == .temporary && $0.safety == .review && $0.bytes >= CleanRules.temporaryMinimum && !$0.contentsOnly })
        // What's there but still in use is counted, so the list doesn't read as everything.
        #expect(found.inUseBytes >= Int64(2 * Self.big))
        // The scan of the home folder never looks there.
        #expect(CleanScanner.list(home: home, workers: 1).candidates.isEmpty)

        for c in found.candidates { #expect(CleanScanner.isStillCandidate(c.path, home: home, temporary: [temp])) }
        for name in ["fresh-work", "old-outside-new-inside", "com.apple.launchd.synthetic", ".hidden", "TemporaryItems", "linked", "gone"] {
            #expect(!CleanScanner.isStillCandidate(temp + "/" + name, home: home, temporary: [temp]), "\(name)")
        }
        // Only in a folder that was named, and never the folder itself.
        #expect(!CleanScanner.isStillCandidate(temp + "/old-build", home: home))
        #expect(!CleanScanner.isStillCandidate(temp, home: home, temporary: [temp]))
    }

    /// A tool keeps a folder for itself, in it one per project and in that
    /// one per run. The runs that ended are offered each on its own; the
    /// folders above them, where another run is under way, never are.
    @Test func runsThatEndedAreFoundBelowAToolsOwnFolder() throws {
        let box = try Sandbox()
        let (home, temp) = try roots(box)
        try box.file("temp/tool-501/project/run-ended/work/a.bin", bytes: Self.big)
        try box.file("temp/tool-501/project/run-live/work/a.bin", bytes: Self.big)
        try box.file("temp/tool-501/project/run-live/work/deep/old/a.bin", bytes: Self.big)
        try age(box, ["temp/tool-501/project/run-ended/work/a.bin", "temp/tool-501/project/run-ended/work", "temp/tool-501/project/run-ended",
                      "temp/tool-501/project/run-live/work/deep/old/a.bin", "temp/tool-501/project/run-live/work/deep/old"], days: 6)
        let ended = temp + "/tool-501/project/run-ended"

        let known = CleanScanner.temporary(in: [temp], workers: 1, inUse: [])
        #expect(known.candidates.map(\.path) == [ended])
        #expect(known.inUseBytes >= Int64(2 * Self.big))
        #expect(CleanScanner.isStillCandidate(ended, home: home, temporary: [temp], inUse: []))
        // No deeper than the look goes, however long that part was left.
        #expect(!CleanScanner.isStillCandidate(temp + "/tool-501/project/run-live/work/deep/old", home: home, temporary: [temp]))

        // A program standing in it, or with a file of it open, is using it.
        for at in [ended, ended + "/work", ended + "/work/a.bin"] {
            #expect(CleanScanner.temporary(in: [temp], workers: 1, inUse: [at]).candidates.isEmpty, "\(at)")
            #expect(!CleanScanner.isStillCandidate(ended, home: home, temporary: [temp], inUse: [at]))
        }
        // One at work in the tool's folder itself uses all of it.
        #expect(CleanScanner.temporary(in: [temp], workers: 1, inUse: [temp + "/tool-501"]).candidates.isEmpty)
        // Where the programs can't be asked, only age speaks: nothing below a folder in use is told apart.
        let unknown = CleanScanner.temporary(in: [temp], workers: 1, inUse: nil)
        #expect(unknown.candidates.isEmpty && unknown.inUseBytes >= Int64(3 * Self.big))
        // A name beside it that only begins the same isn't inside it.
        #expect(!ProcessPaths.uses(ended, among: [ended + "-other/work"]) && ProcessPaths.uses(ended, among: [ended]))
    }

    @Test func aProgramComingBackToItTakesItOffTheList() throws {
        let box = try Sandbox()
        let (home, temp) = try roots(box)
        try box.file("temp/session/work/a.bin", bytes: Self.big)
        try age(box, ["temp/session/work/a.bin", "temp/session/work", "temp/session"], days: 4)
        let path = temp + "/session"
        #expect(CleanScanner.isStillCandidate(path, home: home, temporary: [temp]))
        // Written deep inside since the scan: its own date says nothing, the look through it does.
        try Data("more".utf8).write(to: URL(fileURLWithPath: path + "/work/a.bin"))
        try age(box, ["temp/session/work", "temp/session"], days: 4)
        #expect(!CleanScanner.isStillCandidate(path, home: home, temporary: [temp]))
    }

    @Test func anotherUsersAndTooRecentItemsAreNeverOffered() throws {
        let box = try Sandbox()
        try box.file("temp/theirs/a.bin", bytes: 8_192)
        let path = box.path + "/temp/theirs"
        let old = Date().addingTimeInterval(-5 * 86_400)
        try age(box, ["temp/theirs"], days: 5)
        #expect(CleanRules.offersTemporary(path, changed: old))
        #expect(!CleanRules.offersTemporary(path, changed: old, owner: getuid() + 1))
        #expect(!CleanRules.temporaryFolder(path, owner: getuid() + 1) && CleanRules.temporaryFolder(path))
        #expect(!CleanRules.offersTemporary(path, changed: Date().addingTimeInterval(-2 * 86_400), quiet: 3 * 86_400))
        // One day left alone is enough when that's what Settings says.
        #expect(CleanRules.offersTemporary(path, changed: Date().addingTimeInterval(-2 * 86_400), quiet: CleanRules.temporaryQuiet(days: 1)))
        // Three days to the hour, from whichever moment is asked about.
        #expect(!CleanRules.offersTemporary(path, changed: old, now: old.addingTimeInterval(CleanRules.temporaryQuiet(days: 3) - 1), quiet: CleanRules.temporaryQuiet(days: 3)))
    }

    /// Copies made as clones take their blocks once: what the list says an
    /// item frees is what moving it frees, not every copy's length added up.
    @Test func clonesAreCountedOnce() throws {
        let box = try Sandbox()
        let (_, temp) = try roots(box)
        let first = try box.file("temp/mock/blob-0.bin", bytes: Self.big)
        for i in 1..<6 { try FileManager.default.copyItem(at: first, to: box.url.appending(path: "temp/mock/blob-\(i).bin")) }
        try age(box, (0..<6).map { "temp/mock/blob-\($0).bin" } + ["temp/mock"], days: 5)
        let total = (0..<6).reduce(Int64(0)) { $0 + box.allocated("temp/mock/blob-\($1).bin") }
        let found = try #require(CleanScanner.temporary(in: [temp], workers: 1, inUse: []).candidates.first { $0.name == "mock" })
        #expect(found.bytes <= total)
        // On a disk that clones a copy, the six take the room of about one.
        if FileSpace.sharing(first.path)?.cloneID != nil { #expect(found.bytes < total / 3, "\(found.bytes) of \(total)") }
    }

    /// A file at the top of a temporary folder is held to the same rules
    /// as a folder there: this user's own, and worth a row by what moving
    /// it frees.
    @Test func aFileAtTheTopFollowsTheFoldersRules() throws {
        let box = try Sandbox()
        let (_, temp) = try roots(box)
        let kept = try box.file("elsewhere/original.bin", bytes: Self.big)
        try FileManager.default.copyItem(at: kept, to: box.url.appending(path: "temp/copy.bin"))
        try box.file("temp/alone.bin", bytes: Self.big)
        try age(box, ["temp/copy.bin", "temp/alone.bin"], days: 5)
        let found = CleanScanner.temporary(in: [temp], workers: 1, inUse: [])
        #expect(found.candidates.contains { $0.name == "alone.bin" && $0.bytes >= CleanRules.temporaryMinimum })
        // On a disk that clones a copy, the copy shares its blocks with the
        // file kept elsewhere: moving it frees next to nothing, so it's no row.
        if FileSpace.sharing(temp + "/copy.bin")?.cloneID != nil {
            #expect(!found.candidates.contains { $0.name == "copy.bin" })
        }
        #expect(found.candidates.allSatisfy { $0.bytes >= CleanRules.temporaryMinimum })
        let path = temp + "/alone.bin"
        #expect(CleanRules.temporaryFile(path) && !CleanRules.temporaryFile(path, owner: getuid() + 1))
        #expect(!CleanRules.temporaryFile(temp))
    }

    /// A file this test holds open is among what the programs have open.
    @Test func whatAProgramHasOpenIsRead() throws {
        let box = try Sandbox()
        let file = try box.file("held/open.bin", bytes: 16)
        let real = try #require(Trasher.realPath(file.path))
        let fd = open(real, O_RDONLY)
        try #require(fd >= 0)
        defer { close(fd) }
        let all = try #require(ProcessPaths.inUse(excluding: -1))
        #expect(all.contains(real))
        #expect(ProcessPaths.uses((real as NSString).deletingLastPathComponent, among: all))
        // Asked for many folders, it's one lookup each: the paths and all above them.
        let above = ProcessPaths.foldersInUse(["/synthetic/tool/run/out.log", "/synthetic/tool/other"])
        #expect(above == ["/synthetic/tool/run/out.log", "/synthetic/tool/run", "/synthetic/tool", "/synthetic", "/synthetic/tool/other"])
        #expect(!above.contains("/synthetic/tool/ru") && !above.contains("/"))
        // This program itself is left out when asked to be.
        #expect(ProcessPaths.inUse()?.contains(real) == false)
    }

    /// Days come from Settings, three when nothing is saved, and stay within 0 to 90.
    @Test func theDaysAreASetting() {
        #expect(CleanRules.temporaryDays(saved: nil) == 3 && CleanRules.temporaryDays(saved: 0) == 0 && CleanRules.temporaryDays(saved: 10) == 10)
        #expect(CleanRules.temporaryDays(saved: 500) == 90 && CleanRules.temporaryDays(saved: -4) == 0)
        #expect(CleanRules.temporaryQuiet(days: 0) == 0)
        #expect(CleanRules.temporaryQuiet(days: 2) == 172_800)
    }
}
