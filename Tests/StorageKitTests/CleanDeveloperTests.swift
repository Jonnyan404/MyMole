import Foundation
import Testing

@testable import StorageKit

/// Developer tools' downloads and saved states in Deep Clean, in a home
/// folder of the test's own. All of them cost a download or a saved state,
/// so none is chosen for the user.
@Suite struct CleanDeveloperTests {
    private func candidates(_ box: Sandbox) -> [String: CleanCandidate] {
        Dictionary(uniqueKeysWithValues: CleanScanner.list(home: box.path, workers: 1).candidates.map { ($0.path, $0) })
    }

    @Test func deviceSupportOfEveryPlatformIsOfferedPerVersion() throws {
        let box = try Sandbox()
        let xcode = "Library/Developer/Xcode"
        for platform in ["iOS", "watchOS", "tvOS", "visionOS", "macOS"] {
            try box.file("\(xcode)/\(platform) DeviceSupport/Device1,1 1.0 (1A1)/Symbols/lib.dylib", bytes: 20_000)
        }
        try box.file("\(xcode)/Other DeviceSupport/Device1,1 1.0 (1A1)/x", bytes: 20_000)

        let found = candidates(box)
        for platform in ["iOS", "watchOS", "tvOS", "visionOS", "macOS"] {
            let path = box.path + "/\(xcode)/\(platform) DeviceSupport/Device1,1 1.0 (1A1)"
            let one = try #require(found[path], "\(platform)")
            #expect(one.category == .developerCaches && one.safety == .review && !one.contentsOnly)
            #expect(CleanScanner.isStillCandidate(path, home: box.path))
            #expect(CleanRules.inUse(path, home: box.path, running: ["Xcode"]))
            #expect(!CleanRules.inUse(path, home: box.path, running: ["Finder"]))
        }
        // Only the platforms Xcode names, never a folder that merely looks alike.
        #expect(!found.keys.contains { $0.contains("/Other DeviceSupport") })
    }

    @Test func gradleDistributionsAreOfferedOneVersionAtATime() throws {
        let box = try Sandbox()
        try box.file(".gradle/wrapper/dists/gradle-8.5-bin/abc/gradle-8.5/lib/a.jar", bytes: 30_000)
        try box.file(".gradle/wrapper/dists/gradle-7.6-all/def/gradle-7.6/lib/b.jar", bytes: 30_000)
        try box.file(".gradle/gradle.properties", bytes: 2_000)

        let found = candidates(box)
        let dists = box.path + "/.gradle/wrapper/dists"
        let new = try #require(found[dists + "/gradle-8.5-bin"])
        #expect(found[dists + "/gradle-7.6-all"] != nil)
        #expect(new.category == .developerCaches && new.safety == .review)
        // The settings beside them stay.
        #expect(!found.keys.contains { $0.hasSuffix("gradle.properties") })
        #expect(CleanRules.inUse(new.path, home: box.path, running: ["GradleDaemon"]))
        #expect(CleanScanner.isStillCandidate(new.path, home: box.path))
    }

    @Test func tartCachesAreOfferedButItsMachinesNeverAre() throws {
        let box = try Sandbox()
        try box.file(".tart/cache/OCIs/registry.example/images/base/sha256:1/disk.img", bytes: 40_000)
        try box.file(".tart/cache/IPSWs/restore.ipsw", bytes: 40_000)
        try box.file(".tart/vms/builder/disk.img", bytes: 40_000)

        let found = candidates(box)
        let oci = try #require(found[box.path + "/.tart/cache/OCIs"])
        let ipsw = try #require(found[box.path + "/.tart/cache/IPSWs"])
        #expect(oci.safety == .review && ipsw.safety == .review)
        #expect(oci.category == .developerCaches)
        #expect(!found.keys.contains { $0.contains("/.tart/vms") })
        #expect(!CleanScanner.isStillCandidate(box.path + "/.tart/vms/builder", home: box.path))
        #expect(!CleanScanner.isStillCandidate(box.path + "/.tart/vms", home: box.path))
        #expect(CleanRules.inUse(oci.path, home: box.path, running: ["tart"]))
    }

