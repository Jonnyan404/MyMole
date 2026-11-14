import Darwin
import Foundation
import Testing

@testable import StorageKit

/// Folders of a cloud service, as macOS keeps them for Dropbox, Google
/// Drive, OneDrive and Proton Drive: a File Provider domain in
/// ~/Library/CloudStorage, where a file that's only in the cloud has its
/// size, no blocks and the dataless flag, and reading it downloads it. The
/// service is the test cloud in scripts/cloud-mock, set up and removed by
/// `scripts/cloud-tests.sh`; it logs every request for a file's content.
/// In each folder, `Copies/one.bin`, `two.bin` and `other.bin` and the
/// photos have been downloaded, as if opened; everything else is only in
/// the cloud. Nothing MyMole does on its own may download a file.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MYMOLE_CLOUD_HOST"] != nil))
struct CloudStorageTests {
    static let environment = ProcessInfo.processInfo.environment

    /// Each service's domain and the folder its files are in: Google Drive
    /// keeps them in "My Drive".
    static let services: [(domain: String, root: String)] = [
        ("dropbox", environment["MYMOLE_CLOUD_DROPBOX"]), ("google", environment["MYMOLE_CLOUD_GOOGLE"].map { $0 + "/My Drive" }),
        ("onedrive", environment["MYMOLE_CLOUD_ONEDRIVE"]), ("proton", environment["MYMOLE_CLOUD_PROTON"]),
    ].compactMap { domain, root in root.map { (domain, $0) } }

