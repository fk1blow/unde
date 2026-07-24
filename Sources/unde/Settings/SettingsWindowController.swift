import AppKit
import SwiftUI

/// Hosts the settings window. A single shared controller so the window is reused
/// rather than re-created. Settings is an ordinary activating window (unlike the
/// picker) — the user is deliberately configuring the app here.
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show(prefs: Preferences, onHotKeyChange: @escaping (KeyCombo) -> Void) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let root = SettingsView(prefs: prefs, onHotKeyChange: onHotKeyChange)
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = "unde Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
