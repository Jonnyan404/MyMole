import Foundation
import Testing

@testable import PrivilegedKit
import StorageKit

/// Bills of materials made by macOS's own `mkbom` from synthetic file lists,
/// compressed. "single" installs Fixture Tool.app; "twoApps" Fixture Tool.app
/// and Fixture Other.app; "combo", at the volume's root,
/// /Applications/Fixture Tool.app and a HAL driver, FixtureAudio.driver;
/// "driverOnly", at the root, only that driver.
enum Boms {
    static let single = "7dzPahNRFMfx30z+aWzUxj+rgjLZB2RCVt20glhULFRdigWnGKgzaTqFIhTqxrV7u5KufA1fwKUv4RO48d45NzFm1aXG7wcuN+fk3GFIZnW4dzafPtkpi0kmKXLjtjToS88/Sr3ExevCsvP/e6v6lO8VIfZD5SSbPhcN6bpVb++Wbw5drj53hY4bK7KSa27ccKNrT5Nu8QMDAAAAAPBvmusM1EJnoD6fvOTG6ay6r5C+8jo7ttYCAAAAAABYZnNdgvZsU4FPPBgdl0eT7O6zotjv747Har7Yyv+OhkHD319rs3i7ZTsk4obtgpDqrYeP7S6l5vSGpcvNndG7bDig2QEAAAAAwPKLI9U2foRge5qNLvi1r3Dj6gXK7hd5meWlb0n4HRlajdya9+cLa9rRwrqab2j0x/ujw9KH/kzHTc1OfPxR2g7Tl9+pgT/jsSZ1h6rOecRDa+jEaxZ3D0LsizsufmT55LOq7SHJgcW9l1aXull3XN0rNzfdvKdqK0l6Yvnkg9WnZyF/bvn0q10//Rby393cc/NPVedRBm3LAwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAPgPNaRururNrXEnzPcsn3xyc8vF/gWpK4sLfwE="
    static let combo = "7dzNaxNBGMfxJ5smadPWl/Vdq9bENxALJUm9iJIKpcWKharHYmq3dqFm0+1WqiB48qo3LwVBPPkvePToRfDiP+HFiyfBZ3YmNS1qTkIp3w887M5vZzbL7p6GnYzfvjWbRHEgIhmtiyK1eZG7r0TKJW1fFex25rkX0r3mYuTapiSJg/Z7kRPZZ3vPNJKlVc2KHWcY1BoQ22Wv1jGto1oHtHytw1qHtIa0Tmid1jqlZd6wM1rntM7at08u8EAAAAAAANgZOmYGsm5moNgZ9mo93+w90p5l6F8I1u3UAgAAAAAA2M06ZgmKmx8VmKDeai2HDxpJGDVXTeBp7dkZEwY5c32F8ejRlP1CwsvZryBEegqT01NNc5Ui+fy99m5ffjZ8GoxVmewAAAAAAGD38zKSrX9zjZl2mtly+Oe/D/99tOkxEa4na3EwfCeKlkcarZYJs1r7u4/N3oiaSdBM0smWHq2DW8bIn8ZkpsP5uBE/MftmUuRI9yG5+tpCaCZNJK91vPuA/Mzy2sPLU3YSyKxLOdl9TGGyPm225ruT4e7de91tSy9tZCEOHwexyfu0yt2H93XeObMO5rzr0L+to1N8/3u/NiHpOhh/TNI1Md6YnQTzhmzbX3Ft03lQ2zdtXnor6Sc1pRXbLs/ZfhXdmvU0/n17h/1Fexsqz2xeemHeBt2+dvmGzSsf7Hkqn13+1eU/7O9We2xeHbB59ZKka3yqV1x+3eVz9h5Ul1zecvlLd54Nl79z+UfX/uS2X1z+XdI1Q7WizWu+zWuj9jy1a+7xAgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAPj/ciKlN5L+263ftFtv0G1H7XHP/EHqwPaBvwA="
    static let twoApps = "7dzBShtxEMfxXxKTWDW2RvQkWNa7ICs59aKHolhJQOtRFLqiYLMaVwhCoSfPvben4snX6FP06AP4CAVnd/5Jg5f22IbvB/6ZnclssiR7Gv7sZnt3L0t7iaSSrXkp/iW9/yKtRJa/EcZd/r/Xi6PuSRryfCnrJYP7oiq98u7OcXZ6ZbXKyCc0bM343aOmvPUlPywAAAAAAP+3kclAJUwGKqPFSVufh92rCuXpD0nfRwsAAAAAAGCcjUwJpoabCvLC27N+dt1LXu+n6fnq8cWFagfb3X9jYFDNr6++mX7c9h0S5arvgpAm6lvv/Cql2uCCpRe1vbObpLXOsAMAAAAAgPFXLqmy8RiSzqBa+su38w5bs39uGw5P2tlp0iumJyq2ZmgudE48OyOYuv99HD/Yy5LUbFlcsO9u+XymvOR58zLkeXPD8h2vR99V7PaILj1fOfS+2KKWre/IYs3iiYqdIfEnr0e33h9/C/U7r8c/LC5a/Ol1AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABiqSs2uiuevlhshrnk9+mqxbnn+gNSZ5yc+AQ=="
    static let driverOnly = "7d2/axNhHMfxTy7JRWvjj/NX1YJyXVwsSI5MLumgDUYsFB3VSq7tgSb0TKQKgiCIs6M4OfovOPufuDo4uvn8ShuKUAcHDe8XfLnn+eZ7yZHc9OV5Lit376yPhmUuqWJiUcreSPfeSUupmd8QZp393RtuNNgchrkNjcp8cl/UpZO+em1jtP3M5OKpd2iamJcvOWHitInExDkTZ01cMLHg7y5d4gsHAAAAAOD/MNUZqIbOQDydPGLi9V718qTLcKyf7/rWAgAAAAAAmGVTXYK5vUUFNtErHpcb5Qs7jkwcl+st6NQ/0DCo2+trrAyfdv0KiajuV0FItcZqrzuwbQ0pju9Phkfj9eJl3s5odgAAAAAAMPuiiqqd7wezlb/zsq3ojPvF8A8Kq2tPxlvXugPbs1DNxJnDz6mtdnr2aLsf5w8vr98sdkfjMneXtNwvi+d5afN2o8hF7W8z+U1LZO7z/jjbktsokrTlNo9Ebd8lihb9PNkJc1vcNPPbPp9+kltzku74+dIDX9cyR102dY/8tSSbcutTWq98Pn0rt3klfR/yH32+9UWuQ5V+CPmvIf/Nf27rR8j/9Plswc+zK+F4NeRvyW1+yR76PAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIAZUJOSgdyf6ETNcLwu9zjXyD4Ydf7gCb8A"

