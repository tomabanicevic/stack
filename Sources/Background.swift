import AppKit
import Combine

// MARK: - Dock removal (opt-in, per app)

enum DockPatchError: LocalizedError {
    case notFound
    case appManagementDenied
    case notWritable
    case stillRunning
    case signFailed(String)
    case noBackup
    case protectedApp
    case didNotStart

    var errorDescription: String? {
        switch self {
        case .notFound:
            return String(localized: "The app could not be found.")
        case .appManagementDenied:
            return String(localized: "macOS blocked the change. Allow Stack in System Settings › Privacy & Security › App Management, then try again.")
        case .notWritable:
            return String(localized: "This app belongs to an administrator account, so Stack can't change it.")
        case .stillRunning:
            return String(localized: "The app didn't quit. Quit it, then try again.")
        case .signFailed(let details):
            return String(localized: "The app couldn't be re-signed, so nothing was changed.") + "\n" + details
        case .noBackup:
            return String(localized: "No backup found. Reinstall the app to get its Dock icon back.")
        case .protectedApp:
            return String(localized: "This app uses protected Apple features (iCloud, keychain…) or is a system app, so it can't be changed safely.")
        case .didNotStart:
            return String(localized: "This app refuses to run once it's modified (it checks its own signature). Stack put it back as it was: it has to stay in the Dock.")
        }
    }
}

/// Removes an app from the Dock by setting `LSUIElement` in its Info.plist (what menu bar apps do),
/// then re-signs it ad hoc so macOS still launches it. The three files touched are backed up first,
/// so "Restore" puts the app back exactly as it was, original signature included.
enum DockPatcher {
    static let markerKey = "StackRemovedFromDock"

    static func infoURL(_ app: URL) -> URL { app.appendingPathComponent("Contents/Info.plist") }

