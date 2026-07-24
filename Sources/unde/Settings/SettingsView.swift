import SwiftUI
import AppKit

/// The settings UI: a single window with grouped sections. Intentionally spare —
/// this is a personal tool, so it exposes exactly the knobs worth changing.
///   • General    — show-preview toggle, editable keybinding
///   • Appearance — a uniform UI scale for the picker
struct SettingsView: View {
    let prefs: Preferences
    let onHotKeyChange: (KeyCombo) -> Void

    @State private var showPreview: Bool
    @State private var combo: KeyCombo
    @State private var recording = false
    @State private var uiScale: Double
    @State private var fileMode: FileCaptureMode
    private var recorderMonitor = RecorderMonitor()

    init(prefs: Preferences, onHotKeyChange: @escaping (KeyCombo) -> Void) {
        self.prefs = prefs
        self.onHotKeyChange = onHotKeyChange
        _showPreview = State(initialValue: prefs.showPreview)
        _combo = State(initialValue: prefs.hotKeyCombo)
        _uiScale = State(initialValue: prefs.uiScale)
        _fileMode = State(initialValue: prefs.fileCaptureMode)
    }

    var body: some View {
        Form {
            Section("General") {
                LabeledContent("Show preview") {
                    Toggle("", isOn: $showPreview)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: showPreview) { prefs.showPreview = $0 }
                }
                LabeledContent("Keybinding") {
                    Button(recording ? "Press keys…" : combo.display) {
                        toggleRecording()
                    }
                    .frame(minWidth: 110)
                }
            }

            Section("Clipboard") {
                Picker("When you copy a file", selection: $fileMode) {
                    Text("Keep the file").tag(FileCaptureMode.keepFile)
                    Text("Keep its path").tag(FileCaptureMode.keepPath)
                    Text("Ignore").tag(FileCaptureMode.ignore)
                }
                .onChange(of: fileMode) { prefs.fileCaptureMode = $0 }
            }

            Section("Appearance") {
                LabeledContent("UI scale") {
                    HStack(spacing: 10) {
                        Slider(value: $uiScale,
                               in: Preferences.uiScaleRange,
                               step: 0.05)
                            .frame(width: 160)
                            .onChange(of: uiScale) { prefs.uiScale = $0 }
                        Text("\(Int((uiScale * 100).rounded()))%")
                            .font(.system(.body, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                scalePreview
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Live scale preview

    /// The design-size width and viewport height of the sample. The sample lays
    /// out at `previewBaseWidth`, is scaled by `uiScale`, then clipped to a fixed
    /// viewport so the Settings window never has to grow — the rows just render
    /// larger/smaller in place, exactly as the picker will.
    private static let previewBaseWidth: CGFloat = 300
    private static let previewViewportH: CGFloat = 96

    private var scalePreview: some View {
        let s = CGFloat(uiScale)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Preview")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                PickerRow(text: "Q3 roadmap — meeting notes", meta: "clipboard", active: true)
                PickerRow(text: "https://example.com/design/specs", active: false)
            }
            .frame(width: Self.previewBaseWidth, alignment: .topLeading)
            .scaleEffect(s, anchor: .topLeading)
            .frame(width: Self.previewBaseWidth, height: Self.previewViewportH, alignment: .topLeading)
            .clipped()
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.neutral500.opacity(0.4), lineWidth: 1)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func toggleRecording() {
        if recording {
            recorderMonitor.stop()
            recording = false
            return
        }
        recording = true
        recorderMonitor.start { captured in
            recording = false
            recorderMonitor.stop()
            if let captured {
                combo = captured
                prefs.hotKeyCombo = captured
                onHotKeyChange(captured)
            }
        }
    }
}

/// Captures a single key combo via a local event monitor while recording.
private final class RecorderMonitor {
    private var monitor: Any?
    func start(_ completion: @escaping (KeyCombo?) -> Void) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if event.keyCode == UInt16(53) { completion(nil); return nil } // Escape cancels
            completion(KeyCombo.from(event: event))
            return nil
        }
    }
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }
}
