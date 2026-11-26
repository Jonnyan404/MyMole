import AppKit
import StorageKit
import SwiftUI

// MARK: - Choosing inside entries

extension ProjectsModel {
    /// Where every removable entry sits, and which items and folders hold
    /// something chosen or left out. Rebuilt only after the footprints or
    /// the choice change.
    struct ChoiceIndex {
        var owners: [String: Chosen] = [:]
        /// Item id → entries chosen whole, and whether anything inside one
        /// is chosen or left out.
        var perItem: [String: (whole: Int, parts: Bool)] = [:]
        /// Folders with something chosen or left out inside them.
        var holding = Set<String>()
        /// Chosen path → bytes left out of it.
        var leftOut: [String: Int64] = [:]
        /// Folder → whether the small files read in it go.
        var small: [String: Check] = [:]
        /// What goes, once it's been asked for.
        var entries: [Chosen]?
    }

    var index: ChoiceIndex {
        if let choiceIndex { return choiceIndex }
        var ix = ChoiceIndex()
        for f in footprints {
            for item in f.items where item.removable {
                for e in item.entries { ix.owners[e.path] = Chosen(project: f.id, item: item, entry: e) }
            }
        }
        // Files chosen together share their folder: it's looked up once.
        var ownerOfFolder: [String: Chosen?] = [:]
        func owner(of p: String) -> Chosen? {
            if let hit = ix.owners[p] { return hit }
            let folder = (p as NSString).deletingLastPathComponent
            if let known = ownerOfFolder[folder] { return known }
            let found = Self.owner(of: folder, in: ix.owners)
            ownerOfFolder[folder] = .some(found)
            return found
        }
        for p in chosen.union(excluded) {
            guard let o = owner(of: p) else { continue }
            var counts = ix.perItem[o.item.id] ?? (0, false)
            if p == o.entry.path && chosen.contains(p) { counts.whole += 1 } else { counts.parts = true }
            ix.perItem[o.item.id] = counts
            var up = (p as NSString).deletingLastPathComponent
            // A folder noted already has those above it noted too.
            while up.count >= o.entry.path.count, ix.holding.insert(up).inserted {
                up = (up as NSString).deletingLastPathComponent
            }
        }
        for e in excluded {
            guard let o = owner(of: e), let m = marker(above: e, top: o.entry.path), m.chosen else { continue }
            ix.leftOut[m.path, default: 0] += partInfo[e]?.bytes ?? 0
        }
        for (folder, files) in smallFiles where !files.isEmpty {
            guard let o = owner(of: folder) else { continue }
            let follows = goesWith(folder, top: o.entry.path)
            let going = files.count { follows ? !excluded.contains($0) : chosen.contains($0) }
            ix.small[folder] = going == files.count ? .on : going == 0 ? .off : .mixed
        }
        choiceIndex = ix
        return ix
    }

    /// Whether what's directly in `folder` goes unless it's left out.
    private func goesWith(_ folder: String, top: String) -> Bool {
        chosen.contains(folder) || (!excluded.contains(folder) && marker(above: folder, top: top)?.chosen == true)
    }

    private static func owner(of path: String, in owners: [String: Chosen]) -> Chosen? {
        var p = path
        while true {
            if let hit = owners[p] { return hit }
            let parent = (p as NSString).deletingLastPathComponent
            if parent == p || parent.isEmpty { return nil }
            p = parent
        }
    }

    /// The removable entry `path` is, or lies inside.
    func owner(of path: String) -> Chosen? { Self.owner(of: path, in: index.owners) }

    /// The nearest folder above `path`, up to its entry, that's chosen or
    /// left out.
    func marker(above path: String, top: String) -> (path: String, chosen: Bool)? {
        var up = path
        while up.count > top.count {
            up = (up as NSString).deletingLastPathComponent
            if chosen.contains(up) { return (up, true) }
            if excluded.contains(up) { return (up, false) }
        }
        return nil
    }