    static func readInfo(_ app: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: infoURL(app)) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
    }

    static func isPatched(_ app: URL) -> Bool {
        (readInfo(app)?[markerKey] as? Bool) == true
    }

    /// Menu bar apps that never show in the Dock anyway (Sapphire, Vorssaint…).
    static func nativelyHidden(_ app: URL) -> Bool {
        guard let info = readInfo(app), (info[markerKey] as? Bool) != true else { return false }
        if let flag = info["LSUIElement"] as? Bool { return flag }
        if let flag = info["LSUIElement"] as? String { return flag == "1" || flag.lowercased() == "true" }
        if let flag = info["LSUIElement"] as? Int { return flag != 0 }
        return (info["LSBackgroundOnly"] as? Bool) == true
    }

    static func backupDir(_ bundleID: String) -> URL {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Stack/DockBackups", isDirectory: true)
        return base.appendingPathComponent(bundleID, isDirectory: true)
    }

    static func hasBackup(_ bundleID: String) -> Bool {
        FileManager.default.fileExists(atPath: backupDir(bundleID).appendingPathComponent("Contents/Info.plist").path)
    }

    static func backedUpBundleIDs() -> [String] {
        let base = backupDir("x").deletingLastPathComponent()
        return (try? FileManager.default.contentsOfDirectory(atPath: base.path))?.filter { !$0.hasPrefix(".") } ?? []
    }

    private static func touchedFiles(_ app: URL) -> [String] {
        let exe = readInfo(app)?["CFBundleExecutable"] as? String
        return ["Contents/Info.plist", "Contents/_CodeSignature/CodeResources"] + (exe.map { ["Contents/MacOS/\($0)"] } ?? [])
    }

    /// Entitlements that only work with the developer's own signature: re-signing would break the app.
    static func isProtected(_ app: URL) -> Bool {
        if app.path.hasPrefix("/System/") { return true }
        let result = run("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", app.path], stderr: false)
        guard let start = result.output.range(of: "<?xml") ?? result.output.range(of: "<plist") else { return false }
        let xml = String(result.output[start.lowerBound...])
        guard let data = xml.data(using: .utf8),
              let entitlements = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
        else { return false }
        return entitlements.keys.contains { key in
            key.hasPrefix("com.apple.developer.") || key == "keychain-access-groups"
                || key == "com.apple.application-identifier" || key == "application-identifier"
        }
    }

    static func patch(app: URL, bundleID: String) throws {
        let fm = FileManager.default
        guard var info = readInfo(app) else { throw DockPatchError.notFound }
        if isProtected(app) { throw DockPatchError.protectedApp }
        let files = touchedFiles(app)

        // 1. Back up the original files (signature included).
        let backup = backupDir(bundleID)
        try? fm.removeItem(at: backup)
        for rel in files {
            let source = app.appendingPathComponent(rel)
            guard fm.fileExists(atPath: source.path) else { continue }
            let target = backup.appendingPathComponent(rel)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: target)
        }

        // 2. No Dock icon, like a menu bar app.
        info["LSUIElement"] = true
        info[markerKey] = true
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        do {
            try data.write(to: infoURL(app))
        } catch {
            try? fm.removeItem(at: backup)
            throw mapWriteError(error)
        }

        // 3. Re-sign (ad hoc) so macOS accepts the modified app. On failure, put everything back.
        let result = run("/usr/bin/codesign", ["--force", "--sign", "-", "--preserve-metadata=entitlements", app.path])
        if result.status != 0 {
            try? restoreFiles(app: app, bundleID: bundleID)
            throw DockPatchError.signFailed(result.output)
        }
        refreshLaunchServices(app)
    }

    static func restore(app: URL, bundleID: String) throws {
        if isPatched(app) {
            guard hasBackup(bundleID) else { throw DockPatchError.noBackup }
            try restoreFiles(app: app, bundleID: bundleID)
        }
        try? FileManager.default.removeItem(at: backupDir(bundleID))
        refreshLaunchServices(app)
    }

    private static func restoreFiles(app: URL, bundleID: String) throws {
        let fm = FileManager.default
        let backup = backupDir(bundleID)
        for rel in touchedFiles(app) {
            let saved = backup.appendingPathComponent(rel)
            guard fm.fileExists(atPath: saved.path) else { continue }
            let target = app.appendingPathComponent(rel)
            do {
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.copyItem(at: saved, to: target)
            } catch {
                throw mapWriteError(error)
            }
        }
    }

    private static func mapWriteError(_ error: Error) -> Error {
        let nsError = error as NSError
        let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        if underlying?.domain == NSPOSIXErrorDomain && underlying?.code == Int(EACCES) {
            return DockPatchError.notWritable
        }
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteNoPermissionError {
            return DockPatchError.appManagementDenied
        }
        if underlying?.domain == NSPOSIXErrorDomain && underlying?.code == Int(EPERM) {
            return DockPatchError.appManagementDenied
        }
        return error
    }

    private static func refreshLaunchServices(_ app: URL) {
        run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
            ["-f", app.path])
    }

    @discardableResult
    static func run(_ path: String, _ arguments: [String], stderr: Bool = true) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = stderr ? pipe : FileHandle.nullDevice
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

/// "Out of Dock" for regular apps: Stack sets LSUIElement in the app and re-signs it (DockPatcher),
/// then checks the app still starts; otherwise everything is put back.
@MainActor
final class DockRemoval: ObservableObject {
    static let shared = DockRemoval()

    @Published private(set) var working = false
    private var wanted: [String: String] = [:]   // bundleID → name (regular apps only)
    private var busy: Set<String> = []
    private var failed: Set<String> = []
    private var suspendSync = false

    /// Every app of your groups (Stack excluded), without duplicates.
    static func candidates(_ config: Config) -> [(bundleID: String, name: String, url: URL, removed: Bool)] {
        var seen = Set<String>()
        var result: [(bundleID: String, name: String, url: URL, removed: Bool)] = []
        for item in config.groups.flatMap(\.apps) {
            guard let bundleID = item.bundleID, !bundleID.isEmpty, !seen.contains(bundleID),
                  bundleID != Bundle.main.bundleIdentifier, let url = Launcher.resolveURL(item),
                  !DockPatcher.nativelyHidden(url) else { continue }
            seen.insert(bundleID)
            result.append((bundleID, item.name, url, item.removeFromDock))
        }
        return result
    }

