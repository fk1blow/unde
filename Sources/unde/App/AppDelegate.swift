import AppKit

/// Wires the app together and owns the long-lived objects. Everything that must
/// survive for the process lifetime is constructed here, once, at launch —
/// nothing user-facing is built lazily (see the performance budgets in the PRD).
final class AppDelegate: NSObject, NSApplicationDelegate {

    let prefs = Preferences()
    private(set) var database: SQLiteDatabase?
    private(set) var imageStore: ImageStore!
    private(set) var historyRepo: HistoryRepository?
    private(set) var snippetStore: SnippetStore!
    private(set) var history: HistoryStore!
    private(set) var monitor: PasteboardMonitor!
    private(set) var paster: Paster!
    private(set) var picker: PickerController!
    private(set) var menu: MenuBarController!
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Storage layer: single SQLite file + content-addressed image files, both
        // under Application Support. If the DB can't be opened the app still runs,
        // just without persistence — history falls back to in-memory only.
        imageStore = ImageStore()
        if let dbURL = Self.databaseURL() {
            database = try? SQLiteDatabase(path: dbURL.path)
        }
        if let database {
            historyRepo = HistoryRepository(db: database, imageStore: imageStore)
        }

        // Data layer.
        snippetStore = SnippetStore()
        history = HistoryStore(capacity: prefs.historyCapacity, repository: historyRepo)
        // Age-based retention: the store asks prefs for the current cutoff on every
        // prune. Run one pass now, after the warm-load, so a stale item is gone at
        // launch and not only after the next copy (RET-5).
        history.retentionCutoff = { [prefs] in prefs.retentionCutoff() }
        history.evictExpired()

        // Paste engine + capture. The paster tells the monitor which pasteboard
        // change counts it caused, so we never re-capture our own writes (CAP-7).
        paster = Paster(prefs: prefs)
        monitor = PasteboardMonitor(prefs: prefs, history: history, imageStore: imageStore)
        paster.onWillWrite = { [weak monitor] changeCount in
            monitor?.suppress(changeCount: changeCount)
        }

        // The picker panel and its whole view hierarchy are built now and only
        // ever hidden/shown afterwards — never reconstructed (perf budget).
        picker = PickerController(history: history, snippets: snippetStore, paster: paster, prefs: prefs, imageStore: imageStore)

        // Menu bar item — the only persistent UI.
        menu = MenuBarController(prefs: prefs, monitor: monitor, paster: paster) { [weak self] in
            self?.openSettings()
        }

        // Global hotkey. Carbon-based, so it needs no permissions (INV-1/INV-2).
        registerHotKey()

        // Start watching the pasteboard.
        monitor.start()

        // Accessibility is the only hard permission; the actual paste needs it.
        // Ask once, at first run, rather than on first failed paste.
        Permissions.requestAccessibilityIfNeeded(prefs: prefs)

        // Reflect Secure Input state in the menu bar as it changes (SEC-5).
        menu.beginSecureInputMonitoring()
    }

    private func registerHotKey() {
        hotKey = HotKey(keyCombo: prefs.hotKeyCombo) { [weak self] in
            self?.picker.toggle()
        }
    }

    /// Re-register the hotkey after the user changes it in settings.
    func updateHotKey(_ combo: KeyCombo) {
        prefs.hotKeyCombo = combo
        hotKey = HotKey(keyCombo: combo) { [weak self] in
            self?.picker.toggle()
        }
    }

    private static func databaseURL() -> URL? {
        guard let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = support.appendingPathComponent("unde", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("unde.sqlite")
    }

    /// Persist a new retention window and prune immediately, so shortening it
    /// applies at once (RET-9). Setting "Forever" (0) just stops future eviction.
    func updateRetention(_ days: Int) {
        prefs.retentionDays = days
        history.evictExpired()
    }

    private func openSettings() {
        SettingsWindowController.shared.show(
            prefs: prefs,
            onHotKeyChange: { [weak self] combo in self?.updateHotKey(combo) },
            onRetentionChange: { [weak self] days in self?.updateRetention(days) }
        )
    }
}
