import ServiceManagement

/// Launch-at-login via the modern `SMAppService` API (macOS 13+). Registers the
/// main app as a login item; no helper bundle required.
enum LaunchAtLogin {
    static func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("unde: launch-at-login change failed: \(error)")
        }
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
}