    // MARK: User actions

    func setOutOfDock(_ value: Bool, for item: AppItem) {
        guard let bundleID = item.bundleID, let url = Launcher.resolveURL(item) else { return }
        if value { enable(bundleID: bundleID, name: item.name, url: url) } else { disable(bundleID: bundleID, name: item.name, url: url) }
    }

    private func enable(bundleID: String, name: String, url: URL) {
        // Menu bar apps decide themselves when to show a Dock icon (while their window is open).
        // Closing their window makes macOS quit them, so Stack leaves them alone.
        if DockPatcher.nativelyHidden(url) { return }
        guard confirmRemoval(names: [name]) else { return }
        failed.remove(bundleID)
        setFlagQuietly(true, bundleID)
        perform(bundleID: bundleID, name: name, url: url, patch: true, quitIfRunning: true)
    }

    private func disable(bundleID: String, name: String, url: URL) {
        setFlagQuietly(false, bundleID)
        failed.remove(bundleID)
        perform(bundleID: bundleID, name: name, url: url, patch: false, quitIfRunning: true)
    }

    /// "Remove all my apps from the Dock".
    func enableAll() {
        let regular = Self.candidates(Store.shared.config).filter { !$0.removed }
        guard !regular.isEmpty, confirmRemoval(names: regular.map { $0.name }) else { return }
        suspendSync = true
        for app in regular { Store.shared.setRemoveFromDock(true, bundleID: app.bundleID) }
        suspendSync = false
        runBatch(regular.map { ($0.bundleID, $0.name, $0.url) }, patch: true)
    }

    /// "Put all my apps back in the Dock".
    func disableAll() {
        let apps = Self.candidates(Store.shared.config)
        suspendSync = true
        for app in apps { Store.shared.setRemoveFromDock(false, bundleID: app.bundleID) }
        suspendSync = false
        let patched = apps.filter { DockPatcher.isPatched($0.url) || DockPatcher.hasBackup($0.bundleID) }
        runBatch(patched.map { ($0.bundleID, $0.name, $0.url) }, patch: false)
    }

    private func runBatch(_ apps: [(bundleID: String, name: String, url: URL)], patch: Bool) {
        guard !apps.isEmpty else { return }
        working = true
        Task {
            var failures: [(name: String, error: Error)] = []
            for app in apps {
                failed.remove(app.bundleID)
                if let error = await work(bundleID: app.bundleID, url: app.url, patch: patch, quitIfRunning: true) {
                    failures.append((app.name, error))
                    if patch { setFlagQuietly(false, app.bundleID) }
                }
            }
            working = false
            RunningApps.shared.refresh()
            guard !failures.isEmpty else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Some apps couldn't be changed")
            alert.informativeText = failures.map { "• \($0.name) : \($0.error.localizedDescription)" }.joined(separator: "\n")
            let needsAppManagement = failures.contains { if case .appManagementDenied? = $0.error as? DockPatchError { return true } else { return false } }
            if needsAppManagement { alert.addButton(withTitle: String(localized: "Open Settings")) }
            alert.addButton(withTitle: String(localized: "OK"))
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn && needsAppManagement { PrivacyPane.appManagement.open() }
        }
    }

