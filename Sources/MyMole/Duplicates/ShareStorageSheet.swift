import StorageKit
import SwiftUI

/// Sharing storage instead of removing copies, said before anything is
/// done: every file stays, they take the space of one, the replaced copies
/// go to the Trash, and what can't share is named with the reason.
struct ShareStorageSheet: View {
    let model: DuplicatesModel
    @Environment(\.dismiss) private var dismiss
    @State private var plan: CloneSharing.Plan?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Text("Share Storage").font(.title2.bold())
            DSText("Instead of removing the chosen copies, each one becomes a clone of the copy that stays.", .lead)
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                point("doc.on.doc", "Every file stays where it is, with its own name, contents, dates and tags. Nothing changes in the apps that use them.")
                point("externaldrive", "They take the space of one copy on the disk, as copies made with Finder's Duplicate do. If you change one later, it gets space of its own again; the others stay as they are.")
                point("trash", "The copies being replaced go to the Trash, named “before sharing”. The space is free once the Trash is emptied.")
            }
            if let plan {
                Divider()
                if plan.shares.isEmpty {
                    DSNotice(.warning, "None of the chosen copies can share their storage.")
                } else {
                    DSText(plan.shares.count == 1
                           ? String(localized: "1 copy shares with the copy that stays · \(ByteSize.format(plan.bytes)) frees once the Trash is emptied")
                           : String(localized: "\(plan.shares.count) copies share with the copies that stay · \(ByteSize.format(plan.bytes)) frees once the Trash is emptied"), .lead)
                }
                if !plan.skipped.isEmpty {
                    DSText(plan.skipped.count == 1 ? String(localized: "1 copy stays as it is:") : String(localized: "\(plan.skipped.count) copies stay as they are:"), .metadata)
                    ScrollView {
                        VStack(alignment: .leading, spacing: DS.Space.xs) {
                            ForEach(plan.skipped.keys.sorted(), id: \.self) { path in
                                VStack(alignment: .leading, spacing: 0) {
                                    DSPath(PrivacySection.shown(path), .mono, lines: 1)
                                    DSText(plan.skipped[path]?.text ?? "", .metadata)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                }
            } else {
                DSLoading("Checking which copies can share…").frame(height: 60)
            }
            DSActionGroup {
                EmptyView()
            } trailing: {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Share Storage") {
                    if let plan { model.share(plan) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(plan?.shares.isEmpty ?? true)
            }
        }
        .padding(DS.Space.xl)
        .frame(width: DS.Size.reviewWidth)
        .dialogControls()
        .dialogKeyboard()
        .task { plan = await model.sharePlan() }
    }

    private func point(_ symbol: String, _ text: LocalizedStringResource) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20)
        }
    }
}
