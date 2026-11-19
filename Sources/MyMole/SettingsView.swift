import AppKit
import ServiceManagement
import StorageKit
import SwiftUI
import SystemKit

/// Settings stays in the main window, using the shared page width and section cards.
struct SettingsView: View {
    @Bindable var app: AppModel
    @AppStorage(PerformanceLevel.defaultsKey) private var performance = PerformanceLevel.standard.rawValue
    @AppStorage(ResultSize.defaultsKey) private var results = ResultSize.byDefault.rawValue
    @AppStorage(Responsiveness.defaultsKey) private var responsiveness = Responsiveness.byDefault.rawValue
    @AppStorage(MemoryRelief.defaultsKey) private var memoryRelief: Bool?
    @AppStorage(Density.key) private var density = Density.standard.rawValue
    @AppStorage(AppearanceMode.key) private var mode = AppearanceMode.system.rawValue
    @AppStorage(ThemeFamily.key) private var theme = ThemeFamily.standard.rawValue
    @AppStorage(TableLines.key) private var lines = TableLines.standard.rawValue
    @AppStorage(MenuBarSettings.showKey) private var menuBar = MenuBarSettings.showStandard
    @AppStorage(MenuBarSettings.freeKey) private var menuBarFree = false
    @AppStorage(WatchSettings.scanKey) private var backgroundScan = WatchSettings.Cadence.standard.rawValue
    @AppStorage(WatchSettings.diskKey) private var notifyDisk = false
    @AppStorage(WatchSettings.findsKey) private var notifyFinds = false
    @AppStorage(WatchSettings.trashedAppsKey) private var notifyTrashedApps = false
    @AppStorage(WatchSettings.busyKey) private var notifyBusy = false
    @State private var notificationsRefused = false
    @State private var loginItem = LoginItem.state
    @State private var loginItemProblem: String?
    @AppStorage(LoadingSettings.prefetchKey) private var prefetch = true
    @AppStorage(LoadingSettings.historyKey) private var history = LoadingSettings.historyStandard
    @State private var savedBytes: Int64?
    @State private var savedScanBytes: Int64?
    @State private var spilledBytes: Int64?
    @State private var confirmingClear = false
    @State private var showingSelfRemoval = false
    @State private var language = LanguageSetting.chosen()


    private var diskAccessText: String {
        if !app.access.has(.home) {
            return String(localized: "Choose your home folder in Folder Access before MyMole can check Full Disk Access.")
        }
        if !app.diskAccess.hasResult { return String(localized: "Checking Full Disk Access…") }
        return switch app.diskAccessState {
        case .granted: String(localized: "MyMole has Full Disk Access.")
        case .denied: String(localized: "MyMole doesn't have Full Disk Access, so the folders macOS protects stay closed to it.")
        case .unknown: String(localized: "MyMole couldn't tell whether it has Full Disk Access: none of the folders it checks are on this Mac. It goes on as if it has; a folder it can't read is said where it shows up.")
        }
    }

    private var matches: [SettingsSection] {
        SettingsSection.matching(app.settingsQuery, sandboxed: Edition.current.isSandboxed, systemTasks: Edition.current.hasSystemTasks)
    }

    var body: some View {
        VStack(spacing: 0) {
            DSPaneHeader {
                DSControlField("Search settings") {
                    DSFilterField(String(localized: "Search by name or purpose"), text: $app.settingsQuery)
                        .accessibilityIdentifier("settings.search")
                }
                .frame(maxWidth: DS.Size.formMaxWidth, alignment: .leading)
            } actions: {
                EmptyView()
            } strip: {
                if app.settingsQuery.isEmpty {
                    DSStatusFact("Changes apply as you make them", symbol: "checkmark")
                } else {
                    if matches.count == 1 {
                        DSCountCapsule(1, "matching section")
                    } else {
                        DSCountCapsule(matches.count, "matching sections")
                    }
                    DSStripButton("Show All", symbol: "xmark") { app.settingsQuery = "" }
                }
            }
            Divider()
            if matches.isEmpty {
                ContentUnavailableView.search(text: app.settingsQuery)
            } else {
                DSPage {
                    // One column of forms, as System Settings has: labels and
                    // controls line up from section to section.
                    LazyVStack(alignment: .leading, spacing: DS.Space.section) {
                        ForEach(matches) { section in
                            settingsSection(section)
                                .accessibilityIdentifier("settings.section." + section.rawValue)
                        }
                    }
                    .frame(maxWidth: DS.Size.formMaxWidth, alignment: .leading)
                }
            }
        }
        .paneToolbar("Settings", subtitle: "Appearance, behavior and safety")
        .sheet(isPresented: $showingSelfRemoval, onDismiss: { loginItem = LoginItem.state }) {
            SelfRemovalSheet(model: app.selfRemoval)
        }
    }