    static func data(_ packed: String) -> Data {
        (try! (Data(base64Encoded: packed)! as NSData).decompressed(using: .zlib)) as Data
    }
}

/// System-wide parts beyond the exact-ID places: the maker's launch jobs,
/// the parts vendors list, and what an app's own installer record put on
/// the Mac. All in a synthetic system folder of the box.
@Suite struct SystemVendorPartsTests {
    func plist(_ dict: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    func app(_ box: Box, _ rel: String, id: String) throws {
        try box.file(rel + "/Contents/Info.plist", try plist(["CFBundleIdentifier": id]))
    }

    func bundle(_ box: Box, _ rel: String, id: String) throws {
        try box.file(rel + "/Contents/Info.plist", try plist(["CFBundleIdentifier": id]))
        try box.file(rel + "/Contents/MacOS/driver")
    }

    func receipt(_ box: Box, _ id: String, bom: String, location: String) throws {
        try box.file("private/var/db/receipts/\(id).bom", Boms.data(bom))
        try box.file("private/var/db/receipts/\(id).plist", try plist(["PackageIdentifier": id, "InstallPrefixPath": location]))
    }

    func rel(_ box: Box, _ found: [SystemLeftover]) -> Set<String> {
        Set(found.map { String($0.path.dropFirst(box.path.count)) })
    }

    func zoom() throws -> Box {
        let box = try Box()
        try box.folder("Users")
        try app(box, "Applications/zoom.us.app", id: "us.zoom.xos")
        try box.file("Library/LaunchAgents/us.zoom.updater.plist", try plist(["Label": "us.zoom.updater"]))
        try box.file("Library/LaunchAgents/us.zoom.updater.login.check.plist", try plist(["Label": "us.zoom.updater.login.check"]))
        try box.file("Library/LaunchDaemons/us.zoom.ZoomDaemon.plist", try plist(["Label": "us.zoom.ZoomDaemon"]))
        try box.file("Library/PrivilegedHelperTools/us.zoom.ZoomDaemon")
        try box.file("Library/LaunchDaemons/com.other.Daemon.plist", try plist(["Label": "com.other.Daemon"]))
        try bundle(box, "Library/Internet Plug-Ins/ZoomUsPlugIn.plugin", id: "us.zoom.ZoomUsPlugIn")
        try box.file("Library/Logs/zoomusinstall.log")
        return box
    }

    let zoomApp = SystemLeftovers.Origin(id: "us.zoom.xos", path: "/Applications/zoom.us.app")

    @Test func theMakersJobsAndListedPartsGoWithTheLastOfItsApps() throws {
        let box = try zoom()
        let found = SystemLeftovers.find(ids: ["us.zoom.xos"], base: box.path, app: zoomApp)
        #expect(rel(box, found) == [
            "/Library/LaunchAgents/us.zoom.updater.plist", "/Library/LaunchAgents/us.zoom.updater.login.check.plist",
            "/Library/LaunchDaemons/us.zoom.ZoomDaemon.plist", "/Library/PrivilegedHelperTools/us.zoom.ZoomDaemon",
            "/Library/Internet Plug-Ins/ZoomUsPlugIn.plugin", "/Library/Logs/zoomusinstall.log",
        ])
        #expect(found.allSatisfy { !$0.kind.chosenByDefault })
        #expect(found.first { $0.name == "us.zoom.ZoomDaemon.plist" }?.why == .maker)
        #expect(found.first { $0.name == "ZoomUsPlugIn.plugin" }?.why == .vendorList)

