import AppKit
import SwiftUI

/// Sheet listing the apps installed on the Mac, with search and multi-selection.
struct AppPicker: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var model: PickerModel
    @Environment(\.dismiss) private var dismiss

    private var groupName: String { store.group(model.groupID)?.name ?? "" }

    private var existingKeys: Set<String> {
        Set((store.group(model.groupID)?.apps ?? []).map(\.key))
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Add apps to “\(groupName)”")
                    .font(.headline)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search", text: $model.query)
                        .textFieldStyle(.plain)
                    if !model.query.isEmpty {
                        Button {
                            model.query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
            }
            .padding(16)

            Divider()

            if model.loading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.filtered.isEmpty {
                Text("No app found")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let existing = existingKeys
                List(model.filtered) { app in
                    let added = existing.contains(app.bundleID ?? app.url.path)
                    Button {
                        model.toggle(app)
                    } label: {
                        PickerRow(app: app, selected: model.selected.contains(app.id), alreadyAdded: added)
                    }
                    .buttonStyle(.plain)
                    .disabled(added)
                }
                .listStyle(.inset)
            }

            Divider()

            HStack(spacing: 10) {
                Toggle("Show system apps", isOn: $model.showSystem)
                    .toggleStyle(.checkbox)
                Button("Browse…") { browse() }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    store.add(urls: model.selectedURLs, to: model.groupID)
                    dismiss()
                } label: {
                    if model.selected.isEmpty {
                        Text("Add")
                    } else {
                        Text("Add \(model.selected.count)")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.selected.isEmpty)
            }
            .padding(14)
        }
        .frame(width: 500, height: 580)
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = String(localized: "Add")
        if panel.runModal() == .OK {
            store.add(urls: panel.urls, to: model.groupID)
            dismiss()
        }
    }
}

struct PickerRow: View {
    let app: InstalledApp
    let selected: Bool
    let alreadyAdded: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: selected || alreadyAdded ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 17))
                .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(alreadyAdded ? 0.8 : 0.5))
            AppIconImage(url: app.url, size: 28)
            Text(app.name)
                .lineLimit(1)
            Spacer()
            if alreadyAdded {
                Text("Already added")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .opacity(alreadyAdded ? 0.55 : 1)
    }
}