    @ViewBuilder private func settingsSection(_ section: SettingsSection) -> some View {
        switch section {
        case .appearance: appearance
        case .menuBar: menuBarSection
        case .background: backgroundSection
        case .performance: performanceSection
        case .loading: loadingSection
        case .diskMap: DiskMapSkipsSection()
        case .confirmations: ConfirmationsSection(projectRules: app.projects.ruleConfirmations)
        case .diskAccess: diskAccessSection
        case .appManagement: appManagementSection
        case .timings: TimingsSection()
        case .folderAccess: folderAccessSection
        case .systemTasks: systemTasksSection
        case .keep: keepSection
        case .systemKeep: systemKeepSection
        case .privacy: PrivacySection()
        case .about: aboutSection
        case .uninstall: selfUninstallSection
        }
    }

    private var selfUninstallSection: some View {
        DSSection("Uninstall MyMole", footer: "Review its caches and settings, turn off Open at Login and move the app to the Trash. Nothing is deleted permanently.", rows: false) {
            DSFormGrid {
                DSFormRow("This copy", help: app.selfRemoval.available
                          ? String(localized: "MyMole can uninstall itself, including the data you choose.")
                          : String(localized: "Self-uninstall is available when running the installed MyMole app.")) {
                    Button("Uninstall MyMole…", role: .destructive) { showingSelfRemoval = true }
                        .fixedSize()
                        .disabled(!app.selfRemoval.available)
                }
            }
        }
    }

