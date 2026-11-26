import Darwin
import Foundation
import PrivilegedKit
import StorageKit
import Testing

@testable import MyMole

/// A batch of apps only Finder can move goes to Finder in one request, so
/// it asks for approval once. A synthetic Applications folder and Library
/// per test; Finder's move is stood in for by moving into the test's Trash.
@MainActor
@Suite(.serialized) struct BatchFinderMoveTests {
    private final class Home {
        let url = FileManager.default.temporaryDirectory.appending(path: "batch-finder-\(UUID().uuidString)")
        var path: String { url.path }

        init() throws {
            for name in ["Editor", "Viewer"] {
                try write("Applications/\(name).app/Contents/MacOS/bin")
                let info: NSDictionary = ["CFBundleIdentifier": "com.vendor.\(name)", "CFBundleName": name]
                try info.write(to: url.appending(path: "Applications/\(name).app/Contents/Info.plist"))
                try write("Library/Caches/com.vendor.\(name)/c")
            }
        }

        deinit { try? FileManager.default.removeItem(at: url) }

        func write(_ rel: String) throws {
            let u = url.appending(path: rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 3, count: 3_000).write(to: u)
        }

        func exists(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: path + "/" + rel) }

        /// Finder's move: into the test's Trash, after the request is checked again.
        func finderMove(_ request: FinderAppTrash.Request) -> Int32 {
            guard request.stillCurrent() else { return FinderAppTrash.changed }
            let trash = path + "/.Trash"
            try? FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            return (try? FileManager.default.moveItem(atPath: request.source.path, toPath: trash + "/" + request.source.lastPathComponent)) == nil ? -1 : 0
        }

        @MainActor func model(finder: FinderAppTrash) -> AppsModel {
            let denied: @MainActor ([String]) async -> TrashOutcome = { paths in
                AppsModel.recycleOutcome(urls: paths.map { URL(fileURLWithPath: $0) }, map: [:],
                    error: NSError(domain: NSCocoaErrorDomain, code: 513,
                        userInfo: [NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -5000)]))
            }
            let model = AppsModel(
                home: path, folders: [path + "/Applications"], base: url.appending(path: "store"),
                logURL: url.appending(path: "history.json"), recycle: denied, finderTrash: finder,
                isRunning: { _ in false }, otherCopies: { _ in [] },
                system: AppsModel.SystemSide(base: path + "/system", isReady: { false }, remove: { _, _, _, _ in RemovalReport() }),
                trash: testBin(url), protections: UserProtections(root: url.appending(path: "support")),
                imageOf: { _ in nil }, eject: { _ in "Not in tests" }, identityReaders: .init(groups: { _ in [] }), runtimeRoots: [])
            model.needsApprovalToMove = { _ in true }
            return model
        }
    }

    private func batch(_ model: AppsModel, _ home: Home) async throws -> [AppsModel.BatchItem] {
        var items: [AppsModel.BatchItem] = []
        for name in ["Editor", "Viewer"] {
            let app = try #require(AppFinder.metadata(home.path + "/Applications/\(name).app"))
            items.append(.init(app: app, leftovers: try #require(await model.leftovers(for: app)).filter(\.chosenByDefault)))
        }
        return items
    }

    @Test func appsOnlyFinderCanMoveGoInOneRequestWithOneApproval() async throws {
        let home = try Home()
        var approvals = 0, together: [[String]] = [], alone = 0
        let finder = FinderAppTrash(
            authorize: { approvals += 1; return 0 },
            move: { request in alone += 1; return home.finderMove(request) },
            moveAll: { requests in
                together.append(requests.map(\.source.lastPathComponent))
                return requests.map(home.finderMove).first { $0 != 0 } ?? 0
            })
        let model = home.model(finder: finder)
        let problems = await model.uninstall(batch: try await batch(model, home))
        #expect(problems.isEmpty)
        #expect(approvals == 1 && together == [["Editor.app", "Viewer.app"]] && alone == 0)
        #expect(home.exists(".Trash/Editor.app") && home.exists(".Trash/Viewer.app"))
        // Each app's verified leftovers followed it.
        #expect(!home.exists("Library/Caches/com.vendor.Editor/c") && !home.exists("Library/Caches/com.vendor.Viewer/c"))
        #expect(!model.uninstalling && model.authorizingApp == nil)
    }

    @Test func whenFinderMovesNoneTogetherEachGoesOnItsOwn() async throws {
        let home = try Home()
        var together = 0, alone = 0
        let finder = FinderAppTrash(
            authorize: { 0 },
            move: { request in alone += 1; return home.finderMove(request) },
            moveAll: { _ in together += 1; return FinderAppTrash.changed })
        let model = home.model(finder: finder)
        let problems = await model.uninstall(batch: try await batch(model, home))
        #expect(problems.isEmpty && together == 1 && alone == 2)
        #expect(home.exists(".Trash/Editor.app") && home.exists(".Trash/Viewer.app"))
    }

    @Test func oneAppAloneIsMovedAsBefore() async throws {
        let home = try Home()
        var together = 0, alone = 0
        let finder = FinderAppTrash(authorize: { 0 }, move: { request in alone += 1; return home.finderMove(request) },
                                    moveAll: { _ in together += 1; return 0 })
        let model = home.model(finder: finder)
        let items = try await batch(model, home)
        let problems = await model.uninstall(batch: [items[0]])
        #expect(problems.isEmpty && together == 0 && alone == 1)
    }
}