    private func confirmRemoval(names: [String]) -> Bool {
        let alert = NSAlert()
        if names.count == 1 {
            alert.messageText = String(localized: "Remove \(names[0]) from the Dock?")
        } else {
            alert.messageText = String(localized: "Remove \(names.count) apps from the Dock?")
        }
        let list = names.count > 1 ? names.joined(separator: ", ") + "\n\n" : ""
        alert.informativeText = list + String(localized: "Stack changes one setting inside each app so it behaves like a menu bar app: no Dock icon, reachable from the menu bar. Running apps quit and reopen. An app may ask you to log in again, and Stack redoes this automatically after each update. You can put everything back at any time.")
        alert.addButton(withTitle: String(localized: "Remove from Dock"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func setFlagQuietly(_ value: Bool, _ bundleID: String) {
        suspendSync = true
        Store.shared.setRemoveFromDock(value, bundleID: bundleID)
        suspendSync = false
    }

    // MARK: Automatic maintenance (after app updates)

    func sync(_ config: Config) {
        var result: [String: String] = [:]
        for item in config.groups.flatMap(\.apps) where item.removeFromDock {
            guard let bundleID = item.bundleID, !bundleID.isEmpty,
                  let url = Launcher.resolveURL(item), !DockPatcher.nativelyHidden(url) || DockPatcher.isPatched(url) else { continue }
            result[bundleID] = item.name
        }
        wanted = result
        guard !working, !suspendSync else { return }
        for (bundleID, name) in result { maintain(bundleID: bundleID, name: name, quitIfRunning: false) }
        for bundleID in DockPatcher.backedUpBundleIDs() where result[bundleID] == nil {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { continue }
            if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
                perform(bundleID: bundleID, name: bundleID, url: url, patch: false, quitIfRunning: false)
            }
        }
    }

    func appLaunched(_ bundleID: String) {
        guard let name = wanted[bundleID] else { return }
        maintain(bundleID: bundleID, name: name, quitIfRunning: true)
    }

    func appTerminated(_ bundleID: String) {
        guard let name = wanted[bundleID] else { return }
        maintain(bundleID: bundleID, name: name, quitIfRunning: false)
    }

    private func maintain(bundleID: String, name: String, quitIfRunning: Bool) {
        guard !failed.contains(bundleID),
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              !DockPatcher.isPatched(url), !DockPatcher.nativelyHidden(url) else { return }
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        if running && !quitIfRunning { return }
        perform(bundleID: bundleID, name: name, url: url, patch: true, quitIfRunning: quitIfRunning)
    }

    // MARK: Work

    private func perform(bundleID: String, name: String, url: URL, patch: Bool, quitIfRunning: Bool) {
        Task {
            guard let error = await work(bundleID: bundleID, url: url, patch: patch, quitIfRunning: quitIfRunning) else {
                RunningApps.shared.refresh()
                return
            }
            if patch { setFlagQuietly(false, bundleID) }
            showError(name: name, error: error)
        }
    }

    /// Does the change (no UI). Returns the error, if any.
    private func work(bundleID: String, url: URL, patch: Bool, quitIfRunning: Bool) async -> Error? {
        guard !busy.contains(bundleID) else { return nil }
        if patch && (DockPatcher.isPatched(url) || DockPatcher.nativelyHidden(url)) { return nil }
        if !patch && !DockPatcher.isPatched(url) && !DockPatcher.hasBackup(bundleID) { return nil }
        busy.insert(bundleID)
        defer { busy.remove(bundleID) }

        var wasRunning = false
        if quitIfRunning {
            wasRunning = await quitAndWait(bundleID)
            if !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
                return DockPatchError.stillRunning
            }
        }
        let result = await Task.detached(priority: .userInitiated) { () -> Result<Void, Error> in
            Result {
                if patch {
                    try DockPatcher.patch(app: url, bundleID: bundleID)
                } else {
                    try DockPatcher.restore(app: url, bundleID: bundleID)
                }
            }
        }.value
        if case .failure(let error) = result {
            if wasRunning { reopen(url, hidden: false) }
            failed.insert(bundleID)
            return error
        }
        guard patch else {
            if wasRunning { reopen(url, hidden: false) }
            return nil
        }

        // Some apps (Spotify…) check their own signature and quit when modified.
        // Start it (hidden) and make sure it stays open; otherwise undo everything.
        reopen(url, hidden: true)
        try? await Task.sleep(nanoseconds: 7_000_000_000)
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        if running.isEmpty {
            _ = await Task.detached { try? DockPatcher.restore(app: url, bundleID: bundleID) }.value
            failed.insert(bundleID)
            reopen(url, hidden: !wasRunning)
            return DockPatchError.didNotStart
        }
        if !wasRunning {
            HideWatcher.shared.noteIntentionalQuit(bundleID)
            running.forEach { $0.terminate() }
        }
        return nil
    }

    private func showError(name: String, error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Couldn't change \(name)")
        alert.informativeText = error.localizedDescription
        var isAppManagement = false
        if let patchError = error as? DockPatchError, case .appManagementDenied = patchError { isAppManagement = true }
        if isAppManagement { alert.addButton(withTitle: String(localized: "Open Settings")) }
        alert.addButton(withTitle: String(localized: "OK"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn && isAppManagement { PrivacyPane.appManagement.open() }
    }

    private func quitAndWait(_ bundleID: String) async -> Bool {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard !apps.isEmpty else { return false }
        HideWatcher.shared.noteIntentionalQuit(bundleID)
        apps.forEach { $0.terminate() }
        for _ in 0..<50 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if apps.allSatisfy(\.isTerminated) { break }
        }
        return true
    }

    private func reopen(_ url: URL, hidden: Bool) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = !hidden
        configuration.hides = hidden
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: nil)
    }
}

