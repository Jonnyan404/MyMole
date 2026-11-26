import AppKit
import StorageKit
import SwiftUI

/// What MyMole keeps, where, what leaves the Mac and which permissions the
/// edition in use relies on, in words that can be checked against the app.
struct PrivacySection: View {
    var sandboxed = Edition.current.isSandboxed

    /// MyMole's own folder, inside the container in the App Store edition.
    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "MyMole")
    }

    /// The folder as the lists show paths, from "~" on in the home folder.
    static func shown(_ path: String, home: String = Home.path) -> String {
        path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    var body: some View {
        DSSection("Privacy", rows: false) {
            DSFormGrid {
                DSFormRow("Network") {
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        Text("MyMole makes no network connections, so nothing about your Mac or its files leaves it. Website and Support open in your browser.")
                        if sandboxed {
                            Text("This edition is in the App Sandbox without network access, so macOS would also block a connection.")
                        } else {
                            Text("This edition isn't in the App Sandbox, so macOS doesn't block connections for it; MyMole has no code that makes one.")
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                DSFormRow("Kept on this Mac") {
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        Text("Saved scans, keep lists, project rules and picture fingerprints for Similar Photos hold names and paths of your files. Cleanup history holds only counts and sizes.")
                            .fixedSize(horizontal: false, vertical: true)
                        DSPath(Self.shown(Self.folder.path))
                        Button("Show in Finder") {
                            let folder = Self.folder
                            if FileManager.default.fileExists(atPath: folder.path) {
                                NSWorkspace.shared.activateFileViewerSelecting([folder])
                            } else {
                                NSWorkspace.shared.open(folder.deletingLastPathComponent())
                            }
                        }
                        .help("Show MyMole's folder in Finder. Clear Saved Results in Loading and Memory removes the saved scans.")
                    }
                }
                DSFormRow("Reports") {
                    Text("A report of the disk map is written only where you save it, with the paths and hidden items you chose for it.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                DSFormRow("Only while open") {
                    Text("Large lists set aside on disk are removed when they close and at the next launch. Timings stay in memory until you quit.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                DSFormRow("Permissions") {
                    Group {
                        if sandboxed {
                            Text("Only the folders you give in Folder Access, and Downloads. Finder moves an app that needs an administrator password, once you let MyMole control it.")
                        } else {
                            Text("Full Disk Access and App Management, when you turn them on in System Settings. An administrator password for system files and system tasks.")
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