    private var appearance: some View {
        DSSection("Appearance", rows: false) {
            DSFormGrid {
                DSFormRow("Language", help: "MyMole shows its windows and dialogs in this language. macOS picks the language when MyMole starts, so a change applies the next time it opens.") {
                    Picker("Language", selection: Binding(get: { language }, set: { code in
                        language = code
                        LanguageSetting.choose(code)
                    })) {
                        Text("Same as the Mac").tag(String?.none)
                        Divider()
                        ForEach(LanguageSetting.available, id: \.self) { Text(verbatim: LanguageSetting.name(of: $0)).tag(String?.some($0)) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                DSFormRow("Appearance") {
                    Picker("Appearance", selection: $mode) {
                        ForEach(AppearanceMode.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                DSFormRow("Theme", help: "Changes the surfaces and the accent. Text and warning colours stay the system's.") {
                    Picker("Theme", selection: $theme) {
                        ForEach(ThemeFamily.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                DSFormRow("Layout", help: "Spacious gives margins, rows and the gaps between columns more room. Compact fits the most on screen.") {
                    Picker("Layout", selection: Binding(
                        get: { Density(rawValue: density) ?? .standard },
                        set: { d in
                            // Update observed metrics without recreating open panes.
                            Density.current = d
                            density = d.rawValue
                        })
                    ) {
                        ForEach(Density.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                DSFormRow("Table lines", help: "Lines between the rows of every list, or its rows and columns. Without them, file lists are striped.") {
                    Picker("Table lines", selection: $lines) {
                        ForEach(TableLines.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                DSFormRow("Preview", help: "How lists, selection and status look with these choices.") {
                    ThemePreview()
                }
            }
        }
    }

    private var menuBarSection: some View {
        DSSection("Menu Bar", rows: false) {
            DSFormGrid {
                DSFormRow("Menu bar", checkbox: true, help: "The disk, memory and what the scans found at a glance. MyMole keeps running there when its window is closed; Quit ends it.") {
                    Toggle("Show MyMole in the menu bar", isOn: $menuBar)
                }
                DSFormRow(nil) {
                    Toggle("Show free space beside the icon", isOn: $menuBarFree)
                        .disabled(!menuBar)
                }
                DSFormRow("Login", checkbox: true, help: menuBar
                          ? "It starts in the menu bar, without a window, and scans when the Mac has time to spare."
                          : "Its window opens at login. With the menu bar item on, it starts there instead.") {
                    Toggle("Open MyMole at login", isOn: Binding(
                        get: { loginItem == .on },
                        set: { on in
                            loginItemProblem = LoginItem.set(on)
                            loginItem = LoginItem.state
                        }))
                        .disabled(loginItem == .unavailable)
                }
                if loginItem == .needsApproval {
                    DSFormRow(nil, help: "macOS is waiting for you to allow MyMole in System Settings → General → Login Items.") {
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let loginItemProblem {
                    DSFormRow(nil) { Text(loginItemProblem).foregroundStyle(.red) }
                }
            }
        }
        .liveRefresh(every: .seconds(5), events: []) {
            let current = LoginItem.state
            if loginItem != current { loginItem = current }
        }
    }

    private var backgroundSection: some View {
        DSSection("In the Background", rows: false) {
            DSFormGrid {
                DSFormRow("Background scan", help: "While MyMole runs, also in the menu bar, when the Mac has time to spare. Scans only read; nothing is removed until you choose it.") {
                    Picker("Scan in the background", selection: $backgroundScan) {
                        ForEach(WatchSettings.Cadence.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: backgroundScan) { app.watch.schedule { await app.backgroundScan() } }
                }
                DSFormRow("Notify me") {
                    Toggle("When the disk is nearly full", isOn: notifying($notifyDisk))
                }
                DSFormRow(nil, checkbox: true, help: "At least \(ByteSize.format(Alerts.findsMinimum)) in one pane, at most once a week.") {
                    Toggle("When a scan finds a lot to clean", isOn: notifying($notifyFinds))
                }
                DSFormRow(nil, checkbox: true, help: "An app dragged to the Trash leaves its settings, caches and data in your Library. Nothing is removed until you choose it.") {
                    Toggle("When an app in the Trash left things behind", isOn: notifying($notifyTrashedApps))
                }
                // The App Sandbox keeps other apps' processes from MyMole.
                if !Edition.current.isSandboxed {
                    DSFormRow(nil, checkbox: true, help: "A whole core for \(Int(BusyProcesses.lasting / 60)) minutes, at most once a day for each app.") {
                        Toggle("When an app keeps the processor busy", isOn: notifying($notifyBusy))
                    }
                }
                if notificationsRefused {
                    DSFormRow(nil) {
                        Text("Notifications are turned off for MyMole in System Settings → Notifications.")
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .liveRefresh(every: .seconds(5), events: []) {
            let denied = await Notifier.notificationsDenied()
            guard !Task.isCancelled else { return }
            if denied != notificationsRefused { notificationsRefused = denied }
        }
    }

    private var performanceSection: some View {
        DSSection("Performance", footer: "Each control has six steps, from Gentle to Hyperspeed, and starts at Maximum. Hyperspeed removes every limit and can use a lot of memory and disk. Results are complete at every step. If MyMole makes this Mac sluggish, lower a control. Scans can always be stopped, and a change applies from the next scan.", rows: false) {
            DSFormGrid {
                ScanSpeedControl(performance: $performance)
                DSFormRow("Large results") {
                    Picker("Large results", selection: Binding(
                        get: { ResultSize(saved: results) },
                        set: { results = $0.rawValue })
                    ) {
                        ForEach(ResultSize.allCases, id: \.self) { Text(stepTitle($0.title, hyperspeed: $0 == .hyperspeed)).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("settings.result-size")
                } help: {
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text(ResultSize(saved: results).detail)
                        Text(PerformanceSummary.results(ResultSize(saved: results)))
                        Text("Saved disk map scans take \(savedScanBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…") on disk; large lists kept on disk now take \(spilledBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…").")
                    }
                }
                DSFormRow("Responsiveness") {
                    Picker("Responsiveness", selection: Binding(
                        get: { Responsiveness(rawValue: responsiveness) ?? Responsiveness.byDefault },
                        set: { level in
                            responsiveness = level.rawValue
                            Responsiveness.apply()
                        })
                    ) {
                        ForEach(Responsiveness.allCases) { Text(stepTitle($0.title, hyperspeed: $0 == .hyperspeed)).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("settings.responsiveness")
                } help: {
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text(responsivenessDetail)
                        Text(PerformanceSummary.responsiveness(Responsiveness(rawValue: responsiveness) ?? Responsiveness.byDefault))
                    }
                }
                DSFormRow("Memory", checkbox: true, help: "When macOS warns that memory is short, scans started ahead of time stop and icon and chart caches empty; when it's critical, a disk map that isn't on screen goes too. Nothing you're looking at, have chosen or can undo is touched. Until you choose, it follows Large results: on up to Fast, off at Maximum and Hyperspeed.") {
                    Toggle("Free memory when macOS runs low", isOn: Binding(
                        get: { memoryRelief ?? MemoryRelief.byDefault(ResultSize(saved: results)) },
                        set: { memoryRelief = MemoryRelief.saved($0, for: ResultSize(saved: results)) }))
                        .accessibilityIdentifier("settings.memory-relief")
                }
            }
        }
        .task(id: results) {
            savedScanBytes = await Task.detached(priority: .utility) { SavedResults.bytes(files: []) }.value
            spilledBytes = await Task.detached(priority: .utility) { SpillTable.bytes() }.value
        }
    }

    /// Hyperspeed is marked in every list it's chosen from.
    private func stepTitle(_ title: String, hyperspeed: Bool) -> String {
        hyperspeed ? String(localized: "\(title) (no limits)") : title
    }

    private var responsivenessDetail: String {
        let saved = Responsiveness(rawValue: responsiveness) ?? Responsiveness.byDefault
        guard saved == .automatic else { return saved.detail }
        return String(localized: "\(saved.detail) Now: \(saved.resolved().title).")
    }

    private var loadingSection: some View {
        DSSection("Loading and Memory", footer: "Disk Map's saved scans stay within what Large results allows, \(ResultSize(saved: results).savedScanLimit.map(ByteSize.format) ?? String(localized: "every one at Hyperspeed")); the oldest go first, and the newest of each folder always stays.", rows: false) {
            DSFormGrid {
                DSFormRow("At launch", checkbox: true, help: "Scans run one after another in the background, at a lower priority, so each pane opens with a fresh result. Off: a pane scans when you open it.") {
                    Toggle("Get every pane ready", isOn: $prefetch)
                }
                DSFormRow("Disk map history", help: "What Changes compares against. Fewer keep less on disk; older scans go as new ones are saved.") {
                    Stepper(value: Binding(
                        get: { LoadingSettings.history() },
                        set: { history = min(max($0, LoadingSettings.historyRange.lowerBound), LoadingSettings.historyRange.upperBound) }),
                        in: LoadingSettings.historyRange, step: 5
                    ) {
                        Text("\(LoadingSettings.history()) scans per folder").monospacedDigit()
                    }
                    .fixedSize()
                }
                DSFormRow("Saved results", help: "Each pane's last scan and the disk map's history, shown at once after a launch: \(savedBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…").") {
                    Button("Clear…") { confirmingClear = true }
                        .disabled(savedBytes == 0)
                        .actionConfirmation(String(localized: "Clear the saved results?"), isPresented: $confirmingClear,
                                            action: .savedResults, button: String(localized: "Clear Saved Results"),
                                            message: String(localized: "What's on screen stays until you quit. After the next launch each pane scans afresh. Keep lists, project rules and History aren't touched.")) {
                            Task {
                                await Task.detached(priority: .userInitiated) { SavedResults.clear() }.value
                                await measureSaved()
                            }
                        }
                }
                DSFormRow(nil) {
                    SavedResultsList(changed: { await measureSaved() })
                }
            }
        }
        .task { await measureSaved() }
    }

    private var diskAccessSection: some View {
        DSSection("Full Disk Access", rows: false) {
            DSFormGrid {
                DSFormRow("Status") {
                    Text(diskAccessText).fixedSize(horizontal: false, vertical: true)
                }
                DSFormRow(nil) {
                    Button("Open Privacy Settings") { FullDiskAccess.openSettings() }
                }
            }
        }
    }

    private var appManagementSection: some View {
        DSSection("App Management", rows: false) {
            DSFormGrid {
                DSFormRow("Permission", help: "macOS can require App Management permission to remove other apps; Full Disk Access is a separate permission. Allow the copy of MyMole you're using in Privacy & Security → App Management. File permissions or administrator approval can also affect a move.") {
                    AppManagementButton()
                }
            }
        }
    }

    private var folderAccessSection: some View {
        DSSection("Folder Access", footer: "The App Store edition works only in the folders you choose here. Full Disk Access in System Settings also lets it into the folders macOS protects inside them.", rows: false) {
            DSFormGrid {
                ForEach(FolderAccess.Place.allCases) { place in
                    DSFormRow(label: Phrase(verbatim: place.title)) {
                        if app.access.has(place) {
                            Button("Take Back") { Task { await app.takeBack(place) } }
                                .disabled(app.takeBackBlocker != nil)
                                .help(app.takeBackBlocker ?? String(localized: "Stops running scans, then closes the folder to MyMole."))
                        } else {
                            Button("Give Access…") {
                                app.access.request(place)
                                app.recheckDiskAccess()
                            }
                        }
                    } help: {
                        Text(place.why)
                    }
                }
                if let problem = app.access.lastProblem {
                    DSFormRow(nil) { Text(problem).foregroundStyle(.red) }
                }
            }
        }
    }

    private var systemTasksSection: some View {
        DSSection("System Tasks", rows: false) {
            DSFormGrid {
                DSFormRow("Helper", help: "System Clean, Optimize's administrator tasks and protected app moves need administrator rights. The optional helper lets macOS approve this once. Without it, macOS asks when each task runs.") {
                    #if !APPSTORE
                    if let helper = app.privileged.helper {
                        HelperSettingsView(helper: helper)
                            .disabled(app.privileged.busy || app.privileged.outcomeUnknown)
                    } else {
                        Text("The helper isn't available in this copy of MyMole.").foregroundStyle(.secondary)
                    }
                    #endif
                }
            }
        }
    }

    private var keepSection: some View {
        DSSection("Deep Clean Keep List", footer: "Kept items, and anything inside them, are never offered or moved.") {
            keepProblem(
                read: app.deepClean.keepError, save: app.deepClean.keepSaveError,
                retry: app.deepClean.reloadKeepList, discard: app.deepClean.discardKeepChange)
            if app.deepClean.keep.paths.isEmpty {
                Text("Nothing kept yet. Right-click an item in Deep Clean and choose Always Keep.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(app.deepClean.keep.paths.sorted(), id: \.self) { path in
                    keptRow(path) { app.deepClean.stopKeeping([path]) }
                }
            }
        }
    }

    private var systemKeepSection: some View {
        DSSection("System Clean Keep List", footer: "Kept system items, and anything inside them, are never chosen or removed.") {
            keepProblem(
                read: app.systemClean.keepError, save: app.systemClean.keepSaveError,
                retry: app.systemClean.reloadKeepList, discard: app.systemClean.discardKeepChange)
            if app.systemClean.keep.paths.isEmpty {
                Text("Nothing kept yet. Right-click an item in System Clean and choose Always Keep.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(app.systemClean.keep.paths.sorted(), id: \.self) { path in
                    keptRow(path) { app.systemClean.stopKeeping([path]) }
                }
            }
        }
    }

    /// A kept path, whole and wrapping at its slashes, with the one way to undo it.
    private func keptRow(_ path: String, stop: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.md) {
            DSPath(path, .mono)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Stop Keeping", action: stop)
                .fixedSize()
                .help("Remove this protection. No files are moved.")
        }
    }

    private var aboutSection: some View {
        DSSection("About", footer: "MyMole is a native Mac cleaner. Everything it removes is chosen by you; your own files go to the Trash, with Undo. In the direct edition, system tasks use administrator approval or the optional approved helper.", rows: false) {
            DSFormGrid {
                DSFormRow("Website") {
                    Link(destination: Links.website) { Text(verbatim: "mymole.viktornyberg.com") }
                }
                DSFormRow("Help") {
                    Link("Support", destination: Links.support)
                }
                DSFormRow("License", help: "MyMole is source-available. Personal non-commercial use is permitted; business and organizational use requires a paid commercial license.") {
                    if let url = Bundle.main.url(forResource: "MyMole-LICENSE", withExtension: "txt", subdirectory: "Licenses") {
                        Button("MyMole License") { NSWorkspace.shared.open(url) }
                    }
                }
            }
        }
    }

    /// A notification switch: turning it on asks macOS for permission, and
    /// it stays off when the user says no.
    private func notifying(_ setting: Binding<Bool>) -> Binding<Bool> {
        Binding(
            get: { setting.wrappedValue },
            set: { on in
                guard on else {
                    setting.wrappedValue = false
                    return
                }
                Task {
                    let allowed = await app.watch.authorize()
                    setting.wrappedValue = allowed
                    notificationsRefused = !allowed
                }
            })
    }

    /// Why a keep list isn't what the user sees, as the pane that uses it
    /// says it: nothing is removed against it until this is resolved.
    @ViewBuilder
    private func keepProblem(read: Problem?, save: Problem?, retry: @escaping () -> Void, discard: @escaping () -> Void) -> some View {
        if let read {
            DSNotice(.critical, "This list couldn't be read (\(read.description)). Nothing is removed against it until it can be.") {
                Button("Try Again", action: retry)
                CopyErrorCodeButton(read.code)
            }
        } else if let save {
            DSNotice(.critical, "Your change couldn't be saved (\(save.description)). Nothing is removed until it's saved or given up.") {
                Button("Try Again", action: retry)
                Button("Discard Change", action: discard)
                CopyErrorCodeButton(save.code)
            }
        }
    }
}

/// A sample list in the theme as chosen, so a theme can be judged before
/// leaving Settings. Nothing in it is a real result or can be clicked: the
/// accent shows as a swatch, not as a button.
private struct ThemePreview: View {
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            row("Sample row", selected: false)
            row("Selected row", selected: true)
            HStack(spacing: DS.Space.sm) {
                DSCapsule("Status", symbol: "clock")
                DSCapsule("Warning", symbol: "exclamationmark.triangle.fill", tint: palette.warning)
                Spacer(minLength: DS.Space.sm)
                Text("Accent")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, DS.Space.sm)
                    .frame(height: DS.Size.stripHeight - 6)
                    .background(palette.accent.color, in: .capsule)
            }
        }
        .padding(DS.Space.sm)
        .frame(maxWidth: 420, alignment: .leading)
        .background(palette.workspace.color, in: .rect(cornerRadius: DS.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(palette.separator.color, lineWidth: 1))
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of the \(palette.family.title) theme")
    }

    private func row(_ name: LocalizedStringResource, selected: Bool) -> some View {
        HStack(spacing: DS.Space.sm) {
            DSIcon(symbol: "folder", tint: palette.accentText.color)
            Text(name)
            Spacer(minLength: DS.Space.sm)
            Text("Secondary text").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, DS.Space.sm)
        .frame(height: DS.Size.rowMinHeight)
        .background(selected ? palette.selection : .clear, in: .rect(cornerRadius: DS.Radius.control))
        .dsCard(radius: DS.Radius.control)
    }
}


extension SettingsView {
    fileprivate func measureSaved() async {
        savedBytes = await Task.detached(priority: .utility) { SavedResults.bytes() }.value
    }
}

/// The interface's own timings, kept on this Mac when turned on: what a
/// report about slowness can include. Nothing is sent anywhere.
private struct TimingsSection: View {
    @AppStorage(Timings.key) private var keeping = false
    @State private var summary: [Timings.Summary] = []

    var body: some View {
        DSSection("Timings", rows: false) {
            DSFormGrid {
                DSFormRow("Interface", checkbox: true, help: "How long lists, table menus, app listings and Disk Map scans take, including the first content. Kept in memory until you quit; no file names or paths.") {
                    Toggle("Keep timings of the interface", isOn: $keeping)
                }
                if keeping {
                    DSFormRow("Measured") {
                        if summary.isEmpty {
                            Text("Nothing measured yet.").foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: DS.Space.xs) {
                                ForEach(summary, id: \.step) { s in
                                    LabeledContent(s.step.title) {
                                        Text("median \(Self.ms(s.median)) · p95 \(Self.ms(s.p95)) · longest \(Self.ms(s.longest)) · \(s.count)×")
                                            .monospacedDigit()
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    DSFormRow(nil) {
                        HStack {
                            Button("Copy Timings") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(Timings.text(), forType: .string)
                            }
                            .disabled(summary.isEmpty)
                            Button("Clear") {
                                Timings.clear()
                                summary = []
                            }
                            .disabled(summary.isEmpty)
                        }
                    }
                }
            }
        }
        .task(id: keeping) {
            while keeping, !Task.isCancelled {
                summary = Timings.summary()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private static func ms(_ seconds: Double) -> String {
        (seconds * 1_000).formatted(.number.precision(.fractionLength(seconds < 0.01 ? 1 : 0))) + " ms"
    }
}

/// The folders the Disk Map doesn't scan.
private struct DiskMapSkipsSection: View {
    @State private var paths = DiskMapSkips.paths()

    var body: some View {
        DSSection("Disk Map", footer: "A folder left out isn't read or counted, and isn't compared in Changes, so it never looks deleted. It's apart from Keep, which only stops moves, and from Browse's filter, which only hides rows.") {
            if paths.isEmpty {
                Text("Every folder is scanned. To leave one out, choose Don't Scan This Folder from its menu in Browse.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(paths, id: \.self) { p in
                    HStack {
                        DSPath(p, .mono)
                        Spacer()
                        Button("Scan Again") {
                            DiskMapSkips.remove(p)
                            paths = DiskMapSkips.paths()
                        }
                        .help("Include this folder in the next scan")
                    }
                }
            }
        }
    }
}

/// Each kind of saved result with its size and age, to clear on its own.
private struct SavedResultsList: View {
    let changed: () async -> Void
    @State private var parts: [SavedResults.Part] = []
    @State private var problem: String?
    @State private var pending: SavedResults.Part?
    @State private var confirming = false

    var body: some View {
        DisclosureGroup("Saved results by feature") {
            ForEach(parts.filter { $0.bytes > 0 }) { p in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.title)
                        Text(
                            [
                                ByteSize.format(p.bytes),
                                p.modified.map { String(localized: "saved \($0.formatted(.relative(presentation: .named)))") },
                            ].compactMap { $0 }.joined(separator: " · ")
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Clear Saved Results…") {
                        pending = p; confirming = true
                    }
                    .controlSize(.small)
                }
            }
            if let problem { Text(problem).foregroundStyle(.red) }
        }
        .task { await reload() }
        .actionConfirmation(
            String(localized: "Clear saved \(pending?.title ?? "") results?"), isPresented: $confirming,
            action: .savedResults, button: String(localized: "Clear Saved Results"),
            message: String(
                localized:
                    "Only these saved scan results are cleared. The next scan rebuilds them. Keep lists, project rules and cleanup history stay."
            )
        ) {
            guard let part = pending else { return }
            Task {
                let failed = await Task.detached(priority: .userInitiated) { SavedResults.clear(part) }.value
                problem = failed.isEmpty ? nil : String(localized: "Couldn't remove \(failed.joined(separator: ", ")).")
                await reload()
                await changed()
            }
        }
    }

    private func reload() async {
        parts = await Task.detached(priority: .utility) { SavedResults.parts() }.value
    }
}
