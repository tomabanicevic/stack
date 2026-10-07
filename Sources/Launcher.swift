import AppKit

// MARK: - Launcher

/// Opens and quits apps through Launch Services, exactly like a double-click in the Finder.
@MainActor
enum Launcher {
    /// Finds the app on disk: by bundle identifier first (survives updates and moves), then by path.
    static func resolveURL(_ item: AppItem) -> URL? {
        // "In Stack": the copy in Stack's folder wins, even if the app gets reinstalled elsewhere.
        if item.inStack, FileManager.default.fileExists(atPath: item.path) {
            return URL(fileURLWithPath: item.path)
        }
        if let bundleID = item.bundleID, !bundleID.isEmpty,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url
        }
        if !item.path.isEmpty, FileManager.default.fileExists(atPath: item.path) {
            return URL(fileURLWithPath: item.path)
        }
        return nil
    }

    static func runningApps(for item: AppItem) -> [NSRunningApplication] {
        if let bundleID = item.bundleID, !bundleID.isEmpty {
            return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        }
        let target = URL(fileURLWithPath: item.path).standardizedFileURL.path
        return NSWorkspace.shared.runningApplications.filter {
            $0.bundleURL?.standardizedFileURL.path == target
        }
    }

    static func isRunning(_ item: AppItem) -> Bool { !runningApps(for: item).isEmpty }

    static func open(url: URL, mode: LaunchMode) async throws -> NSRunningApplication {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.addsToRecentItems = false
        configuration.activates = (mode == .normal)
        configuration.hides = mode.startsHidden
        return try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    /// Opens the given apps right away (used by the Settings window buttons).
    static func launchNow(_ items: [AppItem]) {
        guard !items.isEmpty else { return }
        LaunchSession(items: items).start()
    }

    /// Politely asks the apps to quit (same as ⌘Q, so they can save their work).
    static func quit(_ items: [AppItem]) {
        let me = Bundle.main.bundleIdentifier
        for item in items where item.bundleID == nil || item.bundleID != me {
            if let bundleID = item.bundleID { HideWatcher.shared.noteIntentionalQuit(bundleID) }
            for app in runningApps(for: item) { app.terminate() }
        }
    }
}

// MARK: - Launch session

enum LaunchState: Equatable {
    case pending, launching, launched, alreadyRunning, missing, failed
}

/// One "open these apps" run. Observable so the bubble can show live progress.
@MainActor
final class LaunchSession: ObservableObject {
    struct Entry: Identifiable {
        let item: AppItem
        var state: LaunchState
        var id: UUID { item.id }
    }

    /// Number of sessions still working (launching or keeping apps hidden).
    private(set) static var activeCount = 0
    /// Called when the last active session finishes.
    static var onAllIdle: (() -> Void)?

    @Published private(set) var entries: [Entry]
    @Published private(set) var launchesDone = false
    private var hiddenApps: [NSRunningApplication] = []

    init(items: [AppItem]) {
        entries = items.map { Entry(item: $0, state: .pending) }
    }

    func start(onLaunchesDone: (() -> Void)? = nil) {
        Self.activeCount += 1
        Task {
            await runLaunches()
            onLaunchesDone?()
            await keepHiddenAppsHidden()
            Self.activeCount -= 1
            if Self.activeCount == 0 { Self.onAllIdle?() }
        }
    }

    var openedCount: Int { entries.filter { $0.state == .launched }.count }
    var alreadyRunningCount: Int { entries.filter { $0.state == .alreadyRunning }.count }
    var problemCount: Int { entries.filter { $0.state == .missing || $0.state == .failed }.count }

    private func runLaunches() async {
        let count = entries.count
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<count {
                group.addTask { await self.launch(index) }
            }
        }
        launchesDone = true
    }

    private func launch(_ index: Int) async {
        let item = entries[index].item
        // Already open: don't touch it (re-opening a menu-bar app often pops its settings window).
        if Launcher.isRunning(item) {
            entries[index].state = .alreadyRunning
            return
        }
        guard let url = Launcher.resolveURL(item) else {
            entries[index].state = .missing
            return
        }
        entries[index].state = .launching
        do {
            let app = try await Launcher.open(url: url, mode: item.mode)
            entries[index].state = .launched
            if item.mode.startsHidden { hiddenApps.append(app) }
        } catch {
            NSLog("Stack: could not open \(item.name): \(error.localizedDescription)")
            entries[index].state = .failed
        }
    }

    /// Some apps (Spotify…) show their window a moment after launching even when asked to start
    /// hidden. We re-hide them a few times during the first seconds.
    private func keepHiddenAppsHidden() async {
        let apps = hiddenApps
        guard !apps.isEmpty else { return }
        await Launcher.keepHidden(apps)
    }
}

extension Launcher {
    /// Re-hides apps a few times during their first seconds (they often pop their window late).
    static func keepHidden(_ apps: [NSRunningApplication]) async {
        for delay in [0.15, 0.35, 0.6, 1.0, 1.5, 2.5] {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            for app in apps where !app.isTerminated && (!app.isHidden || app.isActive) {
                app.hide()
            }
        }
    }
}

// MARK: - Running apps watcher

/// Publishes which apps are running so the UI can show live status dots.
@MainActor
final class RunningApps: ObservableObject {
    static let shared = RunningApps()

    @Published private(set) var bundleIDs: Set<String> = []
    @Published private(set) var paths: Set<String> = []
    private var observation: NSKeyValueObservation?

    private init() {
        refresh()
        observation = NSWorkspace.shared.observe(\.runningApplications, options: [.new]) { _, _ in
            Task { @MainActor in RunningApps.shared.refresh() }
        }
    }

    func refresh() {
        let apps = NSWorkspace.shared.runningApplications
        bundleIDs = Set(apps.compactMap(\.bundleIdentifier))
        paths = Set(apps.compactMap { $0.bundleURL?.path })
    }

    func isRunning(_ item: AppItem) -> Bool {
        if let bundleID = item.bundleID, !bundleID.isEmpty { return bundleIDs.contains(bundleID) }
        return paths.contains(item.path)
    }
}
