import Foundation

// MyMole's performance settings share one six-step scale: Gentle, Light,
// Balanced, Fast, Maximum and Hyperspeed. Balanced, step 3, holds the
// limits MyMole had before the scale. Maximum, the default, goes well past
// them; Hyperspeed has no limits and can use a lot of memory and disk. A
// lower step is for a Mac where the app feels slow.

/// How hard MyMole's scans may work, chosen in Settings. Lower levels walk
/// with fewer threads at a lower priority, which on Apple silicon keeps them
/// on the efficiency cores, run the cleanup scans one at a time and let fewer
/// disk walks run at once; scans take longer and the Mac stays quiet. From
/// Balanced up a scan you wait on has every core, and the levels differ in
/// what scans started ahead get and in how many walks run at once. Each
/// scan reads the level as it starts, so a change applies from the next scan.
/// In Low Power Mode, or while the Mac runs hot, a scan starts at Balanced at
/// most whatever is chosen (`inEffect`).
public enum PerformanceLevel: Int, CaseIterable, Sendable, Comparable {
    case gentle = 1
    case light
    case balanced
    case fast
    case full
    case hyperspeed

    public static let defaultsKey = "performance.level"
    /// Scans start at Maximum; a lower level is for a Mac where they get in the way.
    public static let standard = PerformanceLevel.full

    /// The level saved in Settings, or the standard one.
    public static func current(in defaults: UserDefaults = .standard) -> PerformanceLevel {
        PerformanceLevel(saved: defaults.integer(forKey: defaultsKey))
    }

    /// The level a scan starting now runs at: the chosen one, or Balanced at
    /// most while the Mac is in Low Power Mode or reports that it's running
    /// hot. Settings keeps showing the level that was chosen.
    public static func inEffect(
        in defaults: UserDefaults = .standard, lowPower: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled,
        thermal: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    ) -> PerformanceLevel {
        current(in: defaults).held(lowPower: lowPower, thermal: thermal)
    }

    /// Whether the Mac asks for less right now: Low Power Mode, or a
    /// thermal state macOS calls serious or critical.
    public static func isStrained(
        lowPower: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled,
        thermal: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    ) -> Bool {
        lowPower || thermal == .serious || thermal == .critical
    }

    public func held(lowPower: Bool, thermal: ProcessInfo.ThermalState) -> PerformanceLevel {
        Self.isStrained(lowPower: lowPower, thermal: thermal) ? min(self, .balanced) : self
    }

    /// A saved value; anything unknown, or nothing saved (0), is the standard level.
    public init(saved: Int) {
        self = PerformanceLevel(rawValue: saved) ?? Self.standard
    }

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public var title: String { StepName.title(rawValue) }

    public var detail: String {
        switch self {
        case .gentle: String(localized: "Quietest. Two threads at the lowest priority, one scan at a time; scans take longest.")
        case .light: String(localized: "Few threads at low priority, one scan at a time.")
        case .balanced: String(localized: "Uses the cores without crowding the apps you work in.")
        case .fast: String(localized: "Every core for scans you wait on, and half of them for scans started ahead.")
        case .full: String(localized: "Everything the Mac has for scans you wait on, and many disk walks at a time.")
        case .hyperspeed: String(localized: "No limits: every thread and as many disk walks at once as there are scans. Can use a lot of memory and disk.")
        }
    }

    /// Directory walkers for one scan: never more than the cores. The
    /// walkers run on the system's shared threads, which carry no more than
    /// that at once, so a higher number would only be a number.
    public func workers(background: Bool, cores: Int = ProcessInfo.processInfo.activeProcessorCount) -> Int {
        let c = max(cores, 1)
        let wanted: Int
        switch (self, background) {
        case (.gentle, false): wanted = 2
        case (.gentle, true): wanted = 1
        case (.light, false): wanted = max(c / 2, 2)
        case (.light, true): wanted = 2
        case (.balanced, false): wanted = c
        case (.balanced, true): wanted = max(c / 4, 2)
        case (.fast, false): wanted = c
        case (.fast, true): wanted = max(c / 2, 2)
        // A scan started ahead of time walks as hard as one you wait on.
        case (.full, _), (.hyperspeed, _): wanted = c
        }
        return min(wanted, c)
    }

    /// Threads for reading app bundles, which are many small folders.
    public func appWorkers(background: Bool) -> Int {
        self == .hyperspeed ? workers(background: background) : min(workers(background: background), background ? 4 : 8)
    }

    public func priority(background: Bool) -> TaskPriority {
        switch self {
        case .gentle, .light: background ? .background : .utility
        case .balanced, .fast: background ? .utility : .userInitiated
        case .full, .hyperspeed: .userInitiated
        }
    }

    /// Whether the cleanup scans may run side by side.
    public var runsScansTogether: Bool { self >= .balanced }

