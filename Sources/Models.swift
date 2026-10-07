import Foundation

// MARK: - Launch mode

/// How an app is opened by Stack.
enum LaunchMode: String, Codable, CaseIterable, Identifiable {
    case normal
    case background
    case hidden
    case alwaysHidden

    var id: String { rawValue }

    var title: String {
        switch self {
        case .normal: return String(localized: "Normal")
        case .background: return String(localized: "Background")
        case .hidden: return String(localized: "Hidden")
        case .alwaysHidden: return String(localized: "Always hidden")
        }
    }

    var detail: String {
        switch self {
        case .normal: return String(localized: "Opens and comes to the front.")
        case .background: return String(localized: "Opens behind your current window, without stealing focus.")
        case .hidden: return String(localized: "Opens with its windows hidden. Ideal for apps that just need to run, like Spotify.")
        case .alwaysHidden: return String(localized: "Like Hidden, and stays hidden even when another app opens it (e.g. Sapphire opening Spotify). Stack keeps an icon in the menu bar for this.")
        }
    }

    /// Launched with its windows hidden.
    var startsHidden: Bool { self == .hidden || self == .alwaysHidden }

    var symbol: String {
        switch self {
        case .normal: return "macwindow"
        case .background: return "rectangle.on.rectangle"
        case .hidden: return "eye.slash"
        case .alwaysHidden: return "eye.slash.fill"
        }
    }
}

// MARK: - Group color

enum GroupColor: String, Codable, CaseIterable, Identifiable {
    case indigo, blue, teal, green, yellow, orange, red, pink, purple, gray
    var id: String { rawValue }
}

// MARK: - App item

/// A reference to an installed app: its bundle identifier (stable across updates) and its last
/// known path. Stack leaves the app alone unless you turn on "Out of Dock" or "In Stack".
struct AppItem: Codable, Identifiable, Hashable {
    var id: UUID
    var bundleID: String?
    var name: String
    var path: String
    var mode: LaunchMode
    /// "Out of Dock" (see DockRemoval).
    var removeFromDock: Bool
    /// "Keep open": Stack reopens the app if it closes.
    var keepOpen: Bool
    /// "In Stack": the app lives in Stack's own folder instead of Applications (see AppVault).
    var inStack: Bool
    /// Where the app was before it moved into Stack.
    var originalPath: String?

    init(id: UUID = UUID(), bundleID: String?, name: String, path: String, mode: LaunchMode = .normal,
         removeFromDock: Bool = false, keepOpen: Bool = false, inStack: Bool = false, originalPath: String? = nil) {
        self.id = id
        self.bundleID = bundleID
        self.name = name
        self.path = path
        self.mode = mode
        self.removeFromDock = removeFromDock
        self.keepOpen = keepOpen
        self.inStack = inStack
        self.originalPath = originalPath
    }

    enum CodingKeys: String, CodingKey { case id, bundleID, name, path, mode, removeFromDock, keepOpen, inStack, originalPath }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        bundleID = try? c.decodeIfPresent(String.self, forKey: .bundleID)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "App"
        path = (try? c.decodeIfPresent(String.self, forKey: .path)) ?? ""
        mode = (try? c.decodeIfPresent(LaunchMode.self, forKey: .mode)) ?? .normal
        removeFromDock = (try? c.decodeIfPresent(Bool.self, forKey: .removeFromDock)) ?? false
        keepOpen = (try? c.decodeIfPresent(Bool.self, forKey: .keepOpen)) ?? false
        inStack = (try? c.decodeIfPresent(Bool.self, forKey: .inStack)) ?? false
        originalPath = try? c.decodeIfPresent(String.self, forKey: .originalPath)
    }

    /// Identity used for de-duplication.
    var key: String {
        if let bundleID, !bundleID.isEmpty { return bundleID }
        return path
    }

    /// Builds an item from an `.app` URL (Finder drop, open panel, app list).
    static func make(from rawURL: URL) -> AppItem? {
        let url = rawURL.resolvingSymlinksInPath()
        guard url.pathExtension.lowercased() == "app" else { return nil }
        let bundleID = Bundle(url: url)?.bundleIdentifier
        if bundleID != nil, bundleID == Bundle.main.bundleIdentifier { return nil }
        return AppItem(bundleID: bundleID,
                       name: displayName(of: url),
                       path: url.path,
                       mode: defaultMode(for: bundleID),
                       inStack: AppVault.contains(url.path))
    }

    static func displayName(of url: URL) -> String {
        var name = FileManager.default.displayName(atPath: url.path)
        if name.lowercased().hasSuffix(".app") { name = String(name.dropLast(4)) }
        return name
    }

    /// Sensible defaults: Spotify only needs to run (e.g. for menu-bar players), so hide its window.
    static func defaultMode(for bundleID: String?) -> LaunchMode {
        switch bundleID {
        case "com.spotify.client": return .alwaysHidden
        default: return .normal
        }
    }
}

// MARK: - Group

struct AppGroup: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var symbol: String
    var color: GroupColor
    var openOnLaunch: Bool
    var apps: [AppItem]

    init(id: UUID = UUID(), name: String, symbol: String = "square.stack.3d.up.fill",
         color: GroupColor = .indigo, openOnLaunch: Bool = true, apps: [AppItem] = []) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.color = color
        self.openOnLaunch = openOnLaunch
        self.apps = apps
    }

    enum CodingKeys: String, CodingKey { case id, name, symbol, color, openOnLaunch, apps }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Group"
        symbol = (try? c.decodeIfPresent(String.self, forKey: .symbol)) ?? "square.stack.3d.up.fill"
        color = (try? c.decodeIfPresent(GroupColor.self, forKey: .color)) ?? .indigo
        openOnLaunch = (try? c.decodeIfPresent(Bool.self, forKey: .openOnLaunch)) ?? true
        apps = (try? c.decodeIfPresent([AppItem].self, forKey: .apps)) ?? []
    }

    static let placeholder = AppGroup(name: "")

    static let symbols: [String] = [
        "square.stack.3d.up.fill", "menubar.rectangle", "briefcase.fill", "music.note",
        "gamecontroller.fill", "hammer.fill", "sparkles", "bolt.fill",
        "figure.strengthtraining.traditional", "book.fill", "paintbrush.fill", "terminal.fill",
        "graduationcap.fill", "brain.head.profile", "globe", "camera.fill",
        "cup.and.saucer.fill", "heart.fill", "star.fill", "moon.fill",
    ]
}

// MARK: - Configuration

struct Config: Codable {
    var groups: [AppGroup]
    var showBubble: Bool

    init(groups: [AppGroup], showBubble: Bool = true) {
        self.groups = groups
        self.showBubble = showBubble
    }

    enum CodingKeys: String, CodingKey { case groups, showBubble }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groups = (try? c.decodeIfPresent([AppGroup].self, forKey: .groups)) ?? []
        showBubble = (try? c.decodeIfPresent(Bool.self, forKey: .showBubble)) ?? true
    }

    static var initial: Config {
        Config(groups: [AppGroup(name: String(localized: "My apps"),
                                 symbol: "square.stack.3d.up.fill",
                                 color: .indigo,
                                 openOnLaunch: true)])
    }
}
