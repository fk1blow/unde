import AppKit
import Carbon.HIToolbox

/// What unde does when a file is copied (a Finder ⌘C carries a `public.file-url`).
/// Both capturing modes store only a *reference* — the path — never the bytes.
enum FileCaptureMode: String, CaseIterable {
    case keepFile   // capture; paste re-pastes the actual file
    case keepPath   // capture; paste inserts the path as text
    case ignore     // never capture files
}

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
        static let retentionDays = "retentionDays"
        static let restorePasteboard = "restorePasteboard"
        static let restoreDelayMS = "restoreDelayMS"
        static let hotKey = "hotKeyCombo"
        static let didRequestAccessibility = "didRequestAccessibility"
        static let paused = "paused"
        static let excludedBundleIDs = "excludedBundleIDs"
        static let launchAtLogin = "launchAtLogin"
        static let skipSecrets = "skipSecrets"
        static let showPreview = "showPreview"
        static let uiScale = "uiScale"
        static let fileCaptureMode = "fileCaptureMode"
    }

    /// Bounds for the picker UI scale (Appearance pref). 1.0 is the design size.
    static let uiScaleRange: ClosedRange<Double> = 0.8...1.5

    init() {
        defaults.register(defaults: [
            Key.historyCapacity: 500,
            Key.restorePasteboard: true,
            Key.restoreDelayMS: 500,
            Key.paused: false,
            Key.showPreview: true,
            Key.uiScale: 1.0,
            Key.fileCaptureMode: FileCaptureMode.keepFile.rawValue,
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

    /// How many days of history to keep; `0` means forever (RET-1, RET-2). Age
    /// eviction is off by default — an absent key reads as 0 — so a version update
    /// never silently drops history the user didn't ask to lose. The other allowed
    /// values (1, 7, 30, 90) are offered by the Settings picker.
    var retentionDays: Int {
        get { defaults.integer(forKey: Key.retentionDays) }
        set { defaults.set(newValue, forKey: Key.retentionDays) }
    }

    /// The instant before which history items are considered expired, or nil when
    /// retention is off ("Forever"). Callers evict everything older than this.
    func retentionCutoff(now: Date = Date()) -> Date? {
        retentionDays > 0 ? now.addingTimeInterval(-Double(retentionDays) * 86_400) : nil
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

    /// Show the detached preview card beside the picker. On by default.
    var showPreview: Bool {
        get { defaults.bool(forKey: Key.showPreview) }
        set { defaults.set(newValue, forKey: Key.showPreview) }
    }

    /// Uniform scale applied to the whole picker UI (Appearance pref). Clamped to
    /// `uiScaleRange`; 1.0 is the design size.
    var uiScale: Double {
        get {
            let v = defaults.double(forKey: Key.uiScale)
            guard v > 0 else { return 1.0 }
            return min(Self.uiScaleRange.upperBound, max(Self.uiScaleRange.lowerBound, v))
        }
        set { defaults.set(newValue, forKey: Key.uiScale) }
    }

    var excludedBundleIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.excludedBundleIDs) ?? []) }
        set { defaults.set(Array(newValue), forKey: Key.excludedBundleIDs) }
    }

    /// How a copied file is handled (Clipboard pref). Default keeps the file.
    var fileCaptureMode: FileCaptureMode {
        get { FileCaptureMode(rawValue: defaults.string(forKey: Key.fileCaptureMode) ?? "") ?? .keepFile }
        set { defaults.set(newValue.rawValue, forKey: Key.fileCaptureMode) }
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
