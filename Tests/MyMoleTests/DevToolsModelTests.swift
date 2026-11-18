import Foundation
import StorageKit
import SynchronizationCompat
import Testing

@testable import MyMole

/// The Developer Tools sheet's model with an injected command runner: what
/// starts chosen, and that only the chosen items' own commands run.
@MainActor
@Suite struct DevToolsModelTests {
    final class Fake: Sendable {
        let calls = Mutex<[[String]]>([])
        let output: String
        init(_ output: String) { self.output = output }
        var runner: CommandRunner {
            CommandRunner(run: { exe, args in
                self.calls.withLock { $0.append([exe] + args) }
                return args.first == "system" ? (0, self.output) : (0, "")
            }, exists: { $0 == "/usr/local/bin/docker" })
        }
    }

    static let df = """
    {"Images":[{"Containers":"0","ID":"sha256:aaa1","Repository":"<none>","Tag":"<none>","Size":"120MB"},\
    {"Containers":"0","ID":"sha256:bbb2","Repository":"web","Tag":"1.0","Size":"1.5GB"}],\
    "Containers":[],"Volumes":[{"Name":"pgdata","Labels":"","Links":"0","Size":"2GB"}],"BuildCache":[]}
    """

    @Test func onlyWhatRebuildsStartsChosenAndOnlyChosenItemsAreRemoved() async throws {
        let fake = Fake(Self.df)
        let model = DevToolsModel(home: "/var/empty", runner: fake.runner, running: { [] })
        await model.load()
        let listing = try #require(model.listing)
        #expect(listing.items.count == 3)
        #expect(model.chosen == ["docker.image.sha256:aaa1"])
        #expect(model.canChoose(try #require(listing.items.first { $0.name == "web:1.0" })))
        #expect(!model.canChoose(try #require(listing.items.first { $0.name == "pgdata" })))
        model.toggle("docker.volume.pgdata")
        #expect(model.chosen == ["docker.image.sha256:aaa1"])
        await model.removeChosen()
        let removals = fake.calls.withLock { $0 }.filter { $0.dropFirst().first != "system" }
        #expect(removals == [["/usr/local/bin/docker", "image", "rm", "sha256:aaa1"]])
        #expect(model.report?.removed == ["docker.image.sha256:aaa1"])
    }
}
