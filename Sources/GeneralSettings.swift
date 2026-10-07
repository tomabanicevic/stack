import AppKit
import SwiftUI

struct GeneralSettings: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var login: LoginItem
    @EnvironmentObject private var watcher: HideWatcher
    @EnvironmentObject private var dock: DockRemoval
    @EnvironmentObject private var vault: VaultController

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $store.config.showBubble) {
                    Text("Show the bubble after opening")
                    Text("A small panel with Settings and Quit all, for a few seconds.")
                }
                LabeledContent {
                    Text("⌥ + click")
                        .font(.system(.body, design: .rounded).weight(.medium))
                        .foregroundStyle(.secondary)
                } label: {
                    Text("Open these settings")
                    Text("Hold the Option key (⌥) while opening Stack.")
                }
            } header: {
                Text("When you click Stack")
            }

            Section {
                let candidates = DockRemoval.candidates(store.config)
                let outCount = candidates.filter { $0.removed }.count
                LabeledContent {
                    if dock.working {
                        ProgressView().controlSize(.small)
                    } else {
                        HStack(spacing: 8) {
                            Button("Put all back") { dock.disableAll() }
                                .disabled(outCount == 0)
                            Button("Remove all from Dock") { dock.enableAll() }
                                .buttonStyle(.borderedProminent)
                                .tint(.purple)
                                .disabled(outCount == candidates.count)
                        }
                    }
                } label: {
                    Text("Keep my apps out of the Dock")
                    if candidates.isEmpty {
                        Text("Nothing to do: your apps are already menu bar apps, or have to stay in the Dock.")
                    } else {
                        Text("\(outCount) of \(candidates.count) apps are out of the Dock. You reach them from Stack's menu bar icon (works with Ice).")
                    }
                }
            } header: {
                Text("Dock")
            }

            Section {
                let kept = store.inStackItems
                LabeledContent {
                    if !vault.busy.isEmpty {
                        ProgressView().controlSize(.small)
                    } else {
                        HStack(spacing: 8) {
                            Button("Show the folder") {
                                try? FileManager.default.createDirectory(at: AppVault.directory, withIntermediateDirectories: true)
                                NSWorkspace.shared.open(AppVault.directory)
                            }
                            Button("Put all back in Applications") { vault.putBack(kept) }
                                .disabled(kept.isEmpty)
                        }
                    }
                } label: {
                    Text("Keep apps inside Stack")
                    if kept.isEmpty {
                        Text("Turn on “In Stack” next to an app: it leaves Applications and Launchpad, and Stack opens it for you.")
                    } else {
                        Text("Apps living in Stack: \(kept.count). They are gone from Applications and Launchpad, and Stack opens them for you.")
                    }
                }
            } header: {
                Text("Inside Stack")
            }

            Section {
                Toggle(isOn: Binding(get: { login.isOn }, set: { login.set($0) })) {
                    Text("Open Stack at login")
                    Text("Your “open on click” groups open automatically when you log in.")
                }
                if login.needsApproval {
                    HStack {
                        Label("Needs your approval in System Settings", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Open Login Items") { login.openSystemSettings() }
                    }
                }
                if let error = login.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Startup")
            }

            if !watcher.apps.isEmpty {
                Section {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "eye.slash.fill")
                            .foregroundStyle(.purple)
                        Text(String(localized: "Stack stays in the menu bar to look after \(watcher.names)."))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Quit Stack") { NSApp.terminate(nil) }
                    }
                } header: {
                    Text("Background")
                }
            }

            Section {
                Text("macOS gives each permission to one app at a time: no app can pass its access on to the others. These shortcuts take you straight to the right place when an app asks again.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(PrivacyPane.allCases) { pane in
                    Button {
                        pane.open()
                    } label: {
                        HStack {
                            Label(pane.title, systemImage: pane.symbol)
                            Spacer()
                            Image(systemName: "arrow.up.forward.app")
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Permissions")
            }

            Section {
                LabeledContent("Version") {
                    Text(verbatim: version)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Stack itself") {
                    Text("Needs no special permission")
                        .foregroundStyle(.secondary)
                }
                Text("If you ever delete Stack, put your apps back in Applications first.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Show the settings file in the Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([store.fileURL])
                }
            } header: {
                Text("About")
            }
        }
        .formStyle(.grouped)
        .onAppear { login.refresh() }
    }
}
