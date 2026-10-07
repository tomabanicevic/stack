import AppKit
import SwiftUI

/// Borderless panel that never steals focus from the app you're using.
final class BubblePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Lets buttons react to the very first click, even though the panel isn't active.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The little bubble shown at the top of the screen for a few seconds after Stack opens your apps.
@MainActor
final class BubbleController {
    var onSettings: (() -> Void)?
    var onQuitAll: (() -> Void)?
    var onClosed: (() -> Void)?

    private let session: LaunchSession
    private var panel: BubblePanel?
    private var hovering = false
    private var canDismiss = false
    private var closed = false
    private var dismissTask: Task<Void, Never>?

    init(session: LaunchSession) {
        self.session = session
    }

    func show() {
        let root = BubbleView(
            onSettings: { [weak self] in self?.onSettings?() },
            onQuitAll: { [weak self] in self?.onQuitAll?() },
            onHover: { [weak self] hovering in self?.setHovering(hovering) }
        )
        let hosting = FirstMouseHostingView(rootView: root.environmentObject(session))
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)

        let panel = BubblePanel(contentRect: NSRect(origin: .zero, size: size),
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = hosting

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 10))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
        self.panel = panel

        // Safety net: never stay on screen forever.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            self?.launchesFinished()
        }
    }

    /// Called when every app has been launched: the bubble fades out shortly after.
    func launchesFinished() {
        guard !canDismiss else { return }
        canDismiss = true
        if !hovering { scheduleDismiss(after: 2.4) }
    }

    func close(animated: Bool = true) {
        guard !closed else { return }
        closed = true
        dismissTask?.cancel()
        guard let panel else {
            onClosed?()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? 0.22 : 0
            panel.animator().alphaValue = 0
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: animated ? 240_000_000 : 0)
            panel.orderOut(nil)
            self?.panel = nil
            self?.onClosed?()
        }
    }

    private func setHovering(_ value: Bool) {
        hovering = value
        if value {
            dismissTask?.cancel()
        } else if canDismiss {
            scheduleDismiss(after: 1.2)
        }
    }

    private func scheduleDismiss(after seconds: Double) {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if Task.isCancelled { return }
            self?.close()
        }
    }
}

// MARK: - Bubble view

struct BubbleView: View {
    @EnvironmentObject private var session: LaunchSession
    var onSettings: @MainActor () -> Void
    var onQuitAll: @MainActor () -> Void
    var onHover: @MainActor (Bool) -> Void

    private let maxIcons = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: "Stack")
                        .font(.system(size: 13, weight: .semibold))
                    Text(statusLine)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 10)
                Button(action: { onSettings() }) {
                    Label("Settings", systemImage: "gearshape.fill")
                }
                .buttonStyle(PillButtonStyle())
                Button(action: { onQuitAll() }) {
                    Label("Quit all", systemImage: "power")
                }
                .buttonStyle(PillButtonStyle(foreground: Color(red: 1, green: 0.45, blue: 0.45), fill: .red))
            }
            if !session.entries.isEmpty {
                HStack(spacing: 9) {
                    ForEach(session.entries.prefix(maxIcons)) { entry in
                        BubbleAppIcon(entry: entry)
                    }
                    if session.entries.count > maxIcons {
                        Text(verbatim: "+\(session.entries.count - maxIcons)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 440)
        .background(VisualEffectBackground(material: .hudWindow))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .environment(\.colorScheme, .dark)
        .onHover { onHover($0) }
    }

    private var statusLine: String {
        let entries = session.entries
        if entries.isEmpty { return String(localized: "Nothing to open") }
        if !session.launchesDone { return String(localized: "Opening \(entries.count) apps…") }
        let opened = session.openedCount
        let already = session.alreadyRunningCount
        let problems = session.problemCount
        if opened == 0 && problems == 0 { return String(localized: "Everything is already open") }
        var parts: [String] = []
        if opened > 0 { parts.append(String(localized: "\(opened) opened")) }
        if already > 0 { parts.append(String(localized: "\(already) already open")) }
        if problems > 0 { parts.append(String(localized: "\(problems) not found")) }
        return parts.joined(separator: " · ")
    }
}

struct BubbleAppIcon: View {
    let entry: LaunchSession.Entry

    private var isWaiting: Bool { entry.state == .pending || entry.state == .launching }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            AppIconImage(url: Launcher.resolveURL(entry.item), size: 30)
                .opacity(isWaiting ? 0.4 : 1)
                .overlay {
                    if isWaiting {
                        ProgressView().controlSize(.small).scaleEffect(0.6)
                    }
                }
            badge
        }
        .frame(width: 32, height: 32)
        .animation(.easeOut(duration: 0.2), value: entry.state)
    }

    @ViewBuilder private var badge: some View {
        switch entry.state {
        case .launched:
            if entry.item.mode.startsHidden {
                badgeIcon("eye.slash.fill", .purple)
            } else {
                badgeIcon("checkmark", .green)
            }
        case .alreadyRunning:
            badgeIcon("checkmark", .gray)
        case .missing, .failed:
            badgeIcon("exclamationmark", .red)
        case .pending, .launching:
            EmptyView()
        }
    }

    private func badgeIcon(_ symbol: String, _ color: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 7, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: 13, height: 13)
            .background(Circle().fill(color))
            .overlay(Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 1))
            .offset(x: 3, y: 3)
    }
}
