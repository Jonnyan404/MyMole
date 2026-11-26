import AppKit
import StorageKit
import SwiftUI

/// What macOS counts as System Data, place by place: what it is, how much
/// it takes, its largest files, and where its space can be won back. It
/// only points the way; nothing here removes anything.
struct SystemDataSheet: View {
    let space: DiskSpace?
    /// Opens the pane where a place's space can be won back.
    let open: (Pane) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var measured: [String: SystemData.Measured] = [:]
    @State private var progress = ScanProgress()
    @State private var done = false
    private let places = SystemData.places()

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Text("System Data").font(.title2.bold())
            DSText("What macOS counts as System Data, place by place, with where its space can be won back. Nothing is removed here.", .metadata)
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.md) {
                    if let space {
                        row(title: String(localized: "Space macOS frees by itself"), bytes: space.purgeable,
                            detail: purgeableText(space), path: nil, largest: []) {
                            Button("Time Machine Settings") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.Time-Machine-Settings.extension") { NSWorkspace.shared.open(url) }
                            }
                        }
                        Divider()
                    }
                    ForEach(places) { place in
                        let m = measured[place.id]
                        row(title: place.title, bytes: m?.bytes, detail: place.detail, path: place.paths.first,
                            largest: m?.largest ?? [], state: state(m)) {
                            remedy(place)
                        }
                        Divider()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 440)
            DSActionGroup {
                if !done { DSLoading("Measuring…") }
            } trailing: {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(DS.Space.xl)
        .frame(width: DS.Size.reviewWidth)
        .dialogControls()
        .dialogKeyboard()
        .task { await measure() }
        .onDisappear { progress.cancel() }
    }

    private func measure() async {
        let (places, progress) = (places, progress)
        let stream = AsyncStream<SystemData.Measured> { c in
            Task.detached(priority: .utility) {
                _ = SystemData.measure(places, progress: progress) { c.yield($0) }
                c.finish()
            }
        }
        for await m in stream { measured[m.id] = m }
        done = true
    }

    private func state(_ m: SystemData.Measured?) -> String? {
        guard let m else { return String(localized: "Measuring…") }
        if m.bytes == nil { return m.partial ? String(localized: "Can't be read by MyMole") : String(localized: "Not on this Mac") }
        return m.partial ? String(localized: "Partly read: some folders inside are closed to MyMole") : nil
    }

    private func purgeableText(_ s: DiskSpace) -> String {
        let count = s.snapshots?.count ?? 0
        let base = String(localized: "Caches macOS manages and local Time Machine snapshots. Finder counts it as free; macOS removes it when space is needed.")
        return count == 0 ? base : base + " " + (count == 1 ? String(localized: "1 local Time Machine snapshot is on this disk.")
                                                     : String(localized: "\(count) local Time Machine snapshots are on this disk."))
    }

    @ViewBuilder private func remedy(_ place: SystemData.Place) -> some View {
        switch place.remedy {
        case .deepClean: Button("Open Deep Clean") { dismiss(); open(.clean) }
        case .developerTools: Button("Open Deep Clean") { dismiss(); open(.clean) }
            .help("Developer Tools is in Deep Clean")
        case .uninstall: Button("Open Uninstall") { dismiss(); open(.uninstall) }
        case .ownApp, .macOS, .restart:
            if let path = place.paths.first(where: { FileManager.default.fileExists(atPath: $0) }) {
                Button("Show in Finder") { FileActions.reveal([path]) }
            }
        }
    }

    private func row(title: String, bytes: Int64?, detail: String, path: String?, largest: [(path: String, bytes: Int64)],
                     state: String? = nil, @ViewBuilder action: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                if let bytes { Text(ByteSize.format(bytes)).monospacedDigit() }
            }
            DSText(detail, .metadata)
            if let path { DSPath(PrivacySection.shown(path), .mono, lines: 1) }
            if let state { DSText(state, .metadata) }
            if !largest.isEmpty {
                DisclosureGroup(String(localized: "Largest files")) {
                    ForEach(largest, id: \.path) { f in
                        HStack {
                            DSPath(PrivacySection.shown(f.path), .mono, lines: 1)
                            Spacer()
                            Text(ByteSize.format(f.bytes)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
                .font(.callout)
            }
            HStack { action() }
        }
    }
}
