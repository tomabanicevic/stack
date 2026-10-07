import AppKit
import SwiftUI

/// Flow:
/// • Click Stack → opens every app of the "open on click" groups, shows a small bubble, then quits.
/// • Hold ⌥ Option while opening Stack (or click "Settings" in the bubble) → Settings window.
/// • First launch (no apps yet) → Settings window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = Store.shared
    private var settingsController: SettingsWindowController?
    private var bubble: BubbleController?
    private let statusBar = StatusBarController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        _ = RunningApps.shared
        LaunchSession.onAllIdle = { [weak self] in self?.terminateIfIdle() }
        HideWatcher.shared.update(from: store.config)
        statusBar.onOpenGroups = { [weak self] in self?.runLaunchFlow() }
        statusBar.onSettings = { [weak self] in self?.showSettings() }
        statusBar.onQuitAll = { [weak self] in
            guard let self else { return }
            Launcher.quit(self.store.allItems)
        }
        statusBar.start()
        HideWatcher.shared.ensureKeptOpen()

        let askedForSettings = CommandLine.arguments.contains("--settings")
        if askedForSettings { showSettings() } else { handleOpen() }
    }

    /// Clicking Stack while it's already running (e.g. in the background to keep an app hidden).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if settingsController != nil || bubble != nil {
            showSettings()
        } else {
            handleOpen()
        }
        return false
    }

    /// A click on Stack: ⌥ → settings, otherwise open the groups.
    private func handleOpen() {
        if NSEvent.modifierFlags.contains(.option) || store.launchItems.isEmpty {
            showSettings()
        } else {
            runLaunchFlow()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }


    // MARK: Launch flow

    private func runLaunchFlow() {
        let items = store.launchItems
        let session = LaunchSession(items: items)

        if store.config.showBubble {
            let bubble = BubbleController(session: session)
            bubble.onSettings = { [weak self] in self?.showSettings() }
            bubble.onQuitAll = { [weak self] in
                Launcher.quit(items)
                self?.bubble?.close()
            }
            bubble.onClosed = { [weak self] in
                self?.bubble = nil
                self?.terminateIfIdle()
            }
            self.bubble = bubble
            bubble.show()
        }

        session.start(onLaunchesDone: { [weak self] in
            self?.bubble?.launchesFinished()
        })
    }

    private func terminateIfIdle() {
        guard settingsController == nil, bubble == nil, LaunchSession.activeCount == 0,
              !HideWatcher.shared.isActive else { return }
        NSApp.terminate(nil)
    }

    // MARK: Settings

    @objc func showSettings() {
        if settingsController == nil {
            let controller = SettingsWindowController(store: store)
            controller.onClose = { [weak self] in self?.settingsDidClose() }
            settingsController = controller
            // Don't start with the group name field selected.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 80_000_000)
                controller.window?.makeFirstResponder(nil)
            }
        }
        NSApp.setActivationPolicy(.regular)
        settingsController?.showWindow(nil)
        settingsController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
        bubble?.close()
    }

    private func settingsDidClose() {
        settingsController = nil
        NSApp.setActivationPolicy(.accessory)
        terminateIfIdle()
    }

    @objc private func openGroupsNow() {
        Launcher.launchNow(store.launchItems)
    }

    @objc private func quitAllApps() {
        Launcher.quit(store.allItems)
    }

    // MARK: Menu

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: String(localized: "About Stack"),
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: String(localized: "Settings…"),
                                       action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        let open = appMenu.addItem(withTitle: String(localized: "Open my groups"),
                                   action: #selector(openGroupsNow), keyEquivalent: "o")
        open.target = self
        let quitApps = appMenu.addItem(withTitle: String(localized: "Quit all apps"),
                                       action: #selector(quitAllApps), keyEquivalent: "")
        quitApps.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Hide Stack"),
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: String(localized: "Quit Stack"),
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: String(localized: "Edit"))
        editMenu.addItem(withTitle: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: String(localized: "Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: String(localized: "Window"))
        windowMenu.addItem(withTitle: String(localized: "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: String(localized: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }
}
