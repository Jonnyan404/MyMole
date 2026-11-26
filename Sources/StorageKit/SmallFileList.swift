import Foundation

/// The files a scan counts together in a folder, read from the disk when
/// they're asked for one by one.
public enum SmallFileList {
    /// The plain files directly in `folder` that use less than
    /// `Folder.listedFileSize` on disk, hidden ones too; links and folders
    /// aren't files. Nil when the folder can't be read whole, and a folder
    /// that's a link isn't followed.
    public static func read(in folder: String) -> [FootprintEntry]? {
        var found: [FootprintEntry] = []
        let outcome = DirectoryReader.read(folder) { e in
            guard e.kind == .file, e.allocated < Folder.listedFileSize else { return }
            let path = folder + "/" + e.name
            found.append(FootprintEntry(
                path: path, bytes: e.allocated, modified: Date(timeIntervalSince1970: e.modified), isDirectory: false,
                reclaim: e.reclaim.holding(blocksOf: path)))
        }
        return outcome == .ok ? found : nil
    }
}
