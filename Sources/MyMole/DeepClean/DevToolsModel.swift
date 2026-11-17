import Foundation
import StorageKit
import SwiftUI

/// The Developer Tools sheet: Docker, simulators, Android and virtual
/// machines as their own tools list them. Recommended items start chosen,
/// offered ones only on the user's choice, shown ones never. Removal runs
/// each tool's own command; the App Store edition runs none and only lists.
@MainActor
@Observable
final class DevToolsModel {
    private(set) var listing: DevTools.Listing?
    private(set) var loading = false
    private(set) var removing = false
    private(set) var report: DevTools.Report?
    var chosen = Set<String>()

    let home: String
    private let runner: CommandRunner
    private let running: @Sendable () -> Set<String>?

    init(home: String = Home.path, runner: CommandRunner = DevToolsModel.liveRunner,
         running: @escaping @Sendable () -> Set<String>? = { RunningTools.names() }) {
        self.home = home
        self.runner = runner
        self.running = running
    }

    static var liveRunner: CommandRunner {
        #if APPSTORE
        CommandRunner(run: { _, _ in (1, "") }, exists: { _ in false })
        #else
        CommandRunner.processes(timeLimit: 120)
        #endif
    }

    var tools: DevTools.Tools { DevTools.Tools.find(home: home, exists: runner.exists) }

    func load() async {
        guard !loading, !removing else { return }
        loading = true
        defer { loading = false }
        let (home, runner, running, tools) = (home, runner, running, tools)
        let fresh = await Task.detached(priority: .userInitiated) {
            DevTools.inventory(home: home, tools: tools, runner: runner, running: running())
        }.value
        listing = fresh
        chosen = Set(fresh.items.filter { $0.handling == .recommend }.map(\.id))
    }

    func canChoose(_ item: DevTools.Item) -> Bool { item.handling != .show && item.removal != nil && !removing }

    func toggle(_ id: String) {
        guard let item = listing?.items.first(where: { $0.id == id }), canChoose(item) else { return }
        if chosen.contains(id) { chosen.remove(id) } else { chosen.insert(id) }
    }

    var chosenItems: [DevTools.Item] { (listing?.items ?? []).filter { chosen.contains($0.id) && canChoose($0) } }
    var chosenBytes: Int64 { chosenItems.compactMap(\.bytes).reduce(0, +) }

    func removeChosen() async {
        let items = chosenItems
        guard !items.isEmpty, !removing else { return }
        removing = true
        let (home, runner, tools) = (home, runner, tools)
        report = await Task.detached(priority: .userInitiated) {
            DevTools.remove(items, tools: tools, home: home, runner: runner)
        }.value
        removing = false
        await load()
    }
}
