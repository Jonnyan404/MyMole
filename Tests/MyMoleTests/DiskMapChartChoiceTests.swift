import Foundation
import Testing

@testable import MyMole

/// The chart choice is saved only when it changes, and once for quick
/// switches: each write to the defaults draws every view that reads a
/// setting again.
@MainActor @Suite struct DiskMapChartChoiceTests {
    @Test func theChartIsSavedOnceWhenItChangesAndNotWhenItDoesnt() async throws {
        let box = FileManager.default.temporaryDirectory.appending(path: "chart-choice-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: box) }
        let settings = testDefaults(in: box)
        let model = StorageModel()
        model.settings = settings
        var writes = 0
        let token = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: settings, queue: nil) { _ in writes += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        let shown = model.chart
        model.chart = shown
        try await Task.sleep(for: .milliseconds(500))
        #expect(writes == 0)
        let others = StorageModel.Chart.allCases.filter { $0 != shown }
        for chart in others.prefix(3) { model.chart = chart }
        #expect(writes == 0, "Saved only once the switch is drawn")
        // A busy test run can delay the save; it comes, and only once.
        for _ in 0..<100 where writes == 0 { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(400))
        #expect(writes == 1)
        #expect(settings.string(forKey: StorageModel.chartKey) == others.prefix(3).last?.rawValue)
    }
}
