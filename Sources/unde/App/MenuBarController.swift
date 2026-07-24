import AppKit

/// The menu bar item — the only persistent UI. Provides the pause toggle, a
/// route to settings, and quit, and reflects Secure Input state in its icon so
/// the user has a standing indication that synthetic paste is currently blocked
/// (SEC-5).
final class MenuBarController: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    private let prefs: Preferences
    private let monitor: PasteboardMonitor
    private let paster: Paster
    private let openSettings: () -> Void

    private var pauseItem: NSMenuItem!
    private var secureInputTimer: Timer?

    init(prefs: Preferences, monitor: PasteboardMonitor, paster: Paster, openSettings: @escaping () -> Void) {
        self.prefs = prefs
        self.monitor = monitor
        self.paster = paster
        self.openSettings = openSettings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configureButton()
        buildMenu()
    }

    private func configureButton() {
        if let button = statusItem.button {
            button.image = Self.brandIcon()
        }
    }

    /// The "unde" brand mark for the menu bar, as a template image the system
    /// tints to match the menu bar's light/dark appearance. Falls back to an SF
    /// Symbol if the bundled asset can't be loaded.
    private static func brandIcon() -> NSImage {
        if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url), image.size.height > 0 {
            // 17pt tall so the "u" matches the visual size of neighbouring
            // menu-bar glyphs (its letter body lines up; the serif just reads
            // slightly heavier).
            let height: CGFloat = 17
            image.size = NSSize(width: height * (image.size.width / image.size.height), height: height)
            image.isTemplate = true
            return image
        }
        let fallback = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "unde") ?? NSImage()
        fallback.isTemplate = true
        return fallback
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        pauseItem = NSMenuItem(title: "Pause Capture", action: #selector(togglePause), keyEquivalent: "")
        pauseItem.target = self
        menu.addItem(pauseItem)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit unde", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    /// Poll Secure Input state and mark the menu bar icon when it's active.
    func beginSecureInputMonitoring() {
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshSecureInputIndicator()
        }
        RunLoop.main.add(timer, forMode: .common)
        secureInputTimer = timer
        refreshSecureInputIndicator()
    }

    private func refreshSecureInputIndicator() {
        guard let button = statusItem.button else { return }
        if SecureInput.isEnabled {
            button.image = NSImage(systemSymbolName: "lock.doc", accessibilityDescription: "unde — Secure Input active")
            button.image?.isTemplate = true
        } else if prefs.paused {
            button.image = NSImage(systemSymbolName: "pause.circle", accessibilityDescription: "unde — paused")
            button.image?.isTemplate = true
        } else {
            button.image = Self.brandIcon()
        }
    }

    // MARK: Menu updates

    func menuNeedsUpdate(_ menu: NSMenu) {
        pauseItem.title = prefs.paused ? "Resume Capture" : "Pause Capture"
        pauseItem.state = prefs.paused ? .on : .off
    }

    // MARK: Actions

    @objc private func togglePause() {
        prefs.paused.toggle()
        refreshSecureInputIndicator()
    }

    @objc private func showSettings() {
        openSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
