import Foundation
import Synchronization
import Testing

@testable import StorageKit

/// Developer tools' own inventories, from synthetic tool output and files in
/// a home folder of the test's own. What is recommended, offered or only
/// shown, and the exact command that removes each, run by a fake runner.
@Suite struct DevToolsTests {
    final class Fake: Sendable {
        let calls = Mutex<[[String]]>([])
        let outputs: [String: (Int32, String)]
        let present: Set<String>
        init(_ outputs: [String: (Int32, String)] = [:], present: Set<String>) {
            self.outputs = outputs
            self.present = present
        }
        var runner: CommandRunner {
            CommandRunner(run: { exe, args in
                self.calls.withLock { $0.append([exe] + args) }
                return self.outputs[([exe] + args).joined(separator: " ")] ?? (0, "")
            }, exists: { self.present.contains($0) })
        }
    }

    static let dockerDF = """
    {"Images":[\
    {"Containers":"0","ID":"sha256:aaa1","Repository":"<none>","Tag":"<none>","Size":"120MB","SharedSize":"0B","UniqueSize":"120MB"},\
    {"Containers":"0","ID":"sha256:bbb2","Repository":"web","Tag":"1.0","Size":"1.5GB","SharedSize":"0B","UniqueSize":"1.5GB"},\
    {"Containers":"2","ID":"sha256:ccc3","Repository":"db","Tag":"16","Size":"400MB","SharedSize":"0B","UniqueSize":"400MB"}],\
    "Containers":[\
    {"ID":"c1","Image":"db:16","Names":"db-main","Size":"20MB","State":"running","Status":"Up 3 hours"},\
    {"ID":"c2","Image":"db:16","Names":"db-old","Size":"5.5kB","State":"exited","Status":"Exited (0) 2 days ago"}],\
    "Volumes":[\
    {"Name":"pgdata","Labels":"","Links":"1","Size":"2GB"},\
    {"Name":"cachevol","Labels":"","Links":"0","Size":"300MB"},\
    {"Name":"0c71ab","Labels":"com.docker.volume.anonymous=","Links":"0","Size":"10MB"},\
    {"Name":"9f00cd","Labels":"com.docker.volume.anonymous=","Links":"1","Size":"1MB"}],\
    "BuildCache":[\
    {"ID":"b1","InUse":"false","Shared":"false","Size":"700MB"},\
    {"ID":"b2","InUse":"true","Shared":"false","Size":"50MB"},\
    {"ID":"b3","InUse":"false","Shared":"true","Size":"30MB"}]}
    """

    @Test func readsDockerSizes() {
        #expect(DevTools.dockerBytes("120MB") == 120_000_000)
        #expect(DevTools.dockerBytes("1.5GB") == 1_500_000_000)
        #expect(DevTools.dockerBytes("5.5kB") == 5_500)
        #expect(DevTools.dockerBytes("0B") == 0)
        #expect(DevTools.dockerBytes("N/A") == nil)
    }

