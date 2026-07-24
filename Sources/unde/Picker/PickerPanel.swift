import AppKit

/// The borderless, non-activating panel the picker lives in. Non-activating is
/// the whole trick: showing it never steals key/main from the app the user is
/// working in, so there is no activate/reactivate race to sequence around.
///
/// A borderless panel returns false from `canBecomeKey` by default, which would
/// send keystrokes nowhere — so we override it.
final class PickerPanel: NSPanel {

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        level = .floating
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        isFloatingPanel = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
