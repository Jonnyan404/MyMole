#if SMOKE
import AppKit
import StorageKit

/// The UI smoke build's pane pictures:
/// on a synthetic home, the app opens every pane at the smallest and a wide
/// window, draws its own window into a PNG in the run folder and lists every
/// control that a pane pushed sideways out of its viewport. Like the resize
/// check it needs neither Accessibility nor Screen Recording; then it quits.
@MainActor
enum ShotExercise {
    static let order: [Pane] = [.dashboard, .clean, .systemClean, .uninstall, .startup, .optimize, .projects,
                                .installer, .duplicates, .diskMap, .status, .history, .settings]

    static func runIfAsked(_ app: AppModel) {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MYMOLE_SMOKE_SHOTS"] == "1", let run = try? SyntheticRun.current() else { return }
        let look = environment["MYMOLE_SMOKE_SHOTS_LOOK"] ?? "shot"
        Task { @MainActor in
            let folder = URL(fileURLWithPath: run.root).appending(path: "shots")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var report: [String] = [] {
                didSet { try? (report.joined(separator: "\n") + "\n").write(to: folder.appending(path: "\(look)-report.txt"), atomically: true, encoding: .utf8) }
            }
            // Launch's scans fill the panes first, as a user meets them.
            try? await Task.sleep(for: .seconds(12))
            for (size, frame) in [("wide", NSSize(width: 1_440, height: 900)), ("small", NSSize(width: 980, height: 700))] {
                guard let window = mainWindow() else { report.append("no window"); break }
                window.setFrame(NSRect(origin: window.frame.origin, size: frame), display: true)
                app.pane = .history
                try? await Task.sleep(for: .seconds(1))
                for (index, pane) in order.enumerated() where pane.isAvailable {
                    app.pane = pane
                    try? await Task.sleep(for: .seconds(2.5))
                    let name = String(format: "%@-%@-%02d-%@", look, size, index + 1, pane.rawValue)
                    report += capture(window, as: name, in: folder)
                }
                app.pane = .settings
                for query in ["Performance", "Background", "Folder"] {
                    app.settingsQuery = query
                    try? await Task.sleep(for: .seconds(1.5))
                    report += capture(window, as: "\(look)-\(size)-13-settings-\(query.lowercased())", in: folder)
                }
                app.settingsQuery = ""
            }
            report.append("shots done")
            NSApp.terminate(nil)
        }
    }

    private static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && !($0 is NSPanel) && $0.contentView != nil && $0.frame.width > 400 }
    }

    /// The window as the window server composited it, glass and toolbar
    /// included, and what it clips. An app may picture its own windows
    /// without Screen Recording; the call is looked up at run time because
    /// the SDK no longer declares it.
    private static func capture(_ window: NSWindow, as name: String, in folder: URL) -> [String] {
        typealias WindowImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let optionIncludingWindow: UInt32 = 1 << 3, ignoreFramingAndBest: UInt32 = 1 | 8
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"),
              let image = unsafeBitCast(symbol, to: WindowImage.self)(.null, optionIncludingWindow, UInt32(window.windowNumber), ignoreFramingAndBest)?
                .takeRetainedValue()
        else { return ["\(name) no-image"] }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: folder.appending(path: name + ".png"))
        let (problems, controls) = clipped(window)
        return ["\(name) controls=\(controls)"] + problems.map { "\(name) clipped \($0)" }
    }

    /// Controls outside their viewport's sides; rows and lists scroll by design.
    private static func clipped(_ window: NSWindow) -> ([String], Int) {
        let controls: Set<NSAccessibility.Role> = [.button, .textField, .popUpButton, .checkBox, .radioButton, .comboBox, .slider]
        let skipped: Set<NSAccessibility.Role> = [.table, .outline, .row, .list, .scrollBar]
        var problems: [String] = []
        var stack: [(Any, CGRect)] = [(window, window.frame)]
        var seen = 0, checked = 0
        while let (element, viewport) = stack.popLast(), seen < 20_000 {
            seen += 1
            guard let node = element as? NSAccessibilityProtocol else { continue }
            let role = node.accessibilityRole() ?? .unknown
            if skipped.contains(role) { continue }
            var visible = viewport
            let rect = node.accessibilityFrame()
            if role == .scrollArea { visible = viewport.intersection(rect) }
            if controls.contains(role) { checked += 1 }
            if controls.contains(role), rect.width > 0, rect.height > 0, rect.maxY > visible.minY, rect.minY < visible.maxY,
               rect.minX < visible.minX - 2 || rect.maxX > visible.maxX + 2 {
                problems.append("\(node.accessibilityLabel() ?? role.rawValue) width \(Int(rect.width)) outside \(Int(visible.width))")
            }
            for child in node.accessibilityChildren() ?? [] { stack.append((child, visible)) }
        }
        return (problems, checked)
    }
}
#endif
