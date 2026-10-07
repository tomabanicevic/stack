import SwiftUI

// Note: the Xcode Command Line Tools don't ship SwiftUI's macro plugin, and in recent SDKs
// `@State` is a macro. To build without full Xcode, all view state lives in these
// ObservableObjects (injected with `.environmentObject`) instead of `@State`.

/// Ephemeral state of the Settings window.
@MainActor
final class SettingsUIState: ObservableObject {
    @Published var selection: SidebarItem?
    @Published var pendingDelete: AppGroup?
    @Published var showStyle = false
    @Published var dropTargeted = false
    @Published var showPicker = false
    @Published private(set) var picker: PickerModel?

    func openPicker(for groupID: UUID) {
        picker = PickerModel(groupID: groupID)
        showPicker = true
    }

    func select(_ item: SidebarItem?) {
        showStyle = false
        selection = item
    }
}

/// State of the "Add apps" sheet.
@MainActor
final class PickerModel: ObservableObject {
    let groupID: UUID
    @Published var apps: [InstalledApp] = []
    @Published var loading = true
    @Published var query = ""
    @Published var selected: Set<String> = []
    @Published var showSystem = false

    init(groupID: UUID) {
        self.groupID = groupID
        Task { await load() }
    }

    func load() async {
        let result = await Task.detached(priority: .userInitiated) { InstalledApps.scan() }.value
        apps = result
        loading = false
    }

    func toggle(_ app: InstalledApp) {
        if selected.contains(app.id) {
            selected.remove(app.id)
        } else {
            selected.insert(app.id)
        }
    }

    var filtered: [InstalledApp] {
        apps.filter { app in
            (showSystem || !app.isSystem)
                && (query.isEmpty || app.name.localizedCaseInsensitiveContains(query))
        }
    }

    var selectedURLs: [URL] { apps.filter { selected.contains($0.id) }.map(\.url) }
}
