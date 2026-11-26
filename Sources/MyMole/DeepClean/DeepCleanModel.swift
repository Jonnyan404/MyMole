import AppKit
import StorageKit
import SwiftUI

/// State of the Deep Clean pane: caches, logs and tool downloads found by
/// MyMole's own rules, what's chosen, the user's keep list, and what the
/// last move can undo. Lives on `AppModel`, so leaving the pane keeps it.
@MainActor
@Observable
final class DeepCleanModel {
    struct Notice: Equatable {
        let text: String
        let canUndo: Bool
    }

    private(set) var candidates: [CleanCandidate] = []
    private(set) var scanning = false
    private(set) var trashing = false
    private(set) var startedAt: Date?
    /// While scanning: how far it has come, 0 to 1.
    private(set) var scanFraction: Double?
    /// While the first scan runs and nothing is listed yet: what it has
    /// found so far, shown but not offered for choosing until it's complete.
    private(set) var preview: [CleanCandidate] = []
    private(set) var scannedAt: Date?
    /// The list is the saved result of an earlier launch, or something
    /// changed since it was measured.
    private(set) var isStale = false
    private(set) var notice: Notice?
    /// Current activity while visible; newly active caches lose their old choices.
    private(set) var running: Set<String> = []
    /// Places the last scan couldn't read, such as app containers without
    /// Full Disk Access: what's there isn't listed.
    private(set) var unreadablePlaces: [String] = []
    private(set) var keepFile: KeepListFile
    var keep: CleanKeepList { keepFile.list }
    /// Paths kept in Projects, as last read: shown as kept and never chosen.
    /// The move reads the project rules again itself.
    private(set) var keptInProjects = CleanKeepList()
    /// Kept here or in Projects: itself, inside something kept, or holding it.
    func isKept(_ path: String) -> Bool { keep.protects(path) || keptInProjects.protects(path) }

    /// Why `c` is chosen or not, in the words the list and its explanation use.
    func choiceReason(_ c: CleanCandidate) -> String {
        if keep.protects(c.path) { return String(localized: "Not chosen: it's on your keep list.") }
        if keptInProjects.protects(c.path) { return String(localized: "Not chosen: it's kept in Projects, or holds something that is.") }
        if isRunning(c) { return String(localized: "Not chosen: the app it belongs to is open.") }
        if isJustWritten(c) { return String(localized: "Not chosen: something wrote to it in the last few minutes.") }
        if c.safety == .review { return String(localized: "Not chosen for you: look at it first.") }
        return chosen.contains(c.path) ? String(localized: "Chosen: it's rebuilt by itself.") : String(localized: "Rebuilt by itself; you unticked it.")
    }
    /// Set when the keep list couldn't be read: nothing is moved until it can.
    var keepError: Problem? { keepFile.readError }
    /// Set when the user's change to the list couldn't be saved: nothing is
    /// moved until it is, or the change is given up.
    var keepSaveError: Problem? { keepFile.saveError }
    var chosen = Set<String>()
    var selection = Set<String>()

