import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct GroupDetail: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var running: RunningApps
    @EnvironmentObject private var ui: SettingsUIState
    @EnvironmentObject private var login: LoginItem
    let groupID: UUID

    var body: some View {
        let group = store.groupBinding(groupID)
        let value = group.wrappedValue
        VStack(spacing: 0) {
            header(group)
            Divider()
            if value.apps.contains(where: { $0.mode.startsHidden }) && !login.isOn {
                loginHint
                Divider()
            }
            if value.apps.isEmpty {
                emptyState(tint: value.color.color)
            } else {
                appList(value)
            }
            Divider()
            footer
        }
        .overlay {
            if ui.dropTargeted { dropOverlay(color: value.color.color) }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $ui.dropTargeted) { providers in
            accept(providers)
        }
        .sheet(isPresented: $ui.showPicker) {
            if let picker = ui.picker {
                AppPicker()
                    .environmentObject(store)
                    .environmentObject(picker)
            }
        }
    }

    // MARK: Header

    private func header(_ group: Binding<AppGroup>) -> some View {
        let value = group.wrappedValue
        let runningCount = value.apps.filter { running.isRunning($0) }.count
        return HStack(spacing: 14) {
            Button {
                ui.showStyle.toggle()
            } label: {
                GroupBadge(symbol: value.symbol, color: value.color.color, size: 46)
            }
            .buttonStyle(.plain)
            .help("Change icon and color")
            .popover(isPresented: $ui.showStyle, arrowEdge: .bottom) {
                GroupStylePicker(binding: group)
            }

            VStack(alignment: .leading, spacing: 3) {
                TextField("Group name", text: group.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20, weight: .semibold))
                Text(subtitle(total: value.apps.count, running: runningCount))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Toggle("Open on click", isOn: group.openOnLaunch)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("When on, this group opens every time you click Stack.")

            Button {
                Launcher.launchNow(value.apps)
            } label: {
                Label("Open", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(value.color.color)
            .disabled(value.apps.isEmpty)
            .help("Open every app of this group now")

            Button {
                Launcher.quit(value.apps)
            } label: {
                Label("Quit", systemImage: "stop.fill")
            }
            .disabled(runningCount == 0)
            .help("Quit every app of this group")
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private func subtitle(total: Int, running: Int) -> String {
        if total == 0 { return String(localized: "Empty group") }
        let apps = total == 1 ? String(localized: "1 app") : String(localized: "\(total) apps")
        if running == 0 { return apps }
        return apps + " · " + String(localized: "\(running) running")
    }

    // MARK: List

    private func appList(_ group: AppGroup) -> some View {
        List {
            ForEach(group.apps) { item in
                AppRow(item: item, groupID: groupID)
            }
            .onMove { store.moveApps(in: groupID, from: $0, to: $1) }
        }
        .listStyle(.inset)
    }

    private func emptyState(tint: Color) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "plus.square.dashed")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(tint)
            Text("No apps yet")
                .font(.title3.weight(.semibold))
            Text("Drag apps here from the Finder, or pick them from the apps installed on your Mac.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 340)
            Button {
                ui.openPicker(for: groupID)
            } label: {
                Label("Add apps", systemImage: "plus")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(tint)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
        )
        .padding(22)
    }

    private var loginHint: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.purple)
            Text("Turn on “Open Stack at login” so hidden apps stay hidden after a restart.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Turn on") { login.set(true) }
                .controlSize(.small)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 9)
        .background(Color.purple.opacity(0.08))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                ui.openPicker(for: groupID)
            } label: {
                Label("Add apps…", systemImage: "plus")
            }
            Button {
                browse()
            } label: {
                Label("Browse…", systemImage: "folder")
            }
            Spacer()
            Text("Tip: drag apps from the Finder into this window.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func dropOverlay(color: Color) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(color, style: StrokeStyle(lineWidth: 2.5, dash: [8, 6]))
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(color.opacity(0.08)))
            .overlay(
                Label("Drop to add", systemImage: "plus.circle.fill")
                    .font(.headline)
                    .foregroundStyle(color)
            )
            .padding(10)
            .allowsHitTesting(false)
    }

    // MARK: Actions

    private func browse() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = String(localized: "Add")
        if panel.runModal() == .OK {
            store.add(urls: panel.urls, to: groupID)
        }
    }

    private func accept(_ providers: [NSItemProvider]) -> Bool {
        let store = self.store
        let groupID = self.groupID
        var accepted = false
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            accepted = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in store.add(urls: [url], to: groupID) }
            }
        }
        return accepted
    }
}