    /// Disk walks `ScanBudget.shared` lets run at once, whichever pane
    /// started them: 1, 2, 3 (the limit before the scale), 4, then 6 or half
    /// the cores, and no limit at Hyperspeed.
    public func scanSlots(cores: Int = ProcessInfo.processInfo.activeProcessorCount) -> Int {
        switch self {
        case .gentle: 1
        case .light: 2
        case .balanced: 3
        case .fast: 4
        case .full: max(6, cores / 2)
        case .hyperspeed: .max
        }
    }
}

/// How MyMole keeps big results, chosen in Settings: how much memory a
/// large list may take before it's kept on disk instead (`SpillTable`), and
/// the saved scans and history points behind Changes and growth. Results
/// are always complete: every large file, search match, process and folder
/// item is listed at every size, from memory or from disk. A change applies
/// from the next scan.
public enum ResultSize: Int, CaseIterable, Sendable, Comparable {
    case gentle = 1
    case light
    case balanced
    case fast
    case maximum
    case hyperspeed

    public static let defaultsKey = "performance.results"
    /// Maximum until someone chooses otherwise.
    public static let byDefault = ResultSize.maximum
    /// The size that keeps what MyMole kept before the setting existed.
    public static let base = ResultSize.balanced

    public static func current(in defaults: UserDefaults = .standard) -> ResultSize {
        ResultSize(saved: defaults.integer(forKey: defaultsKey))
    }

    /// A saved value; anything unknown, or nothing saved (0), is the default size.
    public init(saved: Int) {
        self = ResultSize(rawValue: saved) ?? Self.byDefault
    }

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public var title: String { StepName.title(rawValue) }

    public var detail: String {
        switch self {
        case .gentle: String(localized: "Keeps the least in memory and on disk: big lists move to disk soonest.")
        case .light: String(localized: "Keeps little in memory; big lists move to disk early.")
        case .balanced: String(localized: "Keeps saved scans and history as MyMole did before this setting.")
        case .fast: String(localized: "Keeps more in memory, more saved scans and a history point every few hours.")
        case .maximum: String(localized: "Keeps big lists in memory up to a quarter of this Mac's memory, many saved scans and a history point every hour.")
        case .hyperspeed: String(localized: "No limits: keeps every list in memory, every saved scan and a history point for every scan. Can use a lot of memory and disk.")
        }
    }

    /// All saved disk map scans together: 50 MB, 100 MB, 200 MB (the limit
    /// before the scale), 500 MB, 1 GB; nil keeps every one.
    public var savedScanLimit: Int64? {
        let megabyte: Int64 = 1 << 20
        switch self {
        case .gentle: return 50 * megabyte
        case .light: return 100 * megabyte
        case .balanced: return SnapshotStore.totalLimit
        case .fast: return 500 * megabyte
        case .maximum: return 1_024 * megabyte
        case .hyperspeed: return nil
        }
    }

    /// How often a scan nobody asked for may add a point to a history: every
    /// 24, 12, 6 (as before the scale), 3 or 1 hours; at Hyperspeed every
    /// complete scan does. Growth always compares against a point at least
    /// a day old.
    public var historyInterval: TimeInterval {
        let hour: TimeInterval = 3_600
        switch self {
        case .gentle: return 24 * hour
        case .light: return 12 * hour
        case .balanced: return SnapshotStore.unattendedInterval
        case .fast: return 3 * hour
        case .maximum: return hour
        case .hyperspeed: return 0
        }
    }

    /// What a large result may take in memory before it's kept on disk
    /// instead (`SpillTable`): 64 MB, 128 MB, 256 MB, 512 MB, then a quarter
    /// of this Mac's memory and at least 2 GB, the share Inkline gives open
    /// documents; nil at Hyperspeed, which keeps everything in memory.
    public func memoryBudget(physical: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int64? {
        let megabyte: Int64 = 1 << 20
        switch self {
        case .gentle: return 64 * megabyte
        case .light: return 128 * megabyte
        case .balanced: return 256 * megabyte
        case .fast: return 512 * megabyte
        case .maximum: return max(2_048 * megabyte, Int64(clamping: physical / 4))
        case .hyperspeed: return nil
        }
    }

    /// Roughly what a listed file costs in memory: the row and its path,
    /// name and folder as text.
    public static func memoryCost(pathBytes: Int, rows: Int) -> Int64 {
        Int64(pathBytes) * 2 + Int64(rows) * 160
    }

    /// Points kept of a project's growth history. Hourly points still reach
    /// a day back within them.
    public var projectSamplesKept: Int { self == .hyperspeed ? .max : ProjectStore.keep }
}

/// The six steps the speed, size and responsiveness controls share, named
/// in one place: step 1 is Gentle, step 6 Hyperspeed.
public enum StepName {
    public static func title(_ step: Int) -> String {
        switch step {
        case 1: String(localized: "Gentle")
        case 2: String(localized: "level.light", defaultValue: "Light", comment: "A speed or size level, between Gentle and Balanced; not the light appearance")
        case 3: String(localized: "Balanced")
        case 4: String(localized: "Fast")
        case 5: String(localized: "Maximum")
        default: String(localized: "Hyperspeed")
        }
    }
}