    let home: String
    /// Temporary folders outside the home folder to look in as well, by
    /// their real paths; none unless the app names them.
    let temporary: [String]
    /// The temporary folders are being looked through, after the scan
    /// itself is in: they hold far more files than the caches, so what was
    /// found in the home folder is shown and can be chosen meanwhile, and
    /// neither the launch's other scans nor Smart Scan wait for them.
    private(set) var lookingInTemporary = false
    private(set) var temporaryJob: Task<Void, Never>?
    @ObservationIgnored private var temporaryRun: ScanProgress?
    @ObservationIgnored private var temporaryDeferred = false
    /// Looks through the temporary folders; tests hold it to see what waits.
    @ObservationIgnored var findTemporary: @Sendable ([String], ScanProgress) -> TemporaryListing = {
        CleanScanner.temporary(in: $0, progress: $1, workers: PerformanceLevel.inEffect().workers(background: true), inUse: ProcessPaths.inUse())
    }
    /// Where the running programs are at work, read again right before a
    /// temporary item moves; tests give their own.
    @ObservationIgnored var programsAtWork: @Sendable () -> Set<String>? = { ProcessPaths.inUse() }
    /// The room taken in the temporary folders by what's still in use and
    /// so isn't listed, so the list doesn't read as all there is.
    private(set) var temporaryInUse: Int64 = 0
    private let base: URL
    private let keepURL: URL
    /// Where the project rules are saved.
    private let projectRules: URL
    private let logURL: URL
    private let runningApps: @MainActor () -> Set<String>
    /// Names of command-line tools running, nil when they can't be read.
    private let runningTools: @Sendable () -> Set<String>?
    @ObservationIgnored private var activityRevision: UInt64 = 0
    private var tools: Set<String>? = []
    private var progress: ScanProgress?
    /// A move that can still be put back: what moved, the entries it
    /// took off the list, and what each freed, by where it was.
    private struct Run: UndoableRun {
        let id: UUID
        var records: [TrashRecord]
        var candidates: [CleanCandidate]
        var sizes: [String: Int64]
    }

    private var shelf = UndoShelf<Run>()
    /// The move an Undo works on: one History asked for, or else the latest.
    private var target: UUID?
    private var undone: Run? { target.flatMap(shelf.run) ?? shelf.latest }
    private var undoRecords: [TrashRecord] {
        get { undone?.records ?? [] }
        set { if let id = undone?.id { shelf.update(id) { $0.records = newValue } } }
    }
    private var undoCandidates: [CleanCandidate] {
        get { undone?.candidates ?? [] }
        set { if let id = undone?.id { shelf.update(id) { $0.candidates = newValue } } }
    }
    private var undoSizes: [String: Int64] {
        get { undone?.sizes ?? [:] }
        set { if let id = undone?.id { shelf.update(id) { $0.sizes = newValue } } }
    }
    /// The history record of the move Undo would put back.
    var undoLogID: UUID? { undone?.id }
    /// Something from the last move can still be put back, and nothing else runs.
    var canUndo: Bool { !undoRecords.isEmpty && !trashing }
    /// Whether the move of this history record can still be put back.
    func canUndo(run id: UUID) -> Bool { !(shelf.run(id)?.records.isEmpty ?? true) && !trashing }
    private let trash: TrashBackend
    /// Where its moves and Undos wait their turn among every pane's.
    var jobs: TrashJobs = .shared
    private var scannedThisLaunch = false

    /// A cache written this recently is probably in use by something
    /// running in the background, which the check for running apps can't
    /// see: it's left unticked, as a running app's is.
    nonisolated static let quietFor: TimeInterval = 10 * 60
    private let quiet: TimeInterval

