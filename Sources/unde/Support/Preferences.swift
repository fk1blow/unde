import AppKit
import Carbon.HIToolbox

/// A key combination for the global hotkey: a virtual keycode plus Carbon
/// modifier flags (cmdKey, optionKey, …).
struct KeyCombo: Equatable, Codable {
    var keyCode: UInt32
    var modifiers: UInt32   // Carbon modifier mask

    static let defaultCombo = KeyCombo(
        keyCode: UInt32(kVK_ANSI_V),
        modifiers: UInt32(cmdKey | optionKey)
    )
}

/// Thin, typed wrapper over UserDefaults. Every persisted preference lives here
/// so there is exactly one place that touches the defaults domain.
final class Preferences {
    private let defaults = UserDefaults.standard

    private enum Key {
        static let historyCapacity = "historyCapacity"
        static let restorePasteboard = "restorePasteboard"
        static let restoreDelayMS = "restoreDelayMS"
        static let hotKey = "hotKeyCombo"
        static let didRequestAccessibility = "didRequestAccessibility"
        static let paused = "paused"
        static let excludedBundleIDs = "excludedBundleIDs"
        static let launchAtLogin = "launchAtLogin"
        static let skipSecrets = "skipSecrets"
    }

    init() {
        defaults.register(defaults: [
            Key.historyCapacity: 500,
            Key.restorePasteboard: true,
            Key.restoreDelayMS: 500,
            Key.paused: false,
            Key.excludedBundleIDs: [
                "com.apple.keychainaccess",
                "com.agilebits.onepassword7",
                "com.1password.1password",
                "com.bitwarden.desktop",
            ],
        ])
    }

    var historyCapacity: Int {
        get { max(100, min(2000, defaults.integer(forKey: Key.historyCapacity))) }
        set { defaults.set(newValue, forKey: Key.historyCapacity) }
    }

    var restorePasteboard: Bool {
        get { defaults.bool(forKey: Key.restorePasteboard) }
        set { defaults.set(newValue, forKey: Key.restorePasteboard) }
    }

    var restoreDelay: TimeInterval {
        get { Double(defaults.integer(forKey: Key.restoreDelayMS)) / 1000.0 }
        set { defaults.set(Int(newValue * 1000), forKey: Key.restoreDelayMS) }
    }

    var paused: Bool {
        get { defaults.bool(forKey: Key.paused) }
        set { defaults.set(newValue, forKey: Key.paused) }
    }

    var didRequestAccessibility: Bool {
        get { defaults.bool(forKey: Key.didRequestAccessibility) }
        set { defaults.set(newValue, forKey: Key.didRequestAccessibility) }
    }

    var launchAtLogin: Bool {
        get { defaults.bool(forKey: Key.launchAtLogin) }
        set { defaults.set(newValue, forKey: Key.launchAtLogin) }
    }

    /// Skip capturing strings that look like secrets (PRV-5). Off by default.
    var skipSecrets: Bool {
        get { defaults.bool(forKey: Key.skipSecrets) }
        set { defaults.set(newValue, forKey: Key.skipSecrets) }
    }

    var excludedBundleIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.excludedBundleIDs) ?? []) }
        set { defaults.set(Array(newValue), forKey: Key.excludedBundleIDs) }
    }

    var hotKeyCombo: KeyCombo {
        get {
            guard let data = defaults.data(forKey: Key.hotKey),
                  let combo = try? JSONDecoder().decode(KeyCombo.self, from: data)
            else { return .defaultCombo }
            return combo
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.hotKey)
            }
        }
    }
}