    /// Whether `path` goes: chosen itself or inside something chosen and
    /// not left out; partly when something inside it differs.
    func state(of path: String) -> Check {
        guard !isKeptElsewhere(path), let o = owner(of: path) else { return .off }
        let goes = chosen.contains(path) || (!excluded.contains(path) && marker(above: path, top: o.entry.path)?.chosen == true)
        if index.holding.contains(path) { return .mixed }
        return goes ? .on : .off
    }

    /// Chooses or unchooses one entry, folder or file; partly chosen, it's
    /// chosen whole. Inside a chosen folder, unchoosing leaves it out: the
    /// folder still goes, it stays.
    func toggle(path: String) {
        // What Deep Clean keeps is never chosen here.
        guard !isKeptElsewhere(path), let o = owner(of: path) else { return }
        let top = o.entry.path
        let wasOff = state(of: path) != .on
        // Only what's above the path decides; what was inside it starts over.
        let above = marker(above: path, top: top)
        var c = chosen.filter { !$0.hasPrefix(path + "/") }
        var x = excluded.filter { !$0.hasPrefix(path + "/") }
        if wasOff {
            x.remove(path)
            if above?.chosen != true { c.insert(path) }
        } else {
            c.remove(path)
            if above?.chosen == true { x.insert(path) }
        }
        note(path, in: top)
        excluded = x
        chosen = c
    }

    /// Whether the small files of `folder`, counted together in the list, go.
    func smallFilesState(in folder: String) -> Check {
        guard !isKeptElsewhere(folder), let o = owner(of: folder) else { return .off }
        return index.small[folder] ?? (goesWith(folder, top: o.entry.path) ? .on : .off)
    }