    /// The test cloud's own command line.
    static func host(_ arguments: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try #require(environment["MYMOLE_CLOUD_HOST"]))
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: output, as: UTF8.self)
    }

    /// The files of `domain` downloaded so far.
    static func downloads(_ domain: String) throws -> [String] {
        try host("fetches").split(separator: "\n").map { $0.split(separator: "\t").map(String.init) }
            .filter { $0.count == 3 && $0[0] == "fetch" && $0[1] == domain }.map { $0[2] }
    }

    /// Runs `body` on each service and checks it downloaded nothing there.
    func withoutDownloads(_ body: (_ domain: String, _ root: String) throws -> Void) throws {
        #expect(Self.services.count == 4)
        for service in Self.services {
            let before = try Self.downloads(service.domain)
            try body(service.domain, service.root)
            let after = try Self.downloads(service.domain)
            #expect(after.count == before.count, "\(service.domain) downloaded \(after.dropFirst(before.count))")
        }
    }

    func isCloudOnly(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && st.st_flags & UInt32(SF_DATALESS) != 0
    }

    @Test func theFoldersAreACloudServicesWithFilesOnlyInTheCloud() throws {
        for service in Self.services {
            #expect(service.root.contains("/Library/CloudStorage/"))
            #expect(isCloudOnly(service.root + "/Copies/three-cloud-only.bin"), "\(service.domain)")
            #expect(!isCloudOnly(service.root + "/Copies/one.bin"), "\(service.domain)")
        }
    }

    /// A file only in the cloud is listed, at no room on this Mac.
    @Test func aScanListsEveryFileAndCountsOnlyWhatsOnThisMac() throws {
        try withoutDownloads { domain, root in
            let r = StorageScanner.scan(path: root + "/Copies")
            var expected: Int64 = 0
            for name in ["one.bin", "two.bin", "other.bin", "three-cloud-only.bin"] {
                var st = stat()
                try #require(lstat(root + "/Copies/" + name, &st) == 0)
                expected += Int64(st.st_blocks) * 512
            }
            #expect(r.root.fileCount == 4, "\(domain)")
            #expect(r.root.size == expected && expected > 0, "\(domain)")
            #expect(r.deniedPaths.isEmpty, "\(domain)")
            // The whole folder, folders not opened yet included.
            #expect(!StorageScanner.scan(path: root).cancelled)
        }
    }

    /// `three-cloud-only.bin` holds what `one.bin` does, and is never read.
    @Test func duplicatesCompareOnlyDownloadedCopies() throws {
        try withoutDownloads { domain, root in
            let listing = DuplicateFinder.find(in: [root], minimum: 1_000, workers: 2)
            let copies = listing.groups.first { $0.files.contains { $0.path == root + "/Copies/one.bin" } }
            #expect(Set(copies?.files.map(\.path) ?? []) == [root + "/Copies/one.bin", root + "/Copies/two.bin"], "\(domain)")
            #expect(!listing.groups.contains { $0.files.contains { isCloudOnly($0.path) } }, "\(domain)")
        }
    }

    @Test func similarImagesReadOnlyDownloadedPhotos() throws {
        try withoutDownloads { _, root in
            _ = SimilarImages.find(in: [root], minimum: 1_000, workers: 2)
        }
    }

    /// `package.json` and `.git/HEAD` are only in the cloud.
    @Test func projectsAreFoundAndMeasuredWithoutDownloading() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "cloud-home-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        try withoutDownloads { domain, root in
            let listing = ProjectScanner.list(roots: [root + "/Code"], home: home, workers: 2)
            #expect(listing.footprints.map(\.project.path).contains(root + "/Code/app"), "\(domain): \(listing.footprints.map(\.project.path))")
        }
    }

    /// `Tool-1.0.dmg` and `Tool-1.0.pkg` are only in the cloud.
    @Test func installersAreListedWithoutDownloading() throws {
        try withoutDownloads { domain, root in
            let listing = InstallerFinder.list(in: [InstallerLocation(path: root + "/Installers", depth: 2)])
            #expect(Set(listing.files.map { ($0.path as NSString).lastPathComponent }).isSuperset(of: ["Tool-1.0.dmg", "Tool-1.0.pkg"]), "\(domain)")
        }
    }

    /// `Apps/Tool.app` is only in the cloud: its `Info.plist` isn't read.
    @Test func appCopiesInACloudFolderAreNotDownloaded() throws {
        try withoutDownloads { domain, root in
            #expect(isCloudOnly(root + "/Apps/Tool.app/Contents/Info.plist") || isCloudOnly(root + "/Apps"), "\(domain)")
            _ = AppCopy.read(root + "/Apps/Tool.app", source: .folder)
            _ = AppCopies.addingFolders([root], to: AppCopies.Report(), progress: ScanProgress())
        }
    }

    /// `Install macOS Test.app` is only in the cloud: whether it installs
    /// macOS isn't read from it.
    @Test func aMacOSInstallerInACloudFolderIsNotDownloaded() throws {
        try withoutDownloads { _, root in
            _ = InstallerFinder.list(in: [InstallerLocation(path: root + "/Installers", depth: 2)])
        }
    }

    @Test func aDownloadsReviewOfACloudFolderDownloadsNothing() throws {
        try withoutDownloads { _, root in
            _ = DownloadsReview.list(root)
        }
    }

    /// The service takes `two.bin` back to the cloud after it was opened,
    /// as macOS does when the disk runs low: it's no longer a copy here.
    @Test func aCopyTakenBackToTheCloudIsNoLongerReadOrOffered() throws {
        try withoutDownloads { domain, root in
            // Items are known by their path in the service's folder, which
            // for Google Drive starts with "My Drive".
            _ = try Self.host("evict", domain, domain == "google" ? "My Drive/Copies/two.bin" : "Copies/two.bin")
            for _ in 0..<50 where !isCloudOnly(root + "/Copies/two.bin") { Thread.sleep(forTimeInterval: 0.1) }
            #expect(isCloudOnly(root + "/Copies/two.bin"), "\(domain)")
            let listing = DuplicateFinder.find(in: [root + "/Copies"], minimum: 1_000, workers: 2)
            #expect(listing.groups.isEmpty, "\(domain): \(listing.groups.map { $0.files.map(\.path) })")
        }
    }
}
