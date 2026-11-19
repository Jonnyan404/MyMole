import AppKit
import StorageKit
import SwiftUI

/// Files in iCloud Drive that are downloaded to this Mac. Removing a
/// download keeps the file in iCloud Drive and in Finder; opening it
/// downloads it again. Nothing starts chosen, and a file that isn't
/// uploaded in full can't be chosen.
struct CloudDownloadsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var items: [CloudDownloads.Item]?
    @State private var chosen = Set<String>()
    @State private var selection = Set<String>()
    @State private var confirming = false
    @State private var working = false
    @State private var result: String?

    private var chosenItems: [CloudDownloads.Item] { (items ?? []).filter { chosen.contains($0.path) && $0.uploaded } }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Text("iCloud Downloads").font(.title2.bold())
            DSText("Files in iCloud Drive that are also downloaded to this Mac. Removing a download keeps the file in iCloud Drive and in Finder, with a cloud icon; opening it downloads it again. Nothing goes to the Trash.", .metadata)
            if let result { DSNotice(.info, result) }
            if let items {
                if items.isEmpty {
                    ContentUnavailableView("No Downloaded iCloud Files", systemImage: "icloud",
                                           description: Text("Nothing in iCloud Drive of 1 MB or more is downloaded to this Mac."))
                        .frame(height: 380)
                } else {
                    FileTable(
                        rows: items.map(row), columns: [.name, .size, .modified, .location],
                        titles: [.modified: String(localized: "Last Opened")],
                        autosave: "clouddownloads.list", selection: $selection, marks: chosen,
                        onToggleMark: toggle,
                        onOpen: { FileActions.reveal($0) },
                        onSetMarks: { ids, checked in for id in ids where chosen.contains(id) != checked { toggle(id) } })
                        .frame(height: 380)
                }
            } else {
                DSLoading("Looking in iCloud Drive…").frame(height: 380)
            }
            DSActionGroup {
                if !chosenItems.isEmpty {
                    DSText(String(localized: "\(chosenItems.count) chosen · \(ByteSize.format(chosenItems.reduce(0) { $0 + $1.bytes }))"), .metadata)
                }
            } trailing: {
                Button("Remove Downloads…") { confirming = true }
                    .disabled(chosenItems.isEmpty || working)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(DS.Space.xl)
        .frame(width: DS.Size.reviewWidth)
        .dialogControls()
        .dialogKeyboard()
        .actionConfirmation(
            chosenItems.count == 1 ? String(localized: "Remove 1 download from this Mac?") : String(localized: "Remove \(chosenItems.count) downloads from this Mac?"),
            isPresented: $confirming, always: true, button: String(localized: "Remove Downloads"),
            message: String(localized: "They stay in iCloud Drive and in Finder. Opening one downloads it again, which needs the internet then. Each is checked again first: one that changed or isn't uploaded in full stays.")
        ) { Task { await remove() } }
        .task { await load() }
    }

    private func toggle(_ id: String) {
        guard let item = items?.first(where: { $0.path == id }), item.uploaded, !working else { return }
        if chosen.contains(id) { chosen.remove(id) } else { chosen.insert(id) }
    }

    private func row(_ item: CloudDownloads.Item) -> FileRow {
        var r = FileRow(id: item.path, name: item.name, size: item.bytes)
        r.modified = item.lastOpened
        r.location = PrivacySection.shown((item.path as NSString).deletingLastPathComponent)
        r.symbol = "icloud.and.arrow.down"
        r.canChoose = item.uploaded
        r.choiceHelp = item.uploaded ? nil : String(localized: "Not uploaded in full yet, so it stays on this Mac.")
        if !item.uploaded { r.badge = String(localized: "Uploading") }
        return r
    }

    private func load() async {
        items = await Task.detached(priority: .userInitiated) { CloudDownloads.list() }.value
    }

    private func remove() async {
        let paths = chosenItems.map(\.path)
        working = true
        let r = await Task.detached(priority: .userInitiated) { CloudDownloads.remove(paths) }.value
        working = false
        chosen.subtract(r.removed)
        let freed = (items ?? []).filter { r.removed.contains($0.path) }.reduce(0) { $0 + $1.bytes }
        var text = r.removed.count == 1
            ? String(localized: "Removed 1 download · \(ByteSize.format(freed)) free on this Mac")
            : String(localized: "Removed \(r.removed.count) downloads · \(ByteSize.format(freed)) free on this Mac")
        if !r.failed.isEmpty { text += " · " + String(localized: "\(r.failed.count) stayed: \(r.failed.values.sorted().first ?? "")") }
        result = text
        await load()
    }
}
