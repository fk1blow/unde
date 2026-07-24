import AppKit
import ApplicationServices

/// Accessibility permission handling. This is the one hard permission the app
/// needs: synthesising Cmd+V requires the process to be trusted. Capture, the
/// hotkey, the picker and clipboard-writing all work without it.
enum Permissions {

    /// Whether the process is currently trusted for Accessibility.
    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Ask for Accessibility once, at first run. Subsequent launches don't nag —
    /// the persistent banner in the picker surfaces the still-denied state.
    static func requestAccessibilityIfNeeded(prefs: Preferences) {
        guard !prefs.didRequestAccessibility else { return }
        prefs.didRequestAccessibility = true
        promptForAccessibility()
    }

    /// Trigger the system prompt that offers to open the Privacy pane.
    static func promptForAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Deep-link straight to the Accessibility list in System Settings.
    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