// MARK: - App row

struct AppRow: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var running: RunningApps
    @EnvironmentObject private var vault: VaultController
    let item: AppItem
    let groupID: UUID

    var body: some View {
        let url = Launcher.resolveURL(item)
        let isRunning = running.isRunning(item)
        HStack(spacing: 12) {
            AppIconImage(url: url, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                statusLine(found: url != nil, isRunning: isRunning)
            }
            Spacer(minLength: 8)
            if url == nil {
                Button("Locate…") { locate() }
                    .controlSize(.small)
            }
            if url != nil { optionToggles }
            modePicker
            Menu {
                menuItems(url: url, isRunning: isRunning)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 15))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .padding(.vertical, 5)
        .contextMenu { menuItems(url: url, isRunning: isRunning) }
    }

    @ViewBuilder private func statusLine(found: Bool, isRunning: Bool) -> some View {
        if !found {
            Label("Not found (moved or uninstalled)", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        } else {
            HStack(spacing: 5) {
                Circle()
                    .fill(isRunning ? Color.green : Color.secondary.opacity(0.35))
                    .frame(width: 7, height: 7)
                Text(isRunning ? LocalizedStringKey("Running") : LocalizedStringKey("Not running"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if item.inStack {
                    Label("Lives in Stack", systemImage: "shippingbox.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(.purple)
                }
            }
        }
    }

    /// Per-app options: "Keep open", "Out of Dock" and "In Stack".
    private var optionToggles: some View {
        HStack(spacing: 6) {
            Toggle(isOn: Binding(
                get: { item.keepOpen },
                set: { value in if let id = item.bundleID { store.setKeepOpen(value, bundleID: id) } }
            )) {
                Label("Keep open", systemImage: "pin.fill")
            }
            .help("Keep open: if this app closes, Stack reopens it (unless you quit it from Stack).")

            if let url = Launcher.resolveURL(item), !DockPatcher.nativelyHidden(url) {
            Toggle(isOn: Binding(
                get: { item.removeFromDock },
                set: { value in DockRemoval.shared.setOutOfDock(value, for: item) }
            )) {
                Label("Out of Dock", systemImage: "dock.arrow.down.rectangle")
            }
            .help("Out of Dock: no icon at the bottom, the app stays reachable from the menu bar.")
            }

            if vault.busy.contains(item.key) {
                ProgressView().controlSize(.small)
            } else {
                Toggle(isOn: Binding(
                    get: { item.inStack },
                    set: { value in vault.setInStack(value, for: item) }
                )) {
                    Label("In Stack", systemImage: "shippingbox.fill")
                }
                .help("In Stack: the app leaves Applications and lives inside Stack. Turn off to put it back.")
            }
        }
        .toggleStyle(.button)
        .controlSize(.small)
        .labelStyle(.titleAndIcon)
        .font(.caption)
    }

    private var modePicker: some View {
        Picker(selection: Binding(
            get: { item.mode },
            set: { store.setMode($0, for: item.id, in: groupID) }
        )) {
            ForEach(LaunchMode.allCases) { mode in
                Label(mode.title, systemImage: mode.symbol).tag(mode)
            }
        } label: {
            EmptyView()
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
        .help(Text(item.mode.detail))
    }

    @ViewBuilder private func menuItems(url: URL?, isRunning: Bool) -> some View {
        Button {
            Launcher.launchNow([item])
        } label: {
            Label("Open now", systemImage: "play")
        }
        .disabled(url == nil)
        Button {
            Launcher.quit([item])
        } label: {
            Label("Quit", systemImage: "stop")
        }
        .disabled(!isRunning)
        Divider()
        Button {
            if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        } label: {
            Label("Show in Finder", systemImage: "folder")
        }
        .disabled(url == nil)
        Button {
            locate()
        } label: {
            Label("Locate…", systemImage: "magnifyingglass")
        }
        Menu {
            ForEach(PrivacyPane.allCases) { pane in
                Button {
                    pane.open()
                } label: {
                    Label(pane.title, systemImage: pane.symbol)
                }
            }
        } label: {
            Label("Permissions", systemImage: "lock.shield")
        }
        Divider()
        Button(role: .destructive) {
            store.removeApp(item.id, from: groupID)
        } label: {
            Label("Remove from group", systemImage: "trash")
        }
    }

    private func locate() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Where is \(item.name)?")
        if panel.runModal() == .OK, let url = panel.url {
            store.relocate(item.id, in: groupID, to: url)
        }
    }
}
