import AppKit
import Carbon.HIToolbox

/// Writes an item to the pasteboard and, when permitted, synthesises Cmd+V into
/// whatever app was frontmost. This is the product's core function; a failure to
/// land text in the target app is a P0 defect, not a degraded mode (PST-2).
final class Paster {

    private let prefs: Preferences

    /// Called just before each pasteboard write, with the resulting change count,
    /// so the monitor can skip our own writes (CAP-7).
    var onWillWrite: ((Int) -> Void)?

    /// Reusable HID event source. `.hidSystemState` behaves consistently across
    /// apps where a private source can be dropped.
    private let eventSource = CGEventSource(stateID: .hidSystemState)

    init(prefs: Preferences) {
        self.prefs = prefs
    }

    enum PasteMode {
        case pasteInPlace     // write + synthesise Cmd+V (default)
        case pasteAsPlainText // same, but strips attributed formatting
        case copyOnly         // write to pasteboard, no synthesised paste (PST-7)
    }

    /// Result of a paste attempt, so the caller can surface Secure Input notices.
    enum Outcome {
        case pasted
        case copiedOnly
        case blockedBySecureInput(process: String?)
        case notTrusted
    }

    /// Perform the full paste sequence for a text payload. `previousApp` is the
    /// app that was frontmost when the picker opened, to be re-activated.
    @discardableResult
    func paste(text: String, previousApp: NSRunningApplication?, mode: PasteMode) -> Outcome {
        // 1. Snapshot the user's current pasteboard so we can restore it (PST-5).
        let snapshot = prefs.restorePasteboard ? snapshotPasteboard() : nil

        // 2. Write our payload and tell the monitor to ignore this change.
        let changeCount = writeToPasteboard(text: text)
        onWillWrite?(changeCount)

        if mode == .copyOnly {
            return .copiedOnly
        }

        // 3. Re-activate the previous app if it lost frontmost status. With the
        //    nonactivating panel this is usually a no-op, but it covers Spaces
        //    switches and the source app having been re-ordered.
        if let previousApp, !previousApp.isActive {
            previousApp.activate()
        }

        // 4. Accessibility gate. Without it, synthetic events are silently
        //    dropped, so don't even try — report it so the UI can explain.
        guard Permissions.isAccessibilityTrusted else {
            restoreIfNeeded(snapshot)
            return .notTrusted
        }

        // 5. Secure Input blocks synthetic key events system-wide. Detect it and
        //    surface a notice rather than failing silently (SEC-1/SEC-2) — the
        //    single worst outcome this app can have.
        if IsSecureEventInputEnabled() {
            let holder = SecureInput.holdingProcessName()
            restoreIfNeeded(snapshot)
            return .blockedBySecureInput(process: holder)
        }

        // 6. Synthesise Cmd+V. A short delay lets the panel finish hiding and the
        //    target app settle — some Electron apps drop the very first paste
        //    otherwise.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            self?.postCommandV()
            self?.restoreIfNeeded(snapshot)
        }

        return .pasted
    }

    // MARK: Pasteboard I/O

    private func writeToPasteboard(text: String) -> Int {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        return pb.changeCount
    }

    private func snapshotPasteboard() -> [NSPasteboardItem] {
        let pb = NSPasteboard.general
        return (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    private func restoreIfNeeded(_ snapshot: [NSPasteboardItem]?) {
        guard let snapshot, !snapshot.isEmpty else { return }
        // Restore on a delay so the target app has read our payload first (PST-5).
        DispatchQueue.main.asyncAfter(deadline: .now() + prefs.restoreDelay) { [weak self] in
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects(snapshot)
            self?.onWillWrite?(pb.changeCount)
        }
    }

    // MARK: Synthetic keystroke

    private func postCommandV() {
        let vKey = CGKeyCode(kVK_ANSI_V)
        guard
            let down = CGEvent(keyboardEventSource: eventSource, virtualKey: vKey, keyDown: true),
            let up = CGEvent(keyboardEventSource: eventSource, virtualKey: vKey, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