    @Test func dockerRecommendsOnlyWhatRebuildsAndNeverTouchesWhatIsInUse() throws {
        let items = try #require(DevTools.docker(json: Self.dockerDF))
        func item(_ name: String) throws -> DevTools.Item { try #require(items.first { $0.name == name }) }
        #expect(try item("Untagged image aaa1").handling == .recommend)
        #expect(try item("web:1.0").handling == .offer)
        #expect(try item("db:16").handling == .show)
        #expect(try item("db-main").handling == .show)
        #expect(try item("db-old").handling == .offer)
        // Named volumes hold databases: only shown, used or not.
        #expect(try item("pgdata").handling == .show)
        #expect(try item("cachevol").handling == .show)
        #expect(try item("Anonymous volume 0c71ab").handling == .offer)
        #expect(try item("Anonymous volume 9f00cd").handling == .show)
        let cache = try item("Unused build cache")
        #expect(cache.handling == .recommend && cache.bytes == 700_000_000)
        #expect(items.allSatisfy { $0.handling == .show || !$0.reason.isEmpty })

        #expect(try item("Untagged image aaa1").removal == .command(["image", "rm", "sha256:aaa1"]))
        #expect(try item("db-old").removal == .command(["container", "rm", "c2"]))
        #expect(try item("Anonymous volume 0c71ab").removal == .command(["volume", "rm", "0c71ab"]))
        #expect(cache.removal == .command(["builder", "prune", "--force"]))
        #expect(try item("db:16").removal == nil)
        // Nothing prunes everything.
        #expect(!items.contains { $0.removal.map { "\($0)".contains("system") || "\($0)".contains("--all") || "\($0)".contains("-a") } ?? false })
    }

    @Test func malformedDockerOutputIsUnknown() {
        #expect(DevTools.docker(json: "not json") == nil)
        #expect(DevTools.docker(json: #"{"Images":[{"ID":"x;rm","Containers":"0","Repository":"<none>","Tag":"<none>","Size":"1MB"}]}"#)?.isEmpty == true)
    }

    static let devices = """
    {"devices":{\
    "com.apple.CoreSimulator.SimRuntime.iOS-26-4":[{"udid":"11111111-2222-3333-4444-555555555555","name":"Phone A","state":"Shutdown","isAvailable":true,"dataPathSize":1000}],\
    "com.apple.CoreSimulator.SimRuntime.iOS-17-5":[\
    {"udid":"AAAAAAAA-2222-3333-4444-555555555555","name":"Old Phone","state":"Shutdown","isAvailable":false,"availabilityError":"runtime profile not found","dataPathSize":5000000},\
    {"udid":"BBBBBBBB-2222-3333-4444-555555555555","name":"Old Booted","state":"Booted","isAvailable":false,"dataPathSize":7000}]}}
    """
    static let runtimes = """
    {"R1":{"identifier":"11111111-AAAA-4000-8000-000000000001","runtimeIdentifier":"com.apple.CoreSimulator.SimRuntime.iOS-26-4","version":"26.4","sizeBytes":8000000000,"deletable":true,"state":"Ready","lastUsedAt":"2026-05-11T06:34:14Z"},\
    "R2":{"identifier":"11111111-AAAA-4000-8000-000000000002","runtimeIdentifier":"com.apple.CoreSimulator.SimRuntime.iOS-26-5","version":"26.5","sizeBytes":9000000000,"deletable":true,"state":"Ready"},\
    "R3":{"identifier":"11111111-AAAA-4000-8000-000000000003","runtimeIdentifier":"com.apple.CoreSimulator.SimRuntime.watchOS-11-0","version":"11.0","sizeBytes":3000000000,"deletable":false,"state":"Ready"}}
    """

    @Test func simulatorRuntimesAndUnavailableDevicesAreOfferedThroughSimctl() throws {
        let items = try #require(DevTools.simulators(devices: Self.devices, runtimes: Self.runtimes))
        func item(_ name: String) throws -> DevTools.Item { try #require(items.first { $0.name == name }) }
        // A runtime a simulator still uses is only shown; an unused one is offered.
        #expect(try item("iOS 26.4 runtime").handling == .show)
        let unused = try item("iOS 26.5 runtime")
        #expect(unused.handling == .offer && unused.bytes == 9_000_000_000)
        #expect(unused.removal == .xcrun(["simctl", "runtime", "delete", "11111111-AAAA-4000-8000-000000000002"]))
        #expect(try item("watchOS 11.0 runtime").handling == .show)
        // A simulator whose runtime is gone, shut down: offered, never recommended.
        let old = try item("Old Phone")
        #expect(old.handling == .offer && old.bytes == 5_000_000)
        #expect(old.removal == .xcrun(["simctl", "delete", "AAAAAAAA-2222-3333-4444-555555555555"]))
        #expect(try item("Old Booted").handling == .show)
        // Available simulators are Deep Clean's.
        #expect(!items.contains { $0.name == "Phone A" })
    }

    private func write(_ box: Sandbox, _ rel: String, _ text: String) throws {
        let url = box.url.appending(path: rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test func androidDevicesAndImagesGoOnlyThroughTheirTools() throws {
        let box = try Sandbox()
        let sdk = box.path + "/Library/Android/sdk"
        try write(box, ".android/avd/Pixel_8.ini", "path=\(box.path)/.android/avd/Pixel_8.avd\ntarget=android-35\n")
        try write(box, ".android/avd/Pixel_8.avd/config.ini", "avd.ini.displayname=Pixel 8\nimage.sysdir.1=system-images/android-35/google_apis/arm64-v8a/\n")
        try box.file(".android/avd/Pixel_8.avd/userdata-qemu.img", bytes: 40_000)
        try write(box, ".android/avd/Tablet.ini", "path=\(box.path)/.android/avd/Tablet.avd\n")
        try write(box, ".android/avd/Tablet.avd/config.ini", "image.sysdir.1=system-images/android-34/google_apis/arm64-v8a/\n")
        try box.file(".android/avd/Tablet.avd/multiinstance.lock", bytes: 10)
        try box.file("Library/Android/sdk/system-images/android-35/google_apis/arm64-v8a/system.img", bytes: 50_000)
        try box.file("Library/Android/sdk/system-images/android-34/google_apis/arm64-v8a/system.img", bytes: 50_000)
        try box.file("Library/Android/sdk/system-images/android-33/default/x86_64/system.img", bytes: 50_000)
        let avdmanager = sdk + "/cmdline-tools/latest/bin/avdmanager"
        let sdkmanager = sdk + "/cmdline-tools/latest/bin/sdkmanager"

        let withTools = DevTools.android(home: box.path, toolExists: { [avdmanager, sdkmanager].contains($0) })
        func item(_ name: String) throws -> DevTools.Item { try #require(withTools.first { $0.name == name }) }
        let pixel = try item("Pixel 8")
        #expect(pixel.handling == .offer && (pixel.bytes ?? 0) > 0)
        #expect(pixel.removal == .tool(avdmanager, ["delete", "avd", "-n", "Pixel_8"]))
        // Running: the emulator holds a lock in its folder.
        #expect(try item("Tablet").handling == .show)
        // Images a device uses stay; an unused one goes through sdkmanager.
        #expect(try item("android-35 · google_apis · arm64-v8a").handling == .show)
        #expect(try item("android-34 · google_apis · arm64-v8a").handling == .show)
        let unused = try item("android-33 · default · x86_64")
        #expect(unused.handling == .offer)
        #expect(unused.removal == .tool(sdkmanager, ["--uninstall", "system-images;android-33;default;x86_64"]))

        // Without the tools, everything is only shown.
        let without = DevTools.android(home: box.path, toolExists: { _ in false })
        #expect(without.allSatisfy { $0.handling == .show && $0.removal == nil })
    }

    @Test func virtualMachinesAreOnlyShownWithTheirSizes() throws {
        let box = try Sandbox()
        try box.file("Library/Containers/com.utmapp.UTM/Data/Documents/Linux.utm/Data/disk.qcow2", bytes: 30_000)
        try box.file("Parallels/Windows 11.pvm/harddisk.hdd/data", bytes: 30_000)
        try box.file("Virtual Machines.localized/Ubuntu.vmwarevm/disk.vmdk", bytes: 30_000)
        try box.file("VirtualBox VMs/Debian/Debian.vbox", bytes: 3_000)
        try box.file(".tart/vms/builder/disk.img", bytes: 30_000)
        let vms = DevTools.virtualMachines(home: box.path, running: ["prl_client_app"])
        #expect(Set(vms.map(\.name)) == ["Linux", "Windows 11", "Ubuntu", "Debian", "builder"])
        #expect(vms.allSatisfy { $0.handling == .show && $0.removal == nil && ($0.bytes ?? 0) > 0 })
        #expect(vms.first { $0.name == "Windows 11" }?.detail.contains("running") == true)
    }

    @Test func aRemovalRunsOnlyIfTheFreshInventoryStillOffersIt() throws {
        let docker = "/usr/local/bin/docker"
        let df = "\(docker) system df -v --format json"
        var running = Self.dockerDF.replacingOccurrences(of: #""Names":"db-old","Size":"5.5kB","State":"exited""#,
                                                         with: #""Names":"db-old","Size":"5.5kB","State":"running""#)
        let fake = Fake([df: (0, running)], present: [docker])
        let items = try #require(DevTools.docker(json: Self.dockerDF))
        let old = try #require(items.first { $0.name == "db-old" })
        let tools = DevTools.Tools(docker: docker)
        // Started since the list was made: refused, nothing run but the listing.
        let refused = DevTools.remove([old], tools: tools, home: "/var/empty", runner: fake.runner)
        #expect(refused.removed.isEmpty && refused.refused == [old.id])
        #expect(fake.calls.withLock { $0 } == [[docker, "system", "df", "-v", "--format", "json"]])

        running = Self.dockerDF
        let ok = Fake([df: (0, running)], present: [docker])
        let done = DevTools.remove([old], tools: tools, home: "/var/empty", runner: ok.runner)
        #expect(done.removed == [old.id])
        #expect(ok.calls.withLock { $0 }.last == [docker, "container", "rm", "c2"])
        // A shown item is never removed, whatever is asked.
        let shown = try #require(items.first { $0.name == "pgdata" })
        #expect(DevTools.remove([shown], tools: tools, home: "/var/empty", runner: ok.runner).refused == [shown.id])
    }
}
