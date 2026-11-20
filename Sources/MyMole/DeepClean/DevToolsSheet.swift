import AppKit
import StorageKit
import SwiftUI

/// Docker, Xcode's simulators, Android and virtual machines as their own
/// tools list them, with sizes. What rebuilds by itself starts chosen,
/// what may hold work is chosen only by the user, and what is in use or
/// holds data is only shown. Each removal runs the tool's own command.
struct DevToolsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model = DevToolsModel()
    @State private var selection = Set<String>()
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Text("Developer Tools").font(.title2.bold())
            DSText(
                Edition.current.isSandboxed
                    ? "Virtual machines, AI models and Android's files, with their sizes, to look at. The App Store edition can't run Docker, Xcode's or Android's tools, so it removes nothing here; the direct edition removes what you choose with each tool's own command, and moves AI models to the Trash."
                    : "As each tool lists them. Only what the tool builds or downloads again starts chosen. What may hold your work is chosen only by you, and what's in use or holds data is only shown. Each item goes through the tool's own command and is deleted for good; AI models go to the Trash.",
                .metadata)
            if let listing = model.listing {
                ForEach(listing.notes, id: \.self) { DSNotice(.info, $0) }
                if let report = model.report, !report.failed.isEmpty || !report.refused.isEmpty {
                    DSNotice(.warning, reportText(report))
                }
                FileTable(
                    rows: listing.items.map(row), columns: [.name, .size, .kind, .location],
                    titles: [.kind: String(localized: "What"), .location: String(localized: "Tool")],
                    autosave: "devtools.list", selection: $selection, marks: model.chosen,
                    onToggleMark: { model.toggle($0) },
                    onOpen: { ids in FileActions.reveal(ids.compactMap { id in listing.items.first { $0.id == id }?.path }) },
                    onSetMarks: { ids, checked in
                        for id in ids where model.chosen.contains(id) != checked { model.toggle(id) }
                    })
                    .frame(height: 380)
            } else {
                DSLoading("Asking each tool what it keeps…").frame(height: 380)
            }
            DSActionGroup {
                if !model.chosen.isEmpty {
                    DSText(String(localized: "\(model.chosenItems.count) chosen · \(ByteSize.format(model.chosenBytes))"), .metadata)
                }
            } trailing: {
                Button("Look Again") { Task { await model.load() } }
                    .disabled(model.loading || model.removing)
                Button("Remove \(model.chosenItems.count)…") { confirming = true }
                    .disabled(model.chosenItems.isEmpty || model.loading || model.removing)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(DS.Space.xl)
        .frame(width: DS.Size.reviewWidth)
        .dialogControls()
        .dialogKeyboard()
        .actionConfirmation(
            String(localized: "Remove \(model.chosenItems.count) items for good?"), isPresented: $confirming, action: .devTools,
            big: ConfirmationSettings.isBig(bytes: model.chosenBytes, count: model.chosenItems.count),
            button: String(localized: "Remove"),
            message: confirmText
        ) { Task { await model.removeChosen() } }
        .task { await model.load() }
    }

    private var confirmText: String {
        let trash = model.chosenToTrash, all = model.chosenItems.count
        if trash == all {
            return String(localized: "AI models go to the Trash, with every file that's only theirs; layers other models use stay. Each list is read again first; anything that started or changed since is left alone.")
        }
        if trash == 0 {
            return String(localized: "Each goes through its tool's own command and can't be undone. Each tool's list is read again first; anything that started or changed since is left alone.")
        }
        return String(localized: "AI models go to the Trash; the rest go through each tool's own command and can't be undone. Each list is read again first; anything that started or changed since is left alone.")
    }

    private func row(_ item: DevTools.Item) -> FileRow {
        var r = FileRow(
            id: item.id, name: item.name, size: item.bytes, kind: item.detail, location: item.source.title,
            symbol: symbol(item.source), subtitle: item.reason,
            canChoose: model.canChoose(item),
            choiceHelp: model.canChoose(item) ? nil : String(localized: "Only shown: \(item.reason)"))
        r.badge = switch item.handling {
        case .recommend: String(localized: "Rebuilt")
        case .offer: String(localized: "Your choice")
        case .show: String(localized: "Shown only")
        }
        return r
    }

    private func symbol(_ source: DevTools.Source) -> String {
        switch source {
        case .docker: "shippingbox"
        case .simulator: "iphone"
        case .android: "apps.iphone"
        case .virtualMachine: "desktopcomputer"
        case .aiModels: "cpu"
        }
    }

    private func reportText(_ r: DevTools.Report) -> String {
        var parts: [String] = []
        if !r.refused.isEmpty { parts.append(String(localized: "\(r.refused.count) changed since the list was read and stayed.")) }
        if !r.failed.isEmpty { parts.append(String(localized: "\(r.failed.count) couldn't be removed: \(r.failed.values.sorted().prefix(2).joined(separator: "; "))")) }
        return parts.joined(separator: " ")
    }
}