    init(
        home: String = Home.path, temporary: [String] = [], base: URL = CleanStore.defaultBase, keepURL: URL = CleanKeepList.defaultURL,
        logURL: URL = CleanupLog.defaultURL,
        runningApps: @escaping @MainActor () -> Set<String> = {
            #if SMOKE
            return []
            #else
            Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            #endif
        },
        runningTools: @escaping @Sendable () -> Set<String>? = RunningTools.names,
        trash: TrashBackend = .live, projectRules: URL = ProjectStore.defaultBase,
        quietFor: TimeInterval = DeepCleanModel.quietFor
    ) {
        self.trash = trash
        self.quiet = quietFor
        self.projectRules = projectRules
        self.home = home
        self.temporary = temporary
        self.base = base
        self.keepURL = keepURL
        self.logURL = logURL
        self.runningApps = runningApps
        self.runningTools = runningTools
        keepFile = KeepListFile(url: keepURL)
        restoreJob = Task { [weak self] in
            let saved = await Task.detached(priority: .userInitiated) { CleanStore.load(home: home, base: base) }.value
            self?.restore(saved)
        }
        // Kept in another pane or in Projects: marked here at once.
        keepWatch = NotificationCenter.default.addObserver(forName: KeepChanges.name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.keptElsewhereChanged() }
        }
    }

    @ObservationIgnored private var keepWatch: NSObjectProtocol?

    private func keptElsewhereChanged() {
        if !keepFile.hasUnsavedChange { keepFile.reload() }
        let rules = projectRules
        Task {
            let kept = await Task.detached(priority: .utility) { (try? ProjectStore.loadRules(base: rules))?.keepPaths }.value
            if let kept { keptInProjects = CleanKeepList(paths: kept) }
            chosen = chosen.filter { !isKept($0) }
        }
    }

    /// Reading the saved result off the main actor, so a caller can wait for it.
    private(set) var restoreJob: Task<Void, Never>?

    /// Shows the saved result once read, unless a scan has started first:
    /// that scan's result, or its stop, decides what's shown.
    private func restore(_ saved: CleanStore.Saved?) {
        guard let saved, !scannedThisLaunch, scannedAt == nil else { return }
        candidates = saved.candidates
        scannedAt = saved.date
        isStale = true
    }

    // MARK: Scanning

    static let freshFor: TimeInterval = 10 * 60
    private(set) var scanJob: Task<Void, Never>?

    func scanIfNeeded() {
        guard !scanning else { return }
        // A scan started ahead of need left the temporary folders for when
        // the pane is opened: nothing at launch reads them.
        if temporaryDeferred, !lookingInTemporary, !trashing {
            temporaryDeferred = false
            lookInTemporary(background: false)
        }
        if scannedThisLaunch, !isStale, let at = scannedAt, Date().timeIntervalSince(at) < Self.freshFor { return }
        scan()
    }

    func scan(background: Bool = false) {
        // The list mustn't change under a move or Undo; it's scanned after.
        guard !trashing else {
            scanAfterTrash = (scanAfterTrash ?? true) && background
            return
        }
        progress?.cancel()
        temporaryRun?.cancel()
        let p = ScanProgress()
        progress = p
        scannedThisLaunch = true
        scanning = true
        activityRevision &+= 1
        startedAt = .now
        scanFraction = 0
        preview = []
        let home = home
        let level = PerformanceLevel.inEffect()
        let workers = level.workers(background: background)
        let lookUpTools = runningTools
        let projectRules = projectRules
        let steps = LatestOnly<CleanScanStep> { [weak self] step in self?.stepped(step, run: p) }
        scanJob = Task.detached(priority: level.priority(background: background)) { [weak self] in
            let found = await ScanBudget.shared.walk(background: background, progress: p) {
                CleanScanner.list(home: home, progress: p, workers: workers, onStep: { steps.send($0) })
            }
            // Reading every process's arguments is slow; it's done here, not on the main thread.
            let tools = p.isCancelled ? nil : lookUpTools()
            // Nil when the rules can't be read: what was known stays shown,
            // and a move stops on them by itself.
            let kept = p.isCancelled ? nil : (try? ProjectStore.loadRules(base: projectRules))?.keepPaths
            await self?.finished(found, run: p, tools: tools, keptInProjects: kept, background: background)
        }
    }

    func stop() {
        progress?.cancel()
        temporaryRun?.cancel()
    }

    /// The second, slower look, once the scan's own result is on screen. Its
    /// finds join the list unticked; an earlier look's stay until then.
    private func lookInTemporary(background: Bool) {
        temporaryRun?.cancel()
        guard !temporary.isEmpty else { return }
        let run = ScanProgress()
        temporaryRun = run
        lookingInTemporary = true
        let (roots, find) = (temporary, findTemporary)
        // Below the scans someone waits on, and behind them for a slot.
        temporaryJob = Task.detached(priority: .utility) { [weak self] in
            let found = await ScanBudget.shared.walk(background: true, progress: run) { find(roots, run) }
            await self?.foundTemporary(found, run: run)
        }
    }

    private func foundTemporary(_ found: TemporaryListing?, run: ScanProgress) {
        guard run === temporaryRun else { return }
        temporaryRun = nil
        lookingInTemporary = false
        guard !run.isCancelled, let found else { return }
        // The list mustn't change under a move or Undo: the look is made
        // again once that's done.
        guard !trashing else {
            temporaryDeferred = true
            return
        }
        temporaryInUse = found.inUseBytes
        candidates = CleanScanner.ordered(candidates.filter { $0.category != .temporary } + found.candidates)
        let paths = Set(candidates.map(\.path))
        chosen.formIntersection(paths)
        selection.formIntersection(paths)
    }

    private func stepped(_ step: CleanScanStep, run: ScanProgress) {
        guard run === progress, scanning else { return }
        scanFraction = step.fraction
        if candidates.isEmpty { preview = step.found }
    }

    /// A scan asked for while a move or Undo ran, and whether nobody is
    /// waiting on it: one asked for by the user counts over a background one.
    private var scanAfterTrash: Bool?

    private func startScanAfterTrash() {
        guard let background = scanAfterTrash else {
            // No scan waits, which would look itself: a look through the
            // temporary folders that ended under the move is made now.
            if temporaryDeferred, !lookingInTemporary, !scanning {
                temporaryDeferred = false
                lookInTemporary(background: false)
            }
            return
        }
        scanAfterTrash = nil
        scan(background: background)
    }

    /// Only a complete scan replaces the list. The first scan of a launch
    /// chooses the safe items of apps that aren't running.
    private func finished(_ listing: CleanListing?, run: ScanProgress, tools found_tools: Set<String>?, keptInProjects kept: Set<String>?,
                          background: Bool = false) {
        guard run === progress else { return }
        scanning = false
        progress = nil
        scanFraction = nil
        preview = []
        guard !run.isCancelled, let listing else { return }
        if let kept { keptInProjects = CleanKeepList(paths: kept) }
        // What the last look in the temporary folders found stays listed until the next one is in.
        let found = CleanScanner.ordered(listing.candidates + candidates.filter { $0.category == .temporary })
        let firstResult = scannedAt == nil || isStale
        candidates = found
        unreadablePlaces = listing.unreadable
        scannedAt = .now
        isStale = false
        running = runningApps()
        tools = found_tools
        let paths = Set(found.map(\.path))
        if firstResult {
            chosen = Set(found.filter(isDefaultChoice).map(\.path))
        } else {
            chosen.formIntersection(paths)
        }
        selection.formIntersection(paths)
        let home = home
        let base = base
        // In the order the scans finished, so an older one never lands last.
        // What's in the temporary folders isn't saved: it's looked for again each time.
        StoreWrites.submit { CleanStore.save(listing, home: home, base: base) }
        // A scan nobody waits on, as at launch, reads only the home folder:
        // the temporary folders are looked through once the pane is opened.
        if background {
            temporaryDeferred = !temporary.isEmpty
        } else {
            temporaryDeferred = false
            lookInTemporary(background: false)
        }
    }

    func isDefaultChoice(_ c: CleanCandidate) -> Bool {
        c.safety == .safe && !isRunning(c) && !isKept(c.path) && !isJustWritten(c)
    }

    /// Changed within `quietFor` of the scan that found it.
    func isJustWritten(_ c: CleanCandidate) -> Bool {
        (scannedAt ?? .now).timeIntervalSince(c.modified) < quiet
    }

    /// In use by an app or command-line tool running at the last check.
    func isRunning(_ c: CleanCandidate) -> Bool {
        Self.inUse(c, home: home, apps: running, tools: tools)
    }

    func refreshActivity() async {
        guard !trashing else { return }
        let before = Set(candidates.filter(isRunning).map(\.path))
        let current = runningApps()
        if running != current { running = current }
        unchooseNewlyActive(before: before)
        guard !scanning else { return }
        let revision = activityRevision
        let read = runningTools
        let found = await Task.detached(priority: .utility) { read() }.value
        guard !Task.isCancelled, revision == activityRevision, !scanning, !trashing else { return }
        let beforeTools = Set(candidates.filter(isRunning).map(\.path))
        if tools != found { tools = found }
        unchooseNewlyActive(before: beforeTools)
    }

    private func unchooseNewlyActive(before: Set<String>) {
        let active = Set(candidates.filter(isRunning).map(\.path))
        let opening = active.subtracting(before)
        if !opening.isDisjoint(with: chosen) { chosen.subtract(opening) }
    }

    nonisolated static func inUse(_ c: CleanCandidate, home: String, apps: Set<String>, tools: Set<String>?) -> Bool {
        (c.owner.map(apps.contains) ?? false) || CleanRules.inUse(c.path, home: home, running: tools)
    }

    // MARK: Reading

    var totalBytes: Int64 { candidates.reduce(0) { $0 + $1.bytes } }
    var chosenCandidates: [CleanCandidate] { candidates.filter { chosen.contains($0.path) } }
    var chosenBytes: Int64 { chosenCandidates.reduce(0) { $0 + $1.bytes } }

    func bytes(_ category: CleanCategory) -> Int64 {
        candidates.filter { $0.category == category }.reduce(0) { $0 + $1.bytes }
    }

    // MARK: Choosing

    func toggle(_ path: String) {
        if chosen.contains(path) {
            chosen.remove(path)
        } else if !isKept(path) {
            chosen.insert(path)
        }
    }

    func choose(_ paths: some Sequence<String>) { chosen.formUnion(paths.filter { !isKept($0) }) }

    func chooseSafe() { chosen = Set(candidates.filter(isDefaultChoice).map(\.path)) }

    func choose(category: CleanCategory) {
        choose(candidates.filter { $0.category == category }.map(\.path))
    }

    // MARK: Keep list

    /// Reads the keep list again, and saves a change still waiting.
    func reloadKeepList() { keepFile.reload() }

    /// Gives up a change to the keep list that couldn't be saved.
    func discardKeepChange() { guard !trashing else { return }; keepFile.discardChange() }

    /// Never offers these for cleaning again. Not saved means nothing is
    /// moved until it is.
    func keepAlways(_ paths: [String]) {
        changeKeep(keep: paths, stop: [])
        chosen = chosen.filter { !isKept($0) }
    }

    func stopKeeping(_ paths: [String]) {
        changeKeep(keep: [], stop: paths)
    }

    /// Saved onto the list as it is on disk now, so another window's change
    /// isn't lost. A running move reads the file before each item, so the
    /// list only changes between runs.
    private func changeKeep(keep add: [String], stop remove: [String]) {
        guard !trashing else {
            show(Notice(text: String(localized: "Wait for the move to finish before changing the keep list."), canUndo: false))
            return
        }
        keepFile.change(keep: add, stop: remove)
        if let why = keepFile.readError {
            show(Notice(text: String(localized: "The keep list couldn't be read, so the change isn't saved yet: \(why.description)"), canUndo: false))
        } else if let why = keepFile.saveError {
            show(Notice(text: String(localized: "Couldn't save the keep list: \(why.description)"), canUndo: false))
        }
    }

    // MARK: Trash

    var trashBlocker: String? {
        if let why = keepFile.blocker { return why }
        if chosen.isEmpty { return String(localized: "Choose at least one item.") }
        if scanning { return String(localized: "Wait for the scan to finish.") }
        if trashing { return String(localized: "Moving to the Trash…") }
        return nil
    }

    /// Moves the chosen items to the Trash off the main thread. The keep
    /// list is read again from disk first and every item is checked against
    /// the rules again; a list that can't be read stops the whole run. Caches
    /// of apps running at that moment are left alone.
    func trashChosen() {
        guard !trashing, !scanning, !chosen.isEmpty else { return }
        trashing = true
        activityRevision &+= 1
        let savedKeep = keepFile
        let projectRules = projectRules
        let lookUpTools = runningTools
        let all = chosenCandidates
        let (home, temporary, programsAtWork) = (home, temporary, programsAtWork)
        let keepURL = keepURL
        let backend = trash
        let jobs = jobs
        Task {
            let job = await jobs.begin(.moveToTrash)
            defer { jobs.end(job) }
            let (reloaded, projects) = await Task.detached(priority: .userInitiated) {
                var reloaded = savedKeep
                reloaded.reload()
                let projects = try? ProjectStore.loadRules(base: projectRules)
                return (reloaded, projects)
            }.value
            keepFile = reloaded
            if let why = reloaded.blocker {
                trashing = false
                show(Notice(text: String(localized: "Nothing was moved: \(why.prefix(1).lowercased() + why.dropFirst())"), canUndo: false))
                startScanAfterTrash()
                return
            }
            guard let projects else {
                trashing = false
                show(Notice(text: String(localized: "Nothing was moved: your project rules couldn't be read."), canUndo: false))
                startScanAfterTrash()
                return
            }
            keptInProjects = CleanKeepList(paths: projects.keepPaths)
            let fresh = CleanKeepList(paths: reloaded.list.paths.union(keptInProjects.paths))
            var plan: [(CleanCandidate, [String])] = []
            var moved: [TrashRecord] = []
            var failed: [(path: String, reason: String)] = []
            var sizes: [String: Int64] = [:]
            for c in all {
                // An app or tool may start at any point in the run, so each
                // item is checked against what's running right before it goes.
                let apps = runningApps()
                running = apps
                let step = await Task.detached(priority: .userInitiated) { () -> (paths: [String], outcome: TrashOutcome, sizes: [String: Int64], tools: Set<String>?) in
                    let tools = lookUpTools()
                    let none = TrashOutcome(moved: [], failed: [])
                    guard !Self.inUse(c, home: home, apps: apps, tools: tools) else { return ([], none, [:], tools) }
                    let paths = CleanScanner.trashPaths(for: c, keep: fresh)
                    guard !paths.isEmpty else { return ([], none, [:], tools) }
                    // Each path goes only while the item still meets the rules
                    // and the keep list as it is now protects none of it.
                    let gate = TrashGate(
                        still: { _ in
                            CleanScanner.isStillCandidate(c.path, home: home, temporary: temporary,
                                                          inUse: c.category == .temporary ? programsAtWork() : nil)
                        },
                        protections: {
                            let kept = try UserProtections.kept(keepList: keepURL, projectBase: projectRules)
                            return { kept.protects($0) }
                        })
                    let outcome = job.moveToTrash(paths, through: gate, backend: backend)
                    // What really went: the item at its measured size when it
                    // went itself, anything else measured where it landed,
                    // a file by its blocks and a folder by its tree.
                    var sizes: [String: Int64] = [:]
                    for r in outcome.moved {
                        sizes[r.original.path] = r.original.path == c.path
                            ? c.bytes : StorageScanner.sizeOnDisk(r.trashed.path, workers: 1) ?? 0
                    }
                    return (paths, outcome, sizes, tools)
                }.value
                tools = step.tools
                guard !step.paths.isEmpty else { continue }
                plan.append((c, step.paths))
                moved += step.outcome.moved
                failed += step.outcome.failed
                sizes.merge(step.sizes) { a, _ in a }
            }
            applyTrash(TrashOutcome(moved: moved, failed: failed), plan: plan, picked: all, sizes: sizes)
        }
    }

    private func applyTrash(_ outcome: TrashOutcome, plan: [(CleanCandidate, [String])], picked: [CleanCandidate], sizes: [String: Int64]) {
        trashing = false
        defer { startScanAfterTrash() }
        let moved = Set(outcome.moved.map(\.original.path))
        // Gone whole: every path planned for it moved, and it didn't keep anything back.
        let gone = plan.filter { c, paths in
            paths.allSatisfy(moved.contains) && (!c.contentsOnly || !isKept(c.path))
        }.map(\.0)
        let partly = plan.filter { _, paths in paths.contains(where: moved.contains) }.map(\.0.path)
        let goneSet = Set(gone.map(\.path))
        candidates.removeAll { goneSet.contains($0.path) }
        if partly.count > gone.count { isStale = true }
        chosen.subtract(picked.map(\.path))
        let freed = sizes.values.reduce(0, +)
        let record = CleanupRecord(source: CleanupSource.deepClean.rawValue, items: outcome.moved.count, bytes: freed, failed: outcome.failed.count)
        CleanupLog.submit(record, to: logURL)
        if !outcome.moved.isEmpty {
            shelf.add(Run(id: record.id, records: outcome.moved, candidates: gone, sizes: sizes))
        }
        let skipped = picked.count - plan.count
        var text = outcome.moved.isEmpty && !outcome.failed.isEmpty
            ? nothingMoved(outcome.failed) : String(localized: "Moved \(fmt(freed)) to the Trash")
        if !outcome.moved.isEmpty && !outcome.failed.isEmpty { text += String(localized: " · \(outcome.failed.count) couldn't be moved") }
        if skipped > 0 { text += String(localized: " · \(skipped) left alone") }
        show(Notice(text: text, canUndo: !outcome.moved.isEmpty))
    }

    /// The running Undo, so a caller can wait for it.
    private(set) var undoJob: Task<Void, Never>?

    /// Puts a move back, off the main thread: the one of history record
    /// `id`, or the latest.
    func undoTrash(run id: UUID? = nil) {
        guard !trashing else { return }
        target = id ?? shelf.latest?.id
        guard target.flatMap(shelf.run) != nil, !undoRecords.isEmpty else {
            target = nil
            return
        }
        let records = undoRecords
        trashing = true
        activityRevision &+= 1
        let jobs = jobs
        undoJob = Task {
            let failed = await jobs.perform(.putBack) { $0.putBack(records) }
            trashing = false
            applyUndo(failed)
            target = nil
            startScanAfterTrash()
        }
    }

    private func applyUndo(_ failed: [TrashRecord]) {
        let failedPaths = Set(failed.map(\.original.path))
        let back = Set(undoRecords.map(\.original.path)).subtracting(failedPaths)
        // Only what really came back returns to the list.
        let returned = undoCandidates.filter { c in back.contains { $0 == c.path || $0.hasPrefix(c.path + "/") } }
        candidates = (candidates + returned).sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path }
        let restored = undoRecords.count - failed.count
        if let id = undoLogID {
            CleanupLog.submitRestore(id, restored: restored, bytes: back.reduce(0) { $0 + (undoSizes[$1] ?? 0) }, failed: failed.count, in: logURL)
        }
        for p in back { undoSizes[p] = nil }
        // Emptied folders were never removed from the list; their sizes are
        // right again only once measured.
        isStale = true
        undoRecords = failed
        undoCandidates = undoCandidates.filter { c in failedPaths.contains { $0 == c.path || $0.hasPrefix(c.path + "/") } }
        if failed.isEmpty, let id = undone?.id { shelf.remove(id) }
        show(Notice(
            text: failed.isEmpty ? String(localized: "Restored \(restored) items") : String(localized: "Restored \(restored); \(failed.count) couldn't be put back. Undo tries those again."),
            canUndo: !failed.isEmpty))
    }

    /// The last move's notice with its Undo, shown again after a passing
    /// notice while there's still something to put back.
    private var undoNotice: Notice?

    /// A notice with Undo stays until it's used, closed or replaced; any
    /// other passes after a few seconds.
    private func show(_ n: Notice) {
        withAnimation(Motion.snappy) { notice = n }
        if n.canUndo {
            undoNotice = n
            return
        }
        Task {
            try? await Task.sleep(for: .seconds(4))
            guard notice == n else { return }
            withAnimation(Motion.snappy) { notice = undoRecords.isEmpty ? nil : undoNotice }
        }
    }

    func dismissNotice() { withAnimation(Motion.snappy) { notice = nil } }
}

private func fmt(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
