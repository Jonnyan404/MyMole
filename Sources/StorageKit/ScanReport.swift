import Foundation

/// A report of a finished scan, for a CSV or PDF the user saves where they
/// choose. It's built from the map in memory: nothing is read from disk, and
/// nothing in a report can be opened back as a scan, so a report never
/// gives access to a file or a way to remove one.
public struct ScanReport: Sendable {
    public enum PathDetail: String, Sendable, CaseIterable {
        /// Every path whole, from "/".
        case full
        /// Paths from the scanned folder, which is named but not placed.
        case fromScanned
    }

    public struct Options: Sendable, Equatable {
        /// Folder levels below the scanned folder; nil for every level.
        public var depth: Int?
        /// The largest files listed; nil for all of them, 0 for none.
        public var files: Int?
        public var paths: PathDetail
        /// Whether hidden items, by their own name or a folder above them, are in it.
        public var hidden: Bool

        public init(depth: Int? = 2, files: Int? = 100, paths: PathDetail = .fromScanned, hidden: Bool = false) {
            self.depth = depth
            self.files = files
            self.paths = paths
            self.hidden = hidden
        }
    }

    public struct Row: Sendable, Equatable {
        public let isFolder: Bool
        public let path: String
        /// Levels below the scanned folder: 1 for what's directly in it.
        public let level: Int
        public let size: Int64
        /// Files inside, for a folder.
        public let files: Int?
        public let modified: Date?
        public let kind: FileKind?
    }

    public let options: Options
    /// The scanned folder as the report names it.
    public let scanned: String
    public let made: Date
    public let size: Int64
    public let fileCount: Int
    /// Whether the map was partial: folders that couldn't be read, or a stopped scan.
    public let incomplete: Bool
    public let folders: [Row]
    public let files: [Row]
    /// Folders and files the options left out, so the report can say so.
    public let foldersLeftOut: Int
    public let filesLeftOut: Int

    public init(root: Folder, options: Options, incomplete: Bool = false, home: String? = Home.path, now: Date = .now) {
        self.options = options
        made = now
        size = root.size
        fileCount = root.fileCount
        self.incomplete = incomplete
        let rootPath = root.path
        let name: (String) -> String = { path in
            switch options.paths {
            case .full: return path
            case .fromScanned:
                guard path != rootPath else { return root.name }
                let inside = rootPath == "/" ? String(path.dropFirst()) : String(path.dropFirst(rootPath.count + 1))
                return root.name + "/" + inside
            }
        }
        let shown: String
        switch options.paths {
        case .full: shown = rootPath
        case .fromScanned:
            shown = home.flatMap { h in rootPath == h ? "~" : rootPath.hasPrefix(h + "/") ? "~/" + rootPath.dropFirst(h.count + 1) : nil }
                ?? root.name
        }
        scanned = shown

        var folders: [Row] = [], allFiles: [Row] = []
        var foldersLeftOut = 0, filesLeftOut = 0
        let wantFiles = options.files != 0
        // Depth first, largest first, as the list shows them; a hidden folder
        // left out takes everything in it along.
        func walk(_ folder: Folder, level: Int, hidden: Bool) {
            for child in folder.subfolders {
                let childHidden = hidden || child.name.hasPrefix(".")
                if childHidden, !options.hidden {
                    foldersLeftOut += 1 + child.descendantFolderCount
                    filesLeftOut += wantFiles ? child.listedFileCount : 0
                    continue
                }
                if options.depth.map({ level + 1 <= $0 }) ?? true {
                    folders.append(Row(isFolder: true, path: name(child.path), level: level + 1, size: child.size,
                                       files: child.fileCount, modified: child.latestChange == .distantPast ? nil : child.latestChange,
                                       kind: child.inheritedKind))
                } else {
                    foldersLeftOut += 1
                }
                walk(child, level: level + 1, hidden: childHidden)
            }
            guard wantFiles else { return }
            let base = folder.path
            for file in folder.listedFiles {
                if file.name.hasPrefix(".") || hidden, !options.hidden { filesLeftOut += 1; continue }
                let path = base == "/" ? "/" + file.name : base + "/" + file.name
                allFiles.append(Row(isFolder: false, path: name(path), level: level + 1, size: file.size, files: nil,
                                    modified: file.modified == .distantPast ? nil : file.modified, kind: file.kind))
            }
        }
        walk(root, level: 0, hidden: false)
        allFiles.sort { $0.size != $1.size ? $0.size > $1.size : $0.path < $1.path }
        if let limit = options.files, allFiles.count > limit {
            filesLeftOut += allFiles.count - limit
            allFiles.removeLast(allFiles.count - limit)
        }
        self.folders = folders
        self.files = allFiles
        self.foldersLeftOut = foldersLeftOut
        self.filesLeftOut = filesLeftOut
    }

    // MARK: CSV

    /// One table: a row for the scan itself, then the folders, then the
    /// files. Sizes in bytes, dates in ISO 8601 (UTC), so a spreadsheet reads
    /// them the same in any locale. `kind` names a row's kind.
    public func csv(kind: (FileKind) -> String = { $0.title }, typeNames: (scan: String, folder: String, file: String) = ("scan", "folder", "file")) -> String {
        let iso = ISO8601DateFormatter()
        var out = "Type,Path,Bytes,Files,Modified,Kind\r\n"
        func line(_ cells: [String]) { out += cells.map(Self.cell).joined(separator: ",") + "\r\n" }
        line([typeNames.scan, scanned, String(size), String(fileCount), iso.string(from: made), ""])
        for r in folders + files {
            line([r.isFolder ? typeNames.folder : typeNames.file, r.path, String(r.size), r.files.map(String.init) ?? "",
                  r.modified.map(iso.string) ?? "", r.kind.map(kind) ?? ""])
        }
        return out
    }

    /// A CSV cell: quoted when it holds a comma, quote or line break, and
    /// kept from being read as a formula when it starts like one.
    static func cell(_ text: String) -> String {
        var t = text
        if let first = t.unicodeScalars.first, "=+-@\t\r".unicodeScalars.contains(first), Int64(t) == nil { t = "'" + t }
        guard t.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return t }
        return "\"" + t.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

extension Folder {
    /// Folders anywhere below this one.
    var descendantFolderCount: Int { subfolders.reduce(subfolders.count) { $0 + $1.descendantFolderCount } }
    /// Listed files in this folder and every folder below it.
    var listedFileCount: Int { subfolders.reduce(listedFiles.count) { $0 + $1.listedFileCount } }
}
