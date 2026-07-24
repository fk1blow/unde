import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The settings UI: General, Snippets, Privacy. Kept intentionally spare — this
/// is a personal tool with one user, so the panes expose exactly the knobs the
/// PRD calls for and nothing more.
struct SettingsView: View {
    let prefs: Preferences
    @ObservedObject var snippets: SnippetStore
    let history: HistoryStore
    let onHotKeyChange: (KeyCombo) -> Void

    var body: some View {
        TabView {
            GeneralPane(prefs: prefs, onHotKeyChange: onHotKeyChange)
                .tabItem { Label("General", systemImage: "gearshape") }
            SnippetsPane(snippets: snippets)
                .tabItem { Label("Snippets", systemImage: "pin") }
            PrivacyPane(prefs: prefs, history: history)
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
        }
        .frame(width: 560, height: 460)
    }
}

// MARK: - General

private struct GeneralPane: View {
    let prefs: Preferences
    let onHotKeyChange: (KeyCombo) -> Void

    @State private var combo: KeyCombo
    @State private var recording = false
    @State private var restore: Bool
    @State private var capacity: Int
    @State private var launchAtLogin: Bool
    private var recorderMonitor = RecorderMonitor()

    init(prefs: Preferences, onHotKeyChange: @escaping (KeyCombo) -> Void) {
        self.prefs = prefs
        self.onHotKeyChange = onHotKeyChange
        _combo = State(initialValue: prefs.hotKeyCombo)
        _restore = State(initialValue: prefs.restorePasteboard)
        _capacity = State(initialValue: prefs.historyCapacity)
        _launchAtLogin = State(initialValue: prefs.launchAtLogin)
    }

    var body: some View {
        Form {
            Section("Hotkey") {
                HStack {
                    Text("Show picker")
                    Spacer()
                    Button(recording ? "Press keys…" : combo.display) {
                        toggleRecording()
                    }
                    .frame(minWidth: 120)
                }
            }
            Section("Pasting") {
                Toggle("Restore previous clipboard after paste", isOn: $restore)
                    .onChange(of: restore) { prefs.restorePasteboard = $0 }
            }
            Section("History") {
                Stepper("Keep \(capacity) items", value: $capacity, in: 100...2000, step: 100)
                    .onChange(of: capacity) { prefs.historyCapacity = $0 }
            }
            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { newValue in
                        prefs.launchAtLogin = newValue
                        LaunchAtLogin.set(newValue)
                    }
            }
            if !Permissions.isAccessibilityTrusted {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                        Text("Accessibility permission is off — auto-paste won't work.")
                            .font(.callout)
                        Spacer()
                        Button("Open Settings") { Permissions.openAccessibilitySettings() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
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

// MARK: - Snippets

private struct SnippetsPane: View {
    @ObservedObject var snippets: SnippetStore
    @State private var selection: UUID?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(snippets.ordered) { snippet in
                    HStack(spacing: 10) {
                        if let slot = snippet.slot {
                            Text("⌘\(slot)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(width: 28)
                        } else {
                            Color.clear.frame(width: 28)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(snippet.title).lineLimit(1)
                            if snippet.label != nil {
                                Text(snippet.content.replacingOccurrences(of: "\n", with: " "))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .tag(snippet.id)
                }
            }
            Divider()
            HStack {
                Button {
                    let s = snippets.promote(text: "New snippet", label: "New snippet")
                    selection = s.id
                } label: { Image(systemName: "plus") }
                Button {
                    if let selection { snippets.delete(id: selection) }
                } label: { Image(systemName: "minus") }
                .disabled(selection == nil)
                Spacer()
                Text("\(snippets.snippets.count) snippets")
                    .font(.caption).foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .padding(8)

            if let selection, let snippet = snippets.snippets.first(where: { $0.id == selection }) {
                Divider()
                SnippetEditor(snippet: snippet, snippets: snippets)
                    .padding()
            }
        }
    }
}

private struct SnippetEditor: View {
    let snippet: Snippet
    let snippets: SnippetStore
    @State private var label: String
    @State private var content: String
    @State private var slot: Int

    init(snippet: Snippet, snippets: SnippetStore) {
        self.snippet = snippet
        self.snippets = snippets
        _label = State(initialValue: snippet.label ?? "")
        _content = State(initialValue: snippet.content)
        _slot = State(initialValue: snippet.slot ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Label (optional)", text: $label)
            TextEditor(text: $content)
                .font(.system(size: 13))
                .frame(height: 70)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))
            Picker("Slot", selection: $slot) {
                Text("None").tag(0)
                ForEach(1...9, id: \.self) { Text("⌘\($0)").tag($0) }
            }
            .pickerStyle(.menu)
            .frame(width: 160)
            Button("Save") { save() }
        }
        .id(snippet.id)
        .onChange(of: snippet.id) { _ in
            label = snippet.label ?? ""
            content = snippet.content
            slot = snippet.slot ?? 0
        }
    }

    private func save() {
        var updated = snippet
        updated.label = label.isEmpty ? nil : label
        updated.content = content
        updated.slot = slot == 0 ? nil : slot
        snippets.update(updated)
    }
}

// MARK: - Privacy

private struct PrivacyPane: View {
    let prefs: Preferences
    let history: HistoryStore
    @State private var excluded: [String]
    @State private var newID = ""
    @State private var skipSecrets: Bool
    @State private var confirmingClear = false

    init(prefs: Preferences, history: HistoryStore) {
        self.prefs = prefs
        self.history = history
        _excluded = State(initialValue: Array(prefs.excludedBundleIDs).sorted())
        _skipSecrets = State(initialValue: prefs.skipSecrets)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Excluded applications")
                .font(.headline)
            Text("Nothing copied while one of these apps is frontmost is captured.")
                .font(.caption).foregroundColor(.secondary)
            List {
                ForEach(excluded, id: \.self) { id in
                    HStack {
                        Text(id)
                        Spacer()
                        Button {
                            excluded.removeAll { $0 == id }
                            persist()
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .frame(minHeight: 120)
            HStack {
                TextField("com.example.app", text: $newID)
                Button("Add App…") { pickApp() }
                Button("Add") { addTypedID() }
            }

            Divider()

            Toggle("Skip capturing things that look like secrets (keys, tokens, JWTs)", isOn: $skipSecrets)
                .onChange(of: skipSecrets) { prefs.skipSecrets = $0 }

            HStack {
                Button(role: .destructive) { confirmingClear = true } label: {
                    Label("Clear clipboard history…", systemImage: "trash")
                }
                Spacer()
            }
        }
        .padding()
        .confirmationDialog("Clear all clipboard history?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { history.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes all captured items and their images. Pinned snippets are not affected.")
        }
    }

    /// Native app picker → resolve the chosen .app to its bundle identifier.
    private func pickApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url,
           let bundle = Bundle(url: url), let id = bundle.bundleIdentifier {
            if !excluded.contains(id) { excluded.append(id); excluded.sort() }
            persist()
        }
    }

    private func addTypedID() {
        let trimmed = newID.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if !excluded.contains(trimmed) { excluded.append(trimmed); excluded.sort() }
        newID = ""
        persist()
    }

    private func persist() {
        prefs.excludedBundleIDs = Set(excluded)
    }
}
