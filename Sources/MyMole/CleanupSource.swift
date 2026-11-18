import StorageKit

/// The pane a cleanup run came from. History saves the English raw value,
/// so a run reads the same whatever the language it was made in; `title`
/// is what the interface shows.
enum CleanupSource: String, CaseIterable {
    case deepClean = "Deep Clean"
    case installers = "Installers"
    case uninstall = "Uninstall"
    case reset = "Reset"
    case removedApps = "Removed Apps"
    case projects = "Projects"
    case diskMap = "Disk Map"
    case systemClean = "System Clean"
    case optimize = "Optimize"
    case trash = "Trash"
    case startup = "Startup Items"
    case duplicates = "Duplicates"
    case similar = "Similar Photos"

    var title: String {
        switch self {
        case .deepClean: String(localized: "Deep Clean")
        case .installers: String(localized: "Installers")
        case .uninstall: String(localized: "Uninstall")
        case .reset: String(localized: "Reset")
        case .removedApps: String(localized: "Removed Apps")
        case .projects: String(localized: "Projects")
        case .diskMap: String(localized: "Disk Map")
        case .systemClean: String(localized: "System Clean")
        case .optimize: String(localized: "Optimize")
        case .trash: String(localized: "Trash")
        case .startup: String(localized: "Startup Items")
        case .duplicates: String(localized: "Duplicates")
        case .similar: String(localized: "Similar Photos")
        }
    }

    var symbol: String {
        switch self {
        case .deepClean: Pane.clean.symbol
        case .installers: Pane.installer.symbol
        case .uninstall, .removedApps: Pane.uninstall.symbol
        case .reset: "arrow.counterclockwise"
        case .projects: Pane.projects.symbol
        case .diskMap: Pane.diskMap.symbol
        case .systemClean: Pane.systemClean.symbol
        case .optimize: Pane.optimize.symbol
        case .trash: "trash"
        case .startup: Pane.startup.symbol
        case .duplicates: Pane.duplicates.symbol
        case .similar: "photo.on.rectangle"
        }
    }

    /// Runs that change things in place rather than moving files to the Trash.
    var movesToTrash: Bool { self != .optimize && self != .systemClean }
}

extension CleanupRecord {
    /// The pane the run came from, when it's one MyMole still has.
    var kind: CleanupSource? { CleanupSource(rawValue: source) }
    /// The run's name as shown, or the saved name for a pane MyMole no longer has.
    var title: String { kind?.title ?? source }
    var symbol: String { kind?.symbol ?? "trash" }
}
