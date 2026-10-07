import AppKit
import SwiftUI

/// Holds the configuration and persists it as JSON in
/// ~/Library/Application Support/Stack/config.json
@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published var config: Config {
        didSet {
            save()
            HideWatcher.shared.update(from: config)
        }
    }

    let fileURL: URL

    private init() {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true))
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Stack", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("config.json")

        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? JSONDecoder().decode(Config.self, from: data) {
            config = loaded
        } else {
            config = .initial
        }
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(config).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Stack: could not save config: \(error.localizedDescription)")
        }
    }

    // MARK: Queries

    var hasAnyApp: Bool { config.groups.contains { !$0.apps.isEmpty } }

    /// Apps of every group marked "open on click", without duplicates.
    var launchItems: [AppItem] { unique(config.groups.filter(\.openOnLaunch).flatMap(\.apps)) }

    /// Every app of every group, without duplicates.
    var allItems: [AppItem] { unique(config.groups.flatMap(\.apps)) }

    /// Apps that live inside Stack ("In Stack").
    var inStackItems: [AppItem] { allItems.filter(\.inStack) }

    func groupIndex(_ id: UUID) -> Int? { config.groups.firstIndex { $0.id == id } }

    func group(_ id: UUID) -> AppGroup? { config.groups.first { $0.id == id } }

    /// A binding that stays valid even if the group is deleted while a view still shows it.
    func groupBinding(_ id: UUID) -> Binding<AppGroup> {
        Binding(
            get: { self.group(id) ?? .placeholder },
            set: { newValue in
                guard let index = self.groupIndex(id) else { return }
                self.config.groups[index] = newValue
            }
        )
    }

    private func unique(_ items: [AppItem]) -> [AppItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.key).inserted }
    }

    // MARK: Groups

    @discardableResult
    func addGroup() -> UUID {
        let usedColors = Set(config.groups.map(\.color))
        let color = GroupColor.allCases.first { !usedColors.contains($0) } ?? .blue
        let symbols = AppGroup.symbols
        let group = AppGroup(name: uniqueGroupName(),
                             symbol: symbols[(config.groups.count + 1) % symbols.count],
                             color: color,
                             openOnLaunch: true)
        config.groups.append(group)
        return group.id
    }

    func deleteGroup(_ id: UUID) {
        let leaving = group(id)?.apps ?? []
        config.groups.removeAll { $0.id == id }
        putBackOrphans(leaving)
    }

    func toggleOpenOnLaunch(_ id: UUID) {
        guard let index = groupIndex(id) else { return }
        config.groups[index].openOnLaunch.toggle()
    }

    func moveGroups(from source: IndexSet, to destination: Int) {
        config.groups.move(fromOffsets: source, toOffset: destination)
    }

    private func uniqueGroupName() -> String {
        let base = String(localized: "New group")
        let names = Set(config.groups.map(\.name))
        if !names.contains(base) { return base }
        var i = 2
        while names.contains("\(base) \(i)") { i += 1 }
        return "\(base) \(i)"
    }

    // MARK: Apps

    @discardableResult
    func add(urls: [URL], to groupID: UUID) -> Int {
        guard let index = groupIndex(groupID) else { return 0 }
        var group = config.groups[index]
        var existing = Set(group.apps.map(\.key))
        var added = 0
        for url in urls {
            guard let item = AppItem.make(from: url), !existing.contains(item.key) else { continue }
            group.apps.append(item)
            existing.insert(item.key)
            added += 1
        }
        if added > 0 { config.groups[index] = group }
        return added
    }

    func removeApp(_ appID: UUID, from groupID: UUID) {
        guard let index = groupIndex(groupID) else { return }
        let leaving = config.groups[index].apps.filter { $0.id == appID }
        config.groups[index].apps.removeAll { $0.id == appID }
        putBackOrphans(leaving)
    }

    /// An "In Stack" app that leaves its last group goes back to Applications,
    /// so no app is ever left behind in Stack's folder.
    private func putBackOrphans(_ removed: [AppItem]) {
        let remaining = Set(config.groups.flatMap(\.apps).map(\.key))
        let orphans = removed.filter { $0.inStack && !remaining.contains($0.key) }
        if !orphans.isEmpty { VaultController.shared.putBack(orphans) }
    }

    func moveApps(in groupID: UUID, from source: IndexSet, to destination: Int) {
        guard let index = groupIndex(groupID) else { return }
        config.groups[index].apps.move(fromOffsets: source, toOffset: destination)
    }

    func setMode(_ mode: LaunchMode, for appID: UUID, in groupID: UUID) {
        guard let g = groupIndex(groupID),
              let a = config.groups[g].apps.firstIndex(where: { $0.id == appID }) else { return }
        config.groups[g].apps[a].mode = mode
    }

    /// Sets "Keep open" for every item pointing to this app, and opens it right away when turned on.
    func setKeepOpen(_ value: Bool, bundleID: String) {
        var groups = config.groups
        for g in groups.indices {
            for a in groups[g].apps.indices where groups[g].apps[a].bundleID == bundleID {
                groups[g].apps[a].keepOpen = value
            }
        }
        config.groups = groups
        if value { HideWatcher.shared.ensureKeptOpen() }
    }

    /// Sets "Remove from Dock" for every item pointing to this app (it can be in several groups).
    func setRemoveFromDock(_ value: Bool, bundleID: String) {
        var groups = config.groups
        var changed = false
        for g in groups.indices {
            for a in groups[g].apps.indices where groups[g].apps[a].bundleID == bundleID && groups[g].apps[a].removeFromDock != value {
                groups[g].apps[a].removeFromDock = value
                changed = true
            }
        }
        if changed { config.groups = groups }
    }

    /// Records that an app moved into (or out of) Stack's folder, for every item pointing to it.
    func setInStack(_ value: Bool, key: String, path: String, originalPath: String?) {
        var groups = config.groups
        var changed = false
        for g in groups.indices {
            for a in groups[g].apps.indices where groups[g].apps[a].key == key {
                groups[g].apps[a].inStack = value
                groups[g].apps[a].path = path
                groups[g].apps[a].originalPath = originalPath
                changed = true
            }
        }
        if changed { config.groups = groups }
    }

    /// Points an item to a new location (app moved or reinstalled elsewhere).
    func relocate(_ appID: UUID, in groupID: UUID, to url: URL) {
        guard let g = groupIndex(groupID),
              let a = config.groups[g].apps.firstIndex(where: { $0.id == appID }),
              var fresh = AppItem.make(from: url) else { return }
        fresh.id = appID
        fresh.mode = config.groups[g].apps[a].mode
        fresh.removeFromDock = config.groups[g].apps[a].removeFromDock
        fresh.keepOpen = config.groups[g].apps[a].keepOpen
        config.groups[g].apps[a] = fresh
    }
}
