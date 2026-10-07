import AppKit

/// Entry point. Stack is an AppKit app (SwiftUI for the UI) so we fully control
/// the "open everything, then quit" flow.
@main
enum StackMain {
    @MainActor private static var delegate: AppDelegate?

    @MainActor
    static func main() {
        let app = NSApplication.shared
        let appDelegate = AppDelegate()
        delegate = appDelegate
        app.delegate = appDelegate
        app.run()
    }
}
