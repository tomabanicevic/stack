import AppKit
import ServiceManagement

// MARK: - Installed apps

struct InstalledApp: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let bundleID: String?
    var id: String { url.path }
    var isSystem: Bool { url.path.hasPrefix("/System/") }
}

enum InstalledApps {
    /// Lists the apps in the usual folders (one sub-folder deep, e.g. "/Applications/Adobe …/").
    static func scan() -> [InstalledApp] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let roots = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            home.appendingPathComponent("Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
        ]
        let ownID = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        var result: [InstalledApp] = []

        func consider(_ url: URL) {
            guard url.pathExtension.lowercased() == "app" else { return }
            let bundleID = Bundle(url: url)?.bundleIdentifier
            if let bundleID, bundleID == ownID { return }
            let key = bundleID ?? url.path
            guard !seen.contains(key) else { return }
            seen.insert(key)
            result.append(InstalledApp(url: url, name: AppItem.displayName(of: url), bundleID: bundleID))
        }

        for root in roots {
            guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles]) else { continue }
            for url in items {
                if url.pathExtension.lowercased() == "app" {
                    consider(url)
                } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                          let sub = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                                options: [.skipsHiddenFiles]) {
                    sub.forEach(consider)
                }
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Icons

@MainActor
final class IconCache {
    static let shared = IconCache()
    private var cache: [String: NSImage] = [:]

    func icon(for path: String) -> NSImage {
        if let image = cache[path] { return image }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache[path] = image
        return image
    }
}

// MARK: - Login item

@MainActor
final class LoginItem: ObservableObject {
    static let shared = LoginItem()

    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var lastError: String?

    private init() { refresh() }

    var isOn: Bool { status == .enabled || status == .requiresApproval }
    var needsApproval: Bool { status == .requiresApproval }

    func refresh() { status = SMAppService.mainApp.status }

    func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

// MARK: - Privacy panes

/// Shortcuts to the right place in System Settings › Privacy & Security.
/// macOS grants each permission to one specific app: Stack can't share its permissions,
/// but it can take you straight to the right pane.
enum PrivacyPane: String, CaseIterable, Identifiable {
    case accessibility = "Privacy_Accessibility"
    case screenRecording = "Privacy_ScreenCapture"
    case inputMonitoring = "Privacy_ListenEvent"
    case fullDiskAccess = "Privacy_AllFiles"
    case automation = "Privacy_Automation"
    case appManagement = "Privacy_AppBundles"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accessibility: return String(localized: "Accessibility")
        case .screenRecording: return String(localized: "Screen Recording")
        case .inputMonitoring: return String(localized: "Input Monitoring")
        case .fullDiskAccess: return String(localized: "Full Disk Access")
        case .automation: return String(localized: "Automation")
        case .appManagement: return String(localized: "App Management")
        }
    }

    var symbol: String {
        switch self {
        case .accessibility: return "accessibility"
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .inputMonitoring: return "keyboard"
        case .fullDiskAccess: return "internaldrive"
        case .automation: return "gearshape.2"
        case .appManagement: return "app.badge.checkmark"
        }
    }

    func open() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)") else { return }
        NSWorkspace.shared.open(url)
    }
}