        // Another app of the maker is still installed: its jobs stay.
        try app(box, "Applications/Zoom Rooms.app", id: "us.zoom.ZoomPresence")
        let shared = rel(box, SystemLeftovers.find(ids: ["us.zoom.xos"], base: box.path, app: zoomApp))
        #expect(!shared.contains { $0.contains("updater") || $0.contains("ZoomDaemon") })
        #expect(shared.contains("/Library/Internet Plug-Ins/ZoomUsPlugIn.plugin"))
    }

    @Test func theHelperRemovesThemOnlyOnceTheAppIsGoneAndStopsTheJobFirst() throws {
        let box = try zoom()
        let paths = SystemLeftovers.find(ids: ["us.zoom.xos"], base: box.path, app: zoomApp).map(\.path)
        let early = SystemLeftovers.remove(paths, appID: "us.zoom.xos", ids: ["us.zoom.xos"], appPath: zoomApp.path, base: box.path,
                                           runner: FakeRunner().runner)
        #expect(early.removed.isEmpty)

        try FileManager.default.removeItem(atPath: box.path + "/Applications/zoom.us.app")
        let fake = FakeRunner()
        let sneaky = [box.path + "/Library/LaunchDaemons/com.other.Daemon.plist"]
        let report = SystemLeftovers.remove(paths + sneaky, appID: "us.zoom.xos", ids: ["us.zoom.xos"], appPath: zoomApp.path,
                                            base: box.path, runner: fake.runner)
        #expect(Set(report.removed) == Set(paths))
        #expect(report.refused == sneaky)
        #expect(fake.calls.withLock { $0 } == [[SystemLeftovers.launchctl, "bootout", "system/us.zoom.ZoomDaemon"]])
        #expect(box.exists("Library/LaunchDaemons/com.other.Daemon.plist"))
    }

    @Test func anAppOutsideTheApplicationsFoldersStillCounts() throws {
        let box = try zoom()
        try FileManager.default.removeItem(atPath: box.path + "/Applications/zoom.us.app")
        // Updaters and helper apps live in Application Support.
        try app(box, "Library/Application Support/Zoom/Rooms/Zoom Rooms.app", id: "us.zoom.ZoomPresence")
        let paths = [box.path + "/Library/LaunchAgents/us.zoom.updater.plist"]
        let report = SystemLeftovers.remove(paths, appID: "us.zoom.xos", ids: ["us.zoom.xos"], appPath: zoomApp.path, base: box.path,
                                            runner: FakeRunner().runner)
        #expect(report.refused == paths)
        let owners = try #require(SystemLeftovers.installedOwners(base: box.path))
        #expect(owners.contains("us.zoom.zoompresence"))
        // Deeper in an Applications folder too.
        try app(box, "Applications/Utilities/Vendor Suite/Tools/Deep Tool.app", id: "com.vendor.Deep")
        #expect(SystemLeftovers.installedOwners(base: box.path)?.contains("com.vendor.deep") == true)
    }

    @Test func applesOwnFoldersInApplicationSupportAreNotRead() throws {
        let box = try zoom()
        try box.folder("Library/Application Support/com.apple.TCC")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: box.path + "/Library/Application Support/com.apple.TCC")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: box.path + "/Library/Application Support/com.apple.TCC") }
        #expect(SystemLeftovers.installedOwners(base: box.path) != nil)
        // Another vendor's folder that can't be read leaves the map unknown.
        try box.folder("Library/Application Support/Vendor")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: box.path + "/Library/Application Support/Vendor")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: box.path + "/Library/Application Support/Vendor") }
        #expect(SystemLeftovers.installedOwners(base: box.path) == nil)
    }

    @Test func aListedDriverGoesOnlyWhileItStillCarriesItsID() throws {
        let box = try Box()
        try box.folder("Applications")
        try box.folder("Users")
        try bundle(box, "Library/Audio/Plug-Ins/HAL/MSTeamsAudioDevice.driver", id: "com.microsoft.MSTeamsAudioDevice")
        try box.folder("Library/Application Support/Microsoft/TeamsUpdaterDaemon")
        try box.file("Library/Application Support/Microsoft/TeamsUpdaterDaemon/d")
        let teams = SystemLeftovers.Origin(id: "com.microsoft.teams2", path: "/Applications/Microsoft Teams.app")
        let found = rel(box, SystemLeftovers.find(ids: ["com.microsoft.teams2"], base: box.path, app: teams))
        #expect(found == ["/Library/Audio/Plug-Ins/HAL/MSTeamsAudioDevice.driver", "/Library/Application Support/Microsoft/TeamsUpdaterDaemon"])

        // Something else now sits under that name.
        try box.file("Library/Audio/Plug-Ins/HAL/MSTeamsAudioDevice.driver/Contents/Info.plist", try plist(["CFBundleIdentifier": "com.other.Audio"]))
        let path = box.path + "/Library/Audio/Plug-Ins/HAL/MSTeamsAudioDevice.driver"
        let report = SystemLeftovers.remove([path], appID: "com.microsoft.teams2", ids: ["com.microsoft.teams2"], appPath: teams.path,
                                            base: box.path, runner: FakeRunner().runner)
        #expect(report.refused == [path])
        #expect(box.exists("Library/Audio/Plug-Ins/HAL/MSTeamsAudioDevice.driver/Contents/Info.plist"))
    }

    @Test func applesMusicAppsShareTheirLoopsAndKeepThemForEachOther() throws {
        let box = try Box()
        try box.folder("Users")
        try app(box, "Applications/Logic Pro.app", id: "com.apple.logic10")
        try box.file("Library/Audio/Apple Loops/Apple/01 Hip Hop/loop.caf")
        try box.file("Library/Application Support/GarageBand/Instrument Library/i.exs")
        let band = SystemLeftovers.Origin(id: "com.apple.garageband10", path: "/Applications/GarageBand.app")
        #expect(rel(box, SystemLeftovers.find(ids: [], base: box.path, app: band)) == ["/Library/Application Support/GarageBand"])
        try FileManager.default.removeItem(atPath: box.path + "/Applications/Logic Pro.app")
        let all = SystemLeftovers.find(ids: [], base: box.path, app: band)
        #expect(rel(box, all) == ["/Library/Application Support/GarageBand", "/Library/Audio/Apple Loops/Apple"])
        let report = SystemLeftovers.remove(all.map(\.path), appID: "com.apple.garageband10", ids: [], appPath: band.path,
                                            base: box.path, runner: FakeRunner().runner)
        #expect(Set(report.removed) == Set(all.map(\.path)))
        // Apple's own IDs still never match the ID-based places.
        #expect(SystemLeftovers.requestable(appID: "com.apple.garageband10", ids: []).isEmpty)
    }

    @Test func aRecordGoesWithTheOneAppItInstalledAndSoDoesItsDriver() throws {
        let box = try Box()
        try box.folder("Applications")
        try box.folder("Users")
        try receipt(box, "com.vendor.pkg.tool", bom: Boms.combo, location: "/")
        try receipt(box, "com.vendor.pkg.suite", bom: Boms.twoApps, location: "Applications")
        try bundle(box, "Library/Audio/Plug-Ins/HAL/FixtureAudio.driver", id: "com.unrelated.FixtureAudio")
        let tool = SystemLeftovers.Origin(id: "com.vendor.Tool", path: "/Applications/Fixture Tool.app")
        let found = SystemLeftovers.find(ids: ["com.vendor.Tool"], base: box.path, app: tool)
        #expect(rel(box, found) == [
            "/private/var/db/receipts/com.vendor.pkg.tool.bom", "/private/var/db/receipts/com.vendor.pkg.tool.plist",
            "/Library/Audio/Plug-Ins/HAL/FixtureAudio.driver",
        ])
        #expect(found.first { $0.name == "FixtureAudio.driver" }?.why == .installedWith)
        #expect(found.first { $0.name.hasSuffix(".bom") }?.kind == .record)

        // Removed only for that app's path, which the request names.
        let paths = found.map(\.path)
        let other = SystemLeftovers.remove(paths, appID: "com.vendor.Tool", ids: ["com.vendor.Tool"], appPath: "/Applications/Other.app",
                                           base: box.path, runner: FakeRunner().runner)
        #expect(other.removed.isEmpty)
        let none = SystemLeftovers.remove(paths, appID: "com.vendor.Tool", ids: ["com.vendor.Tool"], base: box.path, runner: FakeRunner().runner)
        #expect(none.removed.isEmpty)
        let report = SystemLeftovers.remove(paths, appID: "com.vendor.Tool", ids: ["com.vendor.Tool"], appPath: tool.path,
                                            base: box.path, runner: FakeRunner().runner)
        #expect(Set(report.removed) == Set(paths))
        #expect(box.exists("private/var/db/receipts/com.vendor.pkg.suite.bom"))
    }

    @Test func aDriverAnotherRecordAlsoInstalledStays() throws {
        let box = try Box()
        try box.folder("Applications")
        try box.folder("Users")
        try receipt(box, "com.vendor.pkg.tool", bom: Boms.combo, location: "/")
        try receipt(box, "com.vendor.pkg.audio", bom: Boms.driverOnly, location: "/")
        try bundle(box, "Library/Audio/Plug-Ins/HAL/FixtureAudio.driver", id: "com.unrelated.FixtureAudio")
        let tool = SystemLeftovers.Origin(id: "com.vendor.Tool", path: "/Applications/Fixture Tool.app")
        let found = rel(box, SystemLeftovers.find(ids: ["com.vendor.Tool"], base: box.path, app: tool))
        #expect(!found.contains("/Library/Audio/Plug-Ins/HAL/FixtureAudio.driver"))
    }

    @Test func aDriverNamedByTheAppsIDIsItsOwn() throws {
        let box = try Box()
        try box.folder("Applications")
        try box.folder("Users")
        try bundle(box, "Library/Audio/Plug-Ins/HAL/EditorAudio.driver", id: "com.vendor.Editor.Audio")
        try bundle(box, "Library/Audio/Plug-Ins/HAL/OtherAudio.driver", id: "com.other.Audio")
        try bundle(box, "Library/CoreMediaIO/Plug-Ins/DAL/EditorCam.plugin", id: "com.vendor.Editor.Camera")
        try box.file("Library/Audio/Plug-Ins/Components/Editor.component/Contents/Info.plist", try plist(["CFBundleIdentifier": "com.vendor.Editor.AU"]))
        let editor = SystemLeftovers.Origin(id: "com.vendor.Editor", path: "/Applications/Editor.app")
        let found = rel(box, SystemLeftovers.find(ids: ["com.vendor.Editor"], base: box.path, app: editor))
        // Audio units and other instruments are the user's, whoever made them.
        #expect(found == ["/Library/Audio/Plug-Ins/HAL/EditorAudio.driver", "/Library/CoreMediaIO/Plug-Ins/DAL/EditorCam.plugin"])
    }

    @Test func aPartBehindALinkIsNeverOffered() throws {
        let box = try zoom()
        try FileManager.default.removeItem(atPath: box.path + "/Library/Internet Plug-Ins/ZoomUsPlugIn.plugin")
        try box.folder("elsewhere/Keep.plugin")
        try FileManager.default.createSymbolicLink(atPath: box.path + "/Library/Internet Plug-Ins/ZoomUsPlugIn.plugin",
                                                   withDestinationPath: box.path + "/elsewhere/Keep.plugin")
        let found = rel(box, SystemLeftovers.find(ids: ["us.zoom.xos"], base: box.path, app: zoomApp))
        #expect(!found.contains("/Library/Internet Plug-Ins/ZoomUsPlugIn.plugin"))
    }
}
