import AppKit

// unde — a native macOS clipboard & snippet manager.
// Entry point: construct NSApplication manually (no storyboard, no @main),
// run as an accessory app so there is no Dock icon — the menu bar item is the
// only persistent UI (CHR-1).

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
