import AppKit

/// The borderless, non-activating panel the picker lives in. Non-activating is
/// the whole trick: showing it never steals key/main from the app the user is
/// working in, so there is no activate/reactivate race to sequence around.
///
/// A borderless panel returns false from `canBecomeKey` by default, which would
/// send keystrokes nowhere — so we override it.
final class PickerPanel: NSPanel {

    /// Whether this panel accepts key status. The main picker panel must (it
    /// handles keystrokes); the detached preview panel must not, so ordering it in
    /// never steals key from the main panel and dismisses it.
    private let acceptsKey: Bool

    init(acceptsKey: Bool = true) {
        self.acceptsKey = acceptsKey
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

    override var canBecomeKey: Bool { acceptsKey }
    override var canBecomeMain: Bool { false }
}
