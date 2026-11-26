import Foundation
import StorageKit
import Testing

@testable import MyMole

/// Settings → Privacy says MyMole makes no network connections. Every
/// module's source is read for the APIs that would make one.
@Suite struct NoNetworkTests {
    static let forbidden = [
        "import Network", "URLSession", "URLRequest", "NWConnection", "NWListener", "NWBrowser", "NWPathMonitor",
        "nw_connection", "CFStreamCreatePairWithSocket", "CFSocketCreate", "socket(AF_INET", "socket(PF_INET",
        "getaddrinfo(", "Data(contentsOf: URL(string", "String(contentsOf: URL(string", "WKWebView", "SFSafariViewController",
    ]

    @Test func noSourceMakesAConnection() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources")
        let walk = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var read = 0
        for case let file as URL in walk where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            read += 1
            for api in Self.forbidden where text.contains(api) {
                Issue.record("\(file.path.dropFirst(sources.path.count + 1)) uses \(api)")
            }
        }
        #expect(read > 100)
    }

    @Test func thePrivacyPathStartsAtHome() {
        #expect(PrivacySection.shown("/synthetic/home/Library/Application Support/MyMole", home: "/synthetic/home")
            == "~/Library/Application Support/MyMole")
        #expect(PrivacySection.shown("/synthetic/home", home: "/synthetic/home") == "~")
        #expect(PrivacySection.shown("/synthetic/homeless/x", home: "/synthetic/home") == "/synthetic/homeless/x")
    }

    @MainActor @Test func settingsFindsThePrivacySection() {
        #expect(SettingsSection.matching("network", sandboxed: false, systemTasks: true) == [.privacy])
        #expect(SettingsSection.matching("fingerprints", sandboxed: true, systemTasks: false).contains(.privacy))
    }
}
