import Darwin
import Foundation
import Testing

@testable import StorageKit

/// Temporary folders lie outside the home folder and hold what running
/// programs work with: only what its owner has left alone is offered.
@Suite struct CleanTemporaryTests {
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
        try box.file("temp/old-build/out/a.bin", bytes: 8_192)
        try box.file("temp/old-file.log", bytes: 8_192)
        try box.file("temp/fresh-work/a.bin", bytes: 8_192)
        try box.file("temp/old-outside-new-inside/deep/a.bin", bytes: 8_192)
        try box.file("temp/com.apple.launchd.synthetic/state.bin", bytes: 8_192)
        try box.file("temp/.hidden/a.bin", bytes: 8_192)
        try box.file("temp/TemporaryItems/a.bin", bytes: 8_192)
        try box.file("elsewhere/a.bin", bytes: 8_192)
        try FileManager.default.createSymbolicLink(atPath: temp + "/linked", withDestinationPath: box.path + "/elsewhere")
        try age(box, ["temp/old-build/out/a.bin", "temp/old-build/out", "temp/old-build", "temp/old-file.log",
                      "temp/old-outside-new-inside/deep", "temp/old-outside-new-inside",
                      "temp/com.apple.launchd.synthetic/state.bin", "temp/com.apple.launchd.synthetic",
                      "temp/.hidden/a.bin", "temp/.hidden", "temp/TemporaryItems/a.bin", "temp/TemporaryItems"], days: 5)

        let found = CleanScanner.list(home: home, workers: 1, temporary: [temp]).candidates.filter { $0.category == .temporary }
        #expect(found.map(\.name).sorted() == ["old-build", "old-file.log"])
        #expect(found.allSatisfy { $0.safety == .review && $0.bytes > 0 && !$0.contentsOnly })
        // Not looked in unless asked to.
        #expect(CleanScanner.list(home: home, workers: 1).candidates.isEmpty)

        for c in found { #expect(CleanScanner.isStillCandidate(c.path, home: home, temporary: [temp])) }
        for name in ["fresh-work", "old-outside-new-inside", "com.apple.launchd.synthetic", ".hidden", "TemporaryItems", "linked", "gone"] {
            #expect(!CleanScanner.isStillCandidate(temp + "/" + name, home: home, temporary: [temp]), "\(name)")
        }
        // Only straight inside a folder that was named, and never the folder itself.
        #expect(!CleanScanner.isStillCandidate(temp + "/old-build", home: home))
        #expect(!CleanScanner.isStillCandidate(temp + "/old-build/out", home: home, temporary: [temp]))
        #expect(!CleanScanner.isStillCandidate(temp, home: home, temporary: [temp]))
    }

    @Test func aProgramComingBackToItTakesItOffTheList() throws {
        let box = try Sandbox()
        let (home, temp) = try roots(box)
        try box.file("temp/session/work/a.bin", bytes: 8_192)
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
        #expect(!CleanRules.offersTemporary(path, changed: Date().addingTimeInterval(-2 * 86_400)))
        // Three days to the hour, from whichever moment is asked about.
        #expect(!CleanRules.offersTemporary(path, changed: old, now: old.addingTimeInterval(CleanRules.temporaryQuiet - 1)))
    }

    /// Copies made as clones take their blocks once: what the list says an
    /// item frees is what moving it frees, not every copy's length added up.
    @Test func clonesAreCountedOnce() throws {
        let box = try Sandbox()
        let (home, temp) = try roots(box)
        let first = try box.file("temp/mock/blob-0.bin", bytes: 1 << 20)
        for i in 1..<6 { try FileManager.default.copyItem(at: first, to: box.url.appending(path: "temp/mock/blob-\(i).bin")) }
        try age(box, (0..<6).map { "temp/mock/blob-\($0).bin" } + ["temp/mock"], days: 5)
        let total = (0..<6).reduce(Int64(0)) { $0 + box.allocated("temp/mock/blob-\($1).bin") }
        let found = try #require(CleanScanner.list(home: home, workers: 1, temporary: [temp]).candidates.first { $0.name == "mock" })
        #expect(found.bytes <= total)
        // On a disk that clones a copy, the six take the room of about one.
        if FileSpace.sharing(at: AT_FDCWD, first.path)?.cloneID != nil { #expect(found.bytes < total / 3, "\(found.bytes) of \(total)") }
    }
}