// MARK: - Background watcher

/// Keeps Stack alive in the menu bar while some apps need it:
/// • "Always hidden": hides the app whenever any app launches it (e.g. Sapphire starting Spotify)
/// • "Keep open": reopens the app if it closes (unless you quit it from Stack)
/// • "Out of Dock": re-applies the change after an app updates itself
@MainActor
final class HideWatcher: ObservableObject {
    static let shared = HideWatcher()

    /// Bundle identifier → display name of the apps Stack looks after.
    @Published private(set) var apps: [String: String] = [:]
    private var alwaysHidden: Set<String> = []
    private var keepOpen: [String: AppItem] = [:]
    private var paused: Set<String> = []              // quit from Stack: don't reopen until next launch
    private var relaunchLog: [String: [Date]] = [:]
    private var allowVisibleLaunch: Set<String> = []
    private var observers: [NSObjectProtocol] = []

    var isActive: Bool { !observers.isEmpty }
    var names: String { apps.values.sorted().joined(separator: ", ") }
    var sortedApps: [(bundleID: String, name: String)] {
        apps.map { ($0.key, $0.value) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func update(from config: Config) {
        var result: [String: String] = [:]
        var always = Set<String>()
        var keep: [String: AppItem] = [:]
        for item in config.groups.flatMap(\.apps) where item.mode.startsHidden || item.removeFromDock || item.keepOpen {
            guard let bundleID = item.bundleID, !bundleID.isEmpty else { continue }
            result[bundleID] = item.name
            if item.mode == .alwaysHidden { always.insert(bundleID) }
            if item.keepOpen { keep[bundleID] = item }
        }
        if result != apps { apps = result }
        alwaysHidden = always
        keepOpen = keep
        if result.isEmpty { stop() } else { start() }
        DockRemoval.shared.sync(config)
    }

    /// Opens the next launch of this app normally (used when you open it from the menu bar).
    func allowNextVisibleLaunch(_ bundleID: String) { allowVisibleLaunch.insert(bundleID) }

    /// Quit from Stack ("Quit", "Quit all"): don't reopen it automatically.
    func noteIntentionalQuit(_ bundleID: String) { paused.insert(bundleID) }

    /// Opens every "Keep open" app that isn't running (at Stack's start, or when the option is turned on).
    func ensureKeptOpen() {
        for (bundleID, item) in keepOpen where !paused.contains(bundleID) {
            if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty { relaunch(item) }
        }
    }

    private func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let events: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ]
        for name in events {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let bundleID = app.bundleIdentifier else { return }
                let pid = app.processIdentifier
                let event = note.name
                Task { @MainActor in HideWatcher.shared.handle(event, bundleID: bundleID, pid: pid) }
            })
        }
    }

    private func stop() {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
    }

    private func handle(_ event: Notification.Name, bundleID: String, pid: pid_t) {
        guard apps[bundleID] != nil else { return }
        switch event {
        case NSWorkspace.didTerminateApplicationNotification:
            DockRemoval.shared.appTerminated(bundleID)
            if let item = keepOpen[bundleID], !paused.contains(bundleID) { relaunch(item) }
        default: // launched
            paused.remove(bundleID)
            DockRemoval.shared.appLaunched(bundleID)
            let visible = allowVisibleLaunch.remove(bundleID) != nil
            if alwaysHidden.contains(bundleID), !visible, let app = NSRunningApplication(processIdentifier: pid) {
                app.hide()
                Task { await Launcher.keepHidden([app]) }
            }
        }
    }

    /// Reopens a "Keep open" app in the background (at most 3 times per minute, in case it crashes).
    private func relaunch(_ item: AppItem) {
        guard let bundleID = item.bundleID else { return }
        let now = Date()
        var log = (relaunchLog[bundleID] ?? []).filter { now.timeIntervalSince($0) < 60 }
        guard log.count < 3 else { return }
        log.append(now)
        relaunchLog[bundleID] = log
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty,
                  let url = Launcher.resolveURL(item) else { return }
            _ = try? await Launcher.open(url: url, mode: item.mode == .normal ? .background : item.mode)
        }
    }
}