    @Test func emulatorSnapshotsAreOfferedOnlyWhileTheEmulatorIsShut() throws {
        let box = try Sandbox()
        let avd = ".android/avd"
        try box.file("\(avd)/Phone_API_35.avd/snapshots/default_boot/ram.bin", bytes: 50_000)
        try box.file("\(avd)/Phone_API_35.avd/snapshots/before-login/ram.bin", bytes: 50_000)
        try box.file("\(avd)/Phone_API_35.avd/userdata-qemu.img", bytes: 50_000)
        try box.file("\(avd)/Phone_API_35.avd/config.ini", bytes: 1_000)
        try box.file("\(avd)/Phone_API_35.ini", bytes: 500)
        // Running: the emulator holds lock files in its folder.
        try box.file("\(avd)/Tablet_API_34.avd/snapshots/default_boot/ram.bin", bytes: 50_000)
        try box.file("\(avd)/Tablet_API_34.avd/hardware-qemu.ini.lock", bytes: 10)
        try box.file("\(avd)/Tablet_API_34.ini", bytes: 500)

        let found = candidates(box)
        let base = box.path + "/\(avd)/Phone_API_35.avd/snapshots"
        let quick = try #require(found[base + "/default_boot"])
        #expect(found[base + "/before-login"] != nil)
        #expect(quick.category == .devices && quick.safety == .review && !quick.contentsOnly)
        #expect(quick.name == "Phone_API_35 · default_boot")
        // The emulator's disk, its settings and its description stay.
        #expect(!found.keys.contains { $0.hasSuffix("userdata-qemu.img") || $0.hasSuffix(".ini") || $0.hasSuffix(".avd") })
        #expect(!found.keys.contains { $0.contains("Tablet_API_34") })
        #expect(CleanScanner.isStillCandidate(quick.path, home: box.path))
        #expect(CleanRules.inUse(quick.path, home: box.path, running: ["qemu-system-aarch64"]))
        #expect(!CleanRules.inUse(quick.path, home: box.path, running: ["Finder"]))

        // Started since the scan: refused when it would go.
        try box.file("\(avd)/Phone_API_35.avd/multiinstance.lock", bytes: 10)
        #expect(!CleanScanner.isStillCandidate(quick.path, home: box.path))
    }

    @Test func xcodeArchivesAreOfferedButNeverChosen() throws {
        let box = try Sandbox()
        let day = "Library/Developer/Xcode/Archives/2026-11-15"
        let archive = box.path + "/\(day)/Sample 15.11.2026, 10.00.xcarchive"
        try box.file("\(day)/Sample 15.11.2026, 10.00.xcarchive/dSYMs/Sample.app.dSYM/x", bytes: 40_000)
        try PropertyListSerialization.data(fromPropertyList: [
            "Name": "Sample", "ApplicationProperties": ["CFBundleShortVersionString": "1.2"],
        ], format: .xml, options: 0).write(to: URL(fileURLWithPath: archive + "/Info.plist"))
        try box.file("\(day)/notes.txt", bytes: 2_000)

        let found = candidates(box)
        let one = try #require(found[archive])
        #expect(one.category == .archives && one.safety == .review && !one.contentsOnly)
        #expect(one.name == "Sample 1.2 · 2026-11-15")
        #expect(!found.keys.contains { $0.hasSuffix("notes.txt") })
        #expect(CleanScanner.isStillCandidate(archive, home: box.path))
        #expect(!CleanScanner.isStillCandidate(box.path + "/\(day)/notes.txt", home: box.path))
        #expect(CleanRules.inUse(archive, home: box.path, running: ["Xcode"]))
        #expect(!CleanCategory.archives.note.isEmpty)
    }

    @Test func noNewDeveloperItemStartsChosen() throws {
        let box = try Sandbox()
        try box.file("Library/Developer/Xcode/watchOS DeviceSupport/Watch1,1 1.0 (1A1)/x", bytes: 20_000)
        try box.file(".gradle/wrapper/dists/gradle-8.5-bin/x", bytes: 20_000)
        try box.file(".tart/cache/OCIs/x", bytes: 20_000)
        try box.file(".android/avd/A.avd/snapshots/default_boot/x", bytes: 20_000)
        let found = CleanScanner.list(home: box.path, workers: 1).candidates
        #expect(found.count == 4)
        #expect(found.allSatisfy { $0.safety == .review })
    }
}
