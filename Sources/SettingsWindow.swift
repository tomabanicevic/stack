import AppKit
import SwiftUI

// MARK: - Window controller

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    init(store: Store) {
        let root = SettingsView()
            .environmentObject(store)
            .environmentObject(RunningApps.shared)
            .environmentObject(LoginItem.shared)
            .environmentObject(SettingsUIState())
            .environmentObject(HideWatcher.shared)
            .environmentObject(DockRemoval.shared)
            .environmentObject(VaultController.shared)
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = [.minSize]

        let window = NSWindow(contentViewController: hosting)
        window.title = "Stack"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 880, height: 590))
        window.center()
        window.setFrameAutosaveName("StackSettingsWindow")
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

// MARK: - Root view

enum SidebarItem: Hashable {
    case group(UUID)
    case general
}

struct SettingsView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var ui: SettingsUIState

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 210, ideal: 232, max: 320)
        } detail: {
            detail
        }
        .frame(minWidth: 860, minHeight: 500)
        .onAppear {
            if ui.selection == nil {
                ui.select(store.config.groups.first.map { SidebarItem.group($0.id) } ?? .general)
            }
        }
    }

    @ViewBuilder private var detail: some View {
        switch ui.selection {
        case .group(let id) where store.groupIndex(id) != nil:
            GroupDetail(groupID: id).id(id)
        case .general:
            GeneralSettings()
        default:
            NoSelectionView()
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var ui: SettingsUIState

    var body: some View {
        List(selection: $ui.selection) {
            Section("Groups") {
                ForEach(store.config.groups) { group in
                    GroupRow(group: group)
                        .tag(SidebarItem.group(group.id))
                        .contextMenu { contextMenu(for: group) }
                }
                .onMove { store.moveGroups(from: $0, to: $1) }

                Button {
                    ui.select(.group(store.addGroup()))
                } label: {
                    Label("New group", systemImage: "plus")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.vertical, 2)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .confirmationDialog(
            Text("Delete this group?"),
            isPresented: Binding(get: { ui.pendingDelete != nil }, set: { if !$0 { ui.pendingDelete = nil } }),
            presenting: ui.pendingDelete
        ) { group in
            Button("Delete", role: .destructive) {
                store.deleteGroup(group.id)
                if ui.selection == .group(group.id) {
                    ui.select(store.config.groups.first.map { SidebarItem.group($0.id) } ?? .general)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Your apps stay installed. Only the group is removed from Stack, and apps kept inside Stack go back to Applications.")
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 4) {
                Button {
                    ui.select(.general)
                } label: {
                    Label("Settings", systemImage: "gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(SidebarButtonStyle(selected: ui.selection == .general))

                Button {
                    Launcher.quit(store.allItems)
                } label: {
                    Label("Quit all", systemImage: "power")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(.secondary)
                .help("Quits every app of all your groups")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder private func contextMenu(for group: AppGroup) -> some View {
        Button {
            Launcher.launchNow(group.apps)
        } label: {
            Label("Open group", systemImage: "play")
        }
        Button {
            Launcher.quit(group.apps)
        } label: {
            Label("Quit group", systemImage: "stop")
        }
        Divider()
        if group.openOnLaunch {
            Button {
                store.toggleOpenOnLaunch(group.id)
            } label: {
                Label("Don't open on click", systemImage: "bolt.slash")
            }
        } else {
            Button {
                store.toggleOpenOnLaunch(group.id)
            } label: {
                Label("Open on click", systemImage: "bolt")
            }
        }
        Divider()
        Button(role: .destructive) {
            ui.pendingDelete = group
        } label: {
            Label("Delete group…", systemImage: "trash")
        }
    }
}

struct GroupRow: View {
    let group: AppGroup

    var body: some View {
        HStack(spacing: 9) {
            GroupBadge(symbol: group.symbol, color: group.color.color, size: 22)
            Text(group.name.isEmpty ? " " : group.name)
                .lineLimit(1)
            Spacer(minLength: 4)
            if group.openOnLaunch {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.yellow)
                    .help("Opens when you click Stack")
            }
            Text(verbatim: "\(group.apps.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct NoSelectionView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var ui: SettingsUIState

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary)
            Text("No group selected")
                .font(.title3.weight(.semibold))
            Button {
                ui.select(.group(store.addGroup()))
            } label: {
                Label("Create a group", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
