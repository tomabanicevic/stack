import AppKit

// MARK: - Apps kept inside Stack (opt-in, per app)

enum VaultError: LocalizedError {
    case notFound
    case systemApp
    case stillRunning
    case nameTaken(String)
    case appManagementDenied
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return String(localized: "The app could not be found.")
        case .systemApp:
            return String(localized: "This is a system app: macOS doesn't let anyone move it.")
        case .stillRunning:
            return String(localized: "The app didn't quit. Quit it, then try again.")
        case .nameTaken(let folder):
            return String(localized: "There is already an app with this name in this folder:") + "\n" + folder
        case .appManagementDenied:
            return String(localized: "macOS blocked the change. Allow Stack in System Settings › Privacy & Security › App Management, then try again.")
        case .cancelled:
            return nil
        case .failed(let details):
            return String(localized: "The app couldn't be moved, so nothing was changed.") + "\n" + details
        }
    }
}

/// "In Stack": the real app is moved out of Applications into Stack's own folder
/// (~/Library/Application Support/Stack/Apps). It disappears from Applications, Launchpad and
/// Spotlight, and Stack opens it from there. The app itself is never modified, so putting it
/// back is a plain move in the other direction.
enum AppVault {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Stack/Apps", isDirectory: true)
    }

    static func contains(_ path: String) -> Bool {
        path.hasPrefix(directory.path + "/")
    }

    /// Where an app goes when it leaves Stack: where it came from, or Applications.
    static func homeURL(for item: AppItem) -> URL {
        let name = URL(fileURLWithPath: item.path).lastPathComponent
        if let original = item.originalPath, !original.isEmpty, !contains(original) {
            let parent = URL(fileURLWithPath: original).deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: parent.path) { return URL(fileURLWithPath: original) }
        }
        return URL(fileURLWithPath: "/Applications").appendingPathComponent(name)
    }

    static func move(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { throw VaultError.notFound }
        if fm.fileExists(atPath: destination.path) {
            throw VaultError.nameTaken(destination.deletingLastPathComponent().path)
        }
        try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try fm.moveItem(at: source, to: destination)
        } catch {
            let nsError = error as NSError
            let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            if underlying?.domain == NSPOSIXErrorDomain && underlying?.code == Int(EPERM) {
                throw VaultError.appManagementDenied
            }
            // App Store apps belong to root: macOS asks for an administrator password.
            try adminMove(source, to: destination)
        }
        DockPatcher.run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                        ["-f", destination.path])
    }

    private static func adminMove(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        let command = "/bin/mv -n \(shellQuoted(source.path)) \(shellQuoted(destination.path))"
            + " && /usr/sbin/chown -R \(getuid()):\(getgid()) \(shellQuoted(destination.path))"
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let result = DockPatcher.run("/usr/bin/osascript", ["-e", "do shell script \"\(escaped)\" with administrator privileges"])
        // The move is what matters (the owner change is a bonus): trust the disk, not the exit code.
        if fm.fileExists(atPath: destination.path) && !fm.fileExists(atPath: source.path) { return }
        if result.output.contains("-128") { throw VaultError.cancelled }
        if result.output.contains("Operation not permitted") { throw VaultError.appManagementDenied }
        throw VaultError.failed(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

@MainActor
final class VaultController: ObservableObject {
    static let shared = VaultController()

    /// Keys (see `AppItem.key`) of the apps being moved right now.
    @Published private(set) var busy: Set<String> = []

    // MARK: User actions

    func setInStack(_ value: Bool, for item: AppItem) {
        guard !busy.contains(item.key) else { return }
        if value {
            guard let url = Launcher.resolveURL(item) else { return }
            if AppVault.contains(url.path) {
                Store.shared.setInStack(true, key: item.key, path: url.path, originalPath: item.originalPath)
                return
            }
            guard confirm(name: item.name) else { return }
            Task { await move(item, from: url, into: true) }
        } else {
            putBack([item])
        }
    }

    /// Moves these apps back where they came from (also used when they leave their last group).
    func putBack(_ items: [AppItem]) {
        var seen = Set<String>()
        for item in items where seen.insert(item.key).inserted && !busy.contains(item.key) {
            let source = URL(fileURLWithPath: item.path)
            guard AppVault.contains(source.path), FileManager.default.fileExists(atPath: source.path) else {
                // Nothing in Stack's folder (reinstalled elsewhere…): just forget the flag.
                let path = Launcher.resolveURL(item)?.path ?? item.path
                Store.shared.setInStack(false, key: item.key, path: path, originalPath: nil)
                continue
            }
            Task { await move(item, from: source, into: false) }
        }
    }

    // MARK: Work

    private func move(_ item: AppItem, from source: URL, into: Bool) async {
        let key = item.key
        busy.insert(key)
        defer { busy.remove(key) }

        if into && source.path.hasPrefix("/System/") {
            showError(name: item.name, error: VaultError.systemApp, leftIn: nil)
            return
        }
        let destination = into ? AppVault.directory.appendingPathComponent(source.lastPathComponent)
                               : AppVault.homeURL(for: item)

        let wasRunning = await quitAndWait(item)
        if Launcher.isRunning(item) {
            showError(name: item.name, error: VaultError.stillRunning, leftIn: into ? nil : source)
            return
        }
        let result = await Task.detached(priority: .userInitiated) { () -> Result<Void, Error> in
            Result { try AppVault.move(source, to: destination) }
        }.value

        switch result {
        case .success:
            Store.shared.setInStack(into, key: key, path: destination.path, originalPath: into ? source.path : nil)
            if wasRunning { reopen(destination, mode: item.mode) }
        case .failure(let error):
            if wasRunning { reopen(source, mode: item.mode) }
            if case VaultError.cancelled = error, into { break }
            showError(name: item.name, error: error, leftIn: into ? nil : source)
        }
        RunningApps.shared.refresh()
    }

    private func quitAndWait(_ item: AppItem) async -> Bool {
        let apps = Launcher.runningApps(for: item)
        guard !apps.isEmpty else { return false }
        if let bundleID = item.bundleID { HideWatcher.shared.noteIntentionalQuit(bundleID) }
        apps.forEach { $0.terminate() }
        for _ in 0..<50 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if apps.allSatisfy(\.isTerminated) { break }
        }
        return true
    }

    private func reopen(_ url: URL, mode: LaunchMode) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = mode.startsHidden
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: nil)
    }

    // MARK: Alerts

    private func confirm(name: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Keep \(name) inside Stack?")
        alert.informativeText = String(localized: "Stack moves the real app into its own folder: it disappears from Applications, Launchpad and Spotlight, and you open it from Stack. Nothing inside the app is changed and it keeps its settings. If it's open, it quits and reopens. macOS may ask for your password. Updates from the App Store may no longer find it, and its own “open at login” may stop working (put it in an “open on click” group instead). You can put it back in Applications at any time.")
        alert.addButton(withTitle: String(localized: "Move into Stack"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// `leftIn`: the app is still in Stack's folder (a "put back" that failed).
    private func showError(name: String, error: Error, leftIn: URL?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Couldn't move \(name)")
        var text = error.localizedDescription
        if case VaultError.cancelled = error { text = "" }
        if leftIn != nil {
            text += (text.isEmpty ? "" : "\n\n") + String(localized: "The app is still in Stack's folder.")
        }
        alert.informativeText = text
        var isAppManagement = false
        if case VaultError.appManagementDenied = error { isAppManagement = true }
        if isAppManagement { alert.addButton(withTitle: String(localized: "Open Settings")) }
        alert.addButton(withTitle: String(localized: "OK"))
        if leftIn != nil { alert.addButton(withTitle: String(localized: "Show in Finder")) }
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if isAppManagement && response == .alertFirstButtonReturn {
            PrivacyPane.appManagement.open()
        } else if let leftIn, response == (isAppManagement ? .alertThirdButtonReturn : .alertSecondButtonReturn) {
            NSWorkspace.shared.activateFileViewerSelecting([leftIn])
        }
    }
}