    /// Chooses or unchooses the small files of `folder`: the ones there now,
    /// read off the main thread. A file made later isn't one of them.
    @discardableResult
    func toggleSmallFiles(in folder: String) -> Task<Void, Never>? {
        guard !trashing, !isKeptElsewhere(folder), let o = owner(of: folder), !readingSmallFiles.contains(folder) else { return nil }
        let on = smallFilesState(in: folder) != .on
        let top = o.entry.path
        let version = contentsVersions[top, default: 0]
        let read = readSmallFiles
        readingSmallFiles.insert(folder)
        return Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { read(folder) }.value
            guard let self else { return }
            readingSmallFiles.remove(folder)
            // The folder was measured again, or a move began, meanwhile.
            guard contentsVersions[top, default: 0] == version, !trashing, owner(of: folder)?.entry.path == top else { return }
            setSmallFiles(found ?? [], in: folder, top: top, on: on)
        }
    }

    private func setSmallFiles(_ found: [FootprintEntry], in folder: String, top: String, on: Bool) {
        let files = found.filter { !isKeptElsewhere($0.path) }
        guard !files.isEmpty else {
            // Gone or unreadable: the folder is measured again.
            dropContents(touching: [folder])
            return
        }
        for e in files { partInfo[e.path] = e }
        let paths = Set(files.map(\.path))
        // Chosen or left out before, and no longer one of them.
        let gone = smallFiles[folder, default: []].subtracting(paths)
        smallFiles[folder] = paths
        let follows = goesWith(folder, top: top)
        var c = chosen.subtracting(gone)
        var x = excluded.subtracting(gone)
        if on {
            x.subtract(paths)
            if !follows { c.formUnion(paths) }
        } else {
            c.subtract(paths)
            if follows { x.formUnion(paths) }
        }
        excluded = x
        chosen = c
        choiceIndex = nil
    }

    /// Left-out paths only mean something inside a chosen one.
    func tidyExcluded() {
        let kept = excluded.filter { e in
            guard let o = owner(of: e) else { return false }
            var up = e
            while up.count > o.entry.path.count {
                up = (up as NSString).deletingLastPathComponent
                if chosen.contains(up) { return true }
            }
            return false
        }
        if kept.count != excluded.count { excluded = kept }
    }

    /// Remembers the size of a part as it's chosen or left out: from the
    /// measured tree, or from the file or folder itself.
    private func note(_ p: String, in entry: String) {
        guard p != entry, partInfo[p] == nil else { return }
        if let f = contents[entry]?.find(path: p) {
            partInfo[p] = FootprintEntry(path: p, bytes: f.size, modified: f.latestChange, isDirectory: true, reclaim: f.reclaim)
            return
        }
        let name = (p as NSString).lastPathComponent
        let listed = contents[entry]?.find(path: (p as NSString).deletingLastPathComponent)?.listedFiles.first { $0.name == name }
        let listedSize = listed?.size
        let listedReclaim = listed?.reclaim.holding(blocksOf: p)
        // Its entry wasn't opened: read and measured off the main thread,
        // where a disk that stops answering can't hold up the window, and
        // the totals catch up when it's done. Until then it counts nothing.
        partInfo[p] = FootprintEntry(path: p, bytes: 0, modified: .distantPast)
        Task.detached(priority: .userInitiated) { [weak self] in
            var st = stat()
            guard lstat(p, &st) == 0 else {
                await self?.measuredPart(p, nil)
                return
            }
            let measured: FootprintEntry
            if st.st_mode & S_IFMT == S_IFDIR {
                let f = StorageScanner.scan(path: p, workers: 2).root
                measured = FootprintEntry(path: p, bytes: f.size, modified: f.latestChange, isDirectory: true, reclaim: f.reclaim)
            } else {
                measured = FootprintEntry(path: p, bytes: listedSize ?? Int64(st.st_blocks) * 512,
                                          modified: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)),
                                          isDirectory: false, reclaim: listedReclaim ?? Reclaim.file(at: p))
            }
            await self?.measuredPart(p, measured)
        }
    }

    private func measuredPart(_ path: String, _ e: FootprintEntry?) {
        partInfo[path] = e
        choiceIndex = nil
        partSizes += 1
    }

    /// Measures what's inside an entry, once, for opening it in the list.
    func loadContents(_ path: String) {
        guard contents[path] == nil, loadingContents[path] == nil else { return }
        let run = UUID()
        loadingContents[path] = run
        contentsVersions[path] = contentsVersions[path, default: 0]
        let level = PerformanceLevel.inEffect()
        let workers = level.workers(background: false)
        let read = readContents
        Task.detached(priority: level.priority(background: false)) { [weak self] in
            let tree = read(path, workers)
            await self?.contentsLoaded(path, tree, run: run)
        }
    }

    private func contentsLoaded(_ path: String, _ tree: Folder, run: UUID) {
        guard loadingContents[path] == run else { return }
        loadingContents[path] = nil
        keepContents(tree, at: path)
    }

    /// An open native branch can retain its tree after cache eviction. Bring
    /// that same measured tree back before refreshing one of its subfolders.
    func keepContents(_ tree: Folder, at path: String) {
        guard tree.path == path else { return }
        contents[path] = tree
        contentsRevision += 1
        contentsOrder.removeAll { $0 == path }
        contentsOrder.append(path)
        while contentsOrder.count > Self.keptContents {
            contents.removeValue(forKey: contentsOrder.removeFirst())
        }
    }

    /// Opened entries kept measured at once.
    static let keptContents = 12

    /// Forgets measured contents that changed, so they're measured again.
    func dropContents(touching paths: some Collection<String>) {
        let stale = Set(contents.keys).union(loadingContents.keys).union(contentsVersions.keys).filter { e in paths.contains { $0 == e || $0.hasPrefix(e + "/") || e.hasPrefix($0 + "/") } }
        for folder in smallFiles.keys where stale.contains(where: { folder == $0 || folder.hasPrefix($0 + "/") }) {
            smallFiles[folder] = nil
        }
        for e in stale {
            contents.removeValue(forKey: e)
            loadingContents[e] = nil
            contentsVersions[e, default: 0] += 1
        }
        contentsOrder.removeAll { stale.contains($0) }
        if !stale.isEmpty { contentsRevision += 1 }
    }
}