// MARK: - Menu bar icon

/// Stack's icon in the menu bar: the apps it looks after (click to show / hide them) and quick actions.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    var onOpenGroups: (() -> Void)?
    var onSettings: (() -> Void)?
    var onQuitAll: (() -> Void)?

    private var item: NSStatusItem?
    private var cancellable: AnyCancellable?

    func start() {
        cancellable = HideWatcher.shared.$apps
            .receive(on: DispatchQueue.main)
            .sink { [weak self] apps in
                self?.setVisible(!apps.isEmpty)
            }
    }

    private func setVisible(_ visible: Bool) {
        if visible, item == nil {
            let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            if let button = statusItem.button {
                let image = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: "Stack")
                image?.isTemplate = true
                button.image = image
                button.toolTip = "Stack"
            }
            let menu = NSMenu()
            menu.delegate = self
            statusItem.menu = menu
            item = statusItem
        } else if !visible, let existing = item {
            NSStatusBar.system.removeStatusItem(existing)
            item = nil
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem(title: String(localized: "Hidden apps"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        for entry in HideWatcher.shared.sortedApps {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: entry.bundleID).first
            let menuItem = NSMenuItem(title: entry.name, action: #selector(toggleApp(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = entry.bundleID
            menuItem.state = (running != nil && running?.isHidden == false) ? .on : .off
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.bundleID),
               let icon = NSWorkspace.shared.icon(forFile: url.path).copy() as? NSImage {
                icon.size = NSSize(width: 16, height: 16)
                menuItem.image = icon
            }
            menu.addItem(menuItem)
        }

        menu.addItem(.separator())
        menu.addItem(actionItem(String(localized: "Open my groups"), #selector(openGroups)))
        menu.addItem(actionItem(String(localized: "Quit all apps"), #selector(quitAll)))
        menu.addItem(.separator())
        menu.addItem(actionItem(String(localized: "Settings…"), #selector(openSettings)))
        menu.addItem(actionItem(String(localized: "Quit Stack"), #selector(quitStack)))
    }

    private func actionItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        return menuItem
    }

    /// Hidden → show it; visible → hide it; not running → open it (visible).
    @objc private func toggleApp(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            if app.isHidden || !app.isActive {
                app.unhide()
                app.activate(options: [.activateAllWindows])
            } else {
                app.hide()
            }
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            HideWatcher.shared.allowNextVisibleLaunch(bundleID)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: nil)
        }
    }

    @objc private func openGroups() { onOpenGroups?() }
    @objc private func quitAll() { onQuitAll?() }
    @objc private func openSettings() { onSettings?() }
    @objc private func quitStack() { NSApp.terminate(nil) }
}
