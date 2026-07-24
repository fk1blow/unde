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
            button.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "unde")
            button.image?.isTemplate = true
        }
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
        } else if prefs.paused {
            button.image = NSImage(systemSymbolName: "pause.circle", accessibilityDescription: "unde — paused")
        } else {
            button.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "unde")
        }
        button.image?.isTemplate = true
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
