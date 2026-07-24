import AppKit
import Carbon.HIToolbox

/// Helpers around macOS Secure Input. When any process enables Secure Keyboard
/// Entry (Terminal.app and iTerm2 both offer it, and any focused password field
/// triggers it automatically), synthetic key events are blocked system-wide.
/// Since terminals are the primary paste target, this is a normal-use condition,
/// not an edge case.
enum SecureInput {

    /// Whether Secure Input is currently active.
    static var isEnabled: Bool {
        IsSecureEventInputEnabled()
    }

    /// Best-effort name of the process holding Secure Input, so a notice can name
    /// it (SEC-3). The public APIs don't expose the holder directly, so this
    /// heuristically checks the known terminals that expose the toggle; if none
    /// match, returns nil and the caller shows the unnamed notice.
    static func holdingProcessName() -> String? {
        let suspects = ["com.apple.Terminal", "com.googlecode.iterm2"]
        let running = NSWorkspace.shared.runningApplications
        // The frontmost suspect is the most likely holder.
        if let front = NSWorkspace.shared.frontmostApplication,
           let bid = front.bundleIdentifier,
           suspects.contains(bid) {
            return front.localizedName
        }
        for app in running where suspects.contains(app.bundleIdentifier ?? "") {
            return app.localizedName
        }
        return nil
    }
}
