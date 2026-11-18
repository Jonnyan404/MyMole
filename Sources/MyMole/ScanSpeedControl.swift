import StorageKit
import SwiftUI

/// Scan speed as a form row: the slider on the control line, the level,
/// Reset and what the level does under it.
struct ScanSpeedControl: View {
    @Binding var performance: Int
    private var level: PerformanceLevel { PerformanceLevel(saved: performance) }
    /// Low Power Mode or heat holds scans at Balanced; read again when either changes.
    @State private var strained = PerformanceLevel.isStrained()

    var body: some View {
        DSFormRow("Scan speed") {
            Slider(value: Binding(get: { Double(level.rawValue) }, set: { performance = Int($0.rounded()) }),
                   in: 1...Double(PerformanceLevel.allCases.count), step: 1) {
                Text("Scan speed")
            } minimumValueLabel: {
                Image(systemName: "tortoise").help("Gentle")
            } maximumValueLabel: {
                Image(systemName: "hare").help("Hyperspeed: no limits")
            }
            .labelsHidden()
            .frame(maxWidth: 360)
            .accessibilityIdentifier("settings.scan-speed")
            .accessibilityValue("\(level.title), level \(level.rawValue) of \(PerformanceLevel.allCases.count)")
        } help: {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                HStack(spacing: 6) {
                    Text("\(level.title) · level \(level.rawValue) of \(PerformanceLevel.allCases.count)")
                        .fontWeight(.medium).foregroundStyle(.primary)
                    if level == .standard {
                        Text("Default")
                    } else {
                        Button("Reset") { performance = PerformanceLevel.standard.rawValue }
                            .buttonStyle(.link)
                            .accessibilityIdentifier("settings.scan-speed.reset")
                    }
                }
                Text(level.detail)
                Text(PerformanceSummary.scans(level))
                if strained, level > .balanced {
                    Text("Held at Balanced while this Mac is in Low Power Mode or running hot.")
                        .accessibilityIdentifier("settings.scan-speed.held")
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange).receive(on: RunLoop.main)) { _ in
            strained = PerformanceLevel.isStrained()
        }
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification).receive(on: RunLoop.main)) { _ in
            strained = PerformanceLevel.isStrained()
        }
    }
}
