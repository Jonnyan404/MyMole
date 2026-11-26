import Foundation
import Testing

@testable import StorageKit

@Suite struct ScannedRiskTests {
    @Test(arguments: [
        "hidden/.aws/key", "hidden/.kube/config", "hidden/.azure/token", "hidden/.netrc", "hidden/.npmrc",
        "hidden/.docker/config.json", "hidden/.config/gh/hosts", "hidden/.config/gcloud/token",
        "Library/Safari/history", "Library/Application Support/Google/Chrome/Default/history",
        "Library/Application Support/Firefox/Profiles/default/history", "Library/Application Support/BraveSoftware/history",
        "Library/Application Support/Microsoft Edge/history", "Library/Application Support/Arc/history",
        "discard/.Trash/file", "Library/Application Support/MobileSync/Backup/device/file",
        "Library/Mobile Documents/cloud/file", "Library/CloudStorage/provider/file",
        "images/Album.photoslibrary/original", "Documents/personal", "Library/Mail/data", "Library/Messages/data",
        "images/Docker.raw", "images/guest.vmwarevm/data", "images/guest.pvm/data", "images/guest.utm/data",
        "images/guest.vdi", "images/guest.vmdk.backup", "images/guest.qcow2",
        "VirtualBox VMs/guest/data", "Parallels/guest/data", "Library/Developer/Xcode/Archives/archive/data",
        "Library/Group Containers/shared/data", "Library/Developer/CoreSimulator/Devices/device/data",
    ]) func warningsIncludeSmallFilesWithoutAnotherWalk(_ relative: String) throws {
        let box = try Sandbox()
        try box.file(relative, bytes: 1)
        let result = StorageScanner.scan(path: box.path, workers: 2)
        let expected = try #require(PathRisk.of(box.path + "/" + relative))
        #expect(result.root.scannedRisk?.level == expected.level)
        #expect(result.root.scannedRisk?.reason == "Inside: " + expected.reason)
        #expect(result.root.riskComplete)
        // The warning is the scan's metadata, independent of subsequent reads.
        try FileManager.default.removeItem(at: box.url.appending(path: relative))
        #expect(result.root.scannedRisk?.reason == "Inside: " + expected.reason)
    }

    @Test func rulesMatchWholeNamesWhateverElseThePathHolds() {
        let home = "/Users/synthetic"
        // A name that only begins like a rule's isn't the thing itself.
        #expect(PathRisk.of(home + "/.awsome/key") == nil)
        #expect(PathRisk.of(home + "/tools/.netrc.sample") == nil)
        // Docker's disk is the file of that name, not a folder named so.
        #expect(PathRisk.of(home + "/images/Docker.raw")?.level == .caution)
        #expect(PathRisk.of(home + "/images/Docker.raw/part") == nil)
        // Names in other scripts around a rule's own.
        #expect(PathRisk.of(home + "/Bilder från Åre/Album.photoslibrary")?.level == .caution)
        #expect(PathRisk.of(home + "/日本語/Documents/メモ")?.reason == "Your own files.")
        #expect(PathRisk.of(home + "/Skrivbord/日本語/メモ") == nil)
        // Shorter than any rule.
        #expect(PathRisk.of("") == nil && PathRisk.of("/") == nil)
        // The first rule that matches decides, as listed.
        #expect(PathRisk.of(home + "/Documents/.aws")?.reason.hasPrefix("Sign-in keys") == true)
    }

    @Test func skippedAndCancelledTreesCannotClaimCompleteRiskInformation() throws {
        let box = try Sandbox()
        try box.file("omitted/.netrc", bytes: 1)
        let result = StorageScanner.scan(path: box.path, skip: [box.path + "/omitted"])
        #expect(result.root.scannedRisk == nil && !result.root.riskComplete)
        let cancelled = ScanProgress()
        cancelled.cancel()
        #expect(!StorageScanner.scan(path: box.path, progress: cancelled).root.riskComplete)
    }

    @Test func hardLinkedCredentialNamesAreCheckedEvenWhenTheirBlocksWereCountedElsewhere() throws {
        let box = try Sandbox()
        let original = try box.file("ordinary/data", bytes: 2)
        try box.folder("hidden")
        try FileManager.default.linkItem(at: original, to: box.url.appending(path: "hidden/.netrc"))
        let result = StorageScanner.scan(path: box.path, workers: 1)
        #expect(result.root.scannedRisk?.reason.contains("Sign-in keys") == true)
    }
}
