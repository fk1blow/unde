import AppKit
import SwiftUI
import Combine
import Carbon.HIToolbox

/// Owns the picker panel, its SwiftUI content, selection state, and all keyboard
/// handling. The panel and its full view hierarchy are constructed once here and
/// only shown/hidden afterwards — never rebuilt — to keep hotkey→visible inside
/// the 50ms budget.
final class PickerController: NSObject, NSWindowDelegate {

    private let history: HistoryStore
    private let snippets: SnippetStore
    private let paster: Paster
    private let imageStore: ImageStore?
    private let prefs: Preferences

    private let model = PickerModel()
    private let panel = PickerPanel()
    private var hostingView: NSHostingView<PickerView>!

    private var eventMonitor: Any?
    private var previousApp: NSRunningApplication?
    private var isVisible = false
    private var isDismissing = false
    private var cancellables = Set<AnyCancellable>()

    init(history: HistoryStore, snippets: SnippetStore, paster: Paster, prefs: Preferences, imageStore: ImageStore? = nil) {
        self.history = history
        self.snippets = snippets
        self.paster = paster
        self.imageStore = imageStore
        self.prefs = prefs
        super.init()

        let view = PickerView(
            model: model,
            onClickRow: { [weak self] index in self?.commit(at: index, mode: .pasteInPlace) },
            onHoverRow: { [weak self] index in
                guard let self else { return }
                // Hover-driven selection: highlight the row but don't scroll the
                // list under the pointer.
                self.model.suppressAutoScroll = true
                self.model.selection = index
            }
        )
        hostingView = NSHostingView(rootView: view)
        panel.contentView = hostingView
        panel.delegate = self

        // Live-refresh the list while the picker is open, so a copy made with the
        // panel up (or a just-captured item) appears immediately.
        Publishers.Merge(
            history.$items.map { _ in () },
            snippets.$snippets.map { _ in () }
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in
            guard let self, self.isVisible else { return }
            self.rebuildRows()
        }
        .store(in: &cancellables)
    }

    // MARK: Show / hide

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        guard !isVisible else { return }
        // Capture the app the user is working in *before* we show anything.
        previousApp = NSWorkspace.shared.frontmostApplication

        model.query = ""
        model.selection = 0
        model.accessibilityTrusted = Permissions.isAccessibilityTrusted
        model.showPreview = prefs.showPreview
        model.uiScale = CGFloat(prefs.uiScale)
        rebuildRows()

        // Fixed, modest panel size — never asks SwiftUI for its size (whose
        // ScrollView fittingSize under-reported and produced an occasional
        // too-small panel). The list fills the space and scrolls for overflow.
        // Scaled by the Appearance UI-scale pref so the panel matches the scaled
        // content the view renders.
        let scale = model.uiScale
        let size = NSSize(width: Self.panelWidth * scale, height: Self.panelHeight * scale)
        panel.setContentSize(size)
        positionPanel(size: size)

        panel.orderFrontRegardless()
        panel.makeKey()
        installEventMonitor()
        isVisible = true
    }

    func hide() {
        guard isVisible else { return }
        isDismissing = true
        removeEventMonitor()
        panel.orderOut(nil)
        isVisible = false
        isDismissing = false
    }

    // Fixed panel size — modest, consistent on every open. The window spans the
    // main card plus the detached preview card and gap; the window background is
    // clear, so the space to the right of the main card is invisible when no
    // preview is showing.
    static let panelWidth: CGFloat = PickerView.windowWidth
    static let panelHeight: CGFloat = PickerView.baseHeight

    private func positionPanel(size: NSSize) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        // Centre the *main card* on screen (not the whole window), so the panel
        // sits where the user expects and the preview floats off to its right.
        // The main card's on-screen width scales with the UI-scale pref.
        var x = visible.midX - (PickerView.mainWidth * model.uiScale) / 2
        // Keep the window fully on screen; if the preview would overflow the
        // right edge, slide the whole thing left rather than clip it.
        x = min(x, visible.maxX - size.width)
        x = max(x, visible.minX)
        let topInset = visible.height * 0.14
        let y = visible.maxY - topInset - size.height
        panel.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
    }

    // MARK: Row building

    private func rebuildRows() {
        let query = model.query.trimmingCharacters(in: .whitespaces)

        // Pinned snippets: filtered by query but never reordered by it (SEL-4).
        // The ⌘n badge is the snippet's *position* in the ordered list (1–9), not
        // its stored slot — so with two pinned items you always see ⌘1 and ⌘2,
        // never a gap like ⌘3 left behind by a deleted slot.
        let pinned = snippets.ordered.enumerated().compactMap { index, snippet -> DisplayRow? in
            let matches = query.isEmpty
                || FuzzyMatcher.matches(query: query, candidate: snippet.title)
                || FuzzyMatcher.matches(query: query, candidate: snippet.content)
            guard matches else { return nil }
            return DisplayRow(
                id: "s-\(snippet.id.uuidString)",
                kind: .pinned,
                text: snippet.content.replacingOccurrences(of: "\n", with: "  "),
                meta: nil,
                slot: index < 9 ? index + 1 : nil,
                image: nil,
                snippet: snippet,
                clip: nil
            )
        }

        // Clipboard history: fuzzy-filtered and ranked by score when querying.
        let clipItems: [ClipboardItem]
        if query.isEmpty {
            clipItems = history.items
        } else {
            clipItems = history.items
                .compactMap { item -> (ClipboardItem, Int)? in
                    guard let score = FuzzyMatcher.score(query: query, candidate: item.preview) else { return nil }
                    return (item, score)
                }
                .sorted { $0.1 > $1.1 }
                .map { $0.0 }
        }

        let clips = clipItems.map { item in
            DisplayRow(
                id: "c-\(item.id)",
                kind: .clip,
                text: item.rowLabel,
                meta: item.rowMeta,
                slot: nil,
                image: item.resolvedImage(using: imageStore),
                snippet: nil,
                clip: item
            )
        }

        model.pinnedRows = pinned
        model.clipRows = clips
        if model.selection >= model.count {
            model.selection = max(0, model.count - 1)
        }
    }

    // MARK: Selection

    private func move(_ delta: Int) {
        let n = model.count
        guard n > 0 else { return }
        // Keyboard navigation should scroll the selection into view.
        model.suppressAutoScroll = false
        model.selection = (model.selection + delta + n) % n
    }

    // MARK: Commit / paste

    private func commit(at index: Int, mode: Paster.PasteMode) {
        let rows = model.allRows
        guard index >= 0, index < rows.count else { return }
        performPaste(row: rows[index], mode: mode)
    }

    private func commitSelected(mode: Paster.PasteMode) {
        commit(at: model.selection, mode: mode)
    }

    /// ⌘n pastes the n-th pinned snippet by display order, matching the ⌘n badge
    /// shown on the row (positional, not the stored slot).
    private func pastePinnedSlot(_ position: Int) {
        let ordered = snippets.ordered
        guard position >= 1, position <= min(9, ordered.count) else { return }
        let snippet = ordered[position - 1]
        let row = DisplayRow(
            id: "s-\(snippet.id.uuidString)", kind: .pinned, text: snippet.content,
            meta: nil, slot: position, image: nil, snippet: snippet, clip: nil
        )
        performPaste(row: row, mode: .pasteInPlace)
    }

    private func performPaste(row: DisplayRow, mode: Paster.PasteMode) {
        let app = previousApp
        let outcome: Paster.Outcome

        if let snippet = row.snippet {
            hide()
            outcome = paster.paste(text: snippet.content, previousApp: app, mode: mode)
        } else if let text = row.clip?.text {
            hide()
            outcome = paster.paste(text: text, previousApp: app, mode: mode)
        } else if let clip = row.clip, clip.kind == .image,
                  let path = clip.imagePath, let data = imageStore?.loadData(path: path) {
            // Image paste: put the stored bytes back on the pasteboard, then ⌘V.
            hide()
            outcome = paster.paste(imageData: data, previousApp: app, mode: mode)
        } else {
            return
        }

        switch outcome {
        case .pasted, .copiedOnly:
            break
        case .blockedBySecureInput(let process):
            let who = process.map { " — \($0) has Secure Keyboard Entry on" } ?? ""
            NoticePresenter.shared.show("Secure Input active\(who). Press ⌘V to paste.")
        case .notTrusted:
            NoticePresenter.shared.show("Accessibility permission needed to paste. It's on the clipboard — press ⌘V.")
        }
    }

    /// Delete the previous word from the query: drop any trailing spaces, then the
    /// run of non-space characters before them.
    private func deleteWordFromQuery() {
        guard !model.query.isEmpty else { return }
        var q = model.query
        while let last = q.last, last == " " { q.removeLast() }
        while let last = q.last, last != " " { q.removeLast() }
        model.query = q
        model.selection = 0
        rebuildRows()
    }

    private func promoteSelected() {
        let rows = model.allRows
        guard model.selection < rows.count, let clip = rows[model.selection].clip, let text = clip.text else { return }
        // Don't create a second copy of something already pinned (SNP dedup).
        if snippets.isPinned(content: text) {
            NoticePresenter.shared.show("Already pinned")
            return
        }
        snippets.promote(text: text)
        rebuildRows()
        NoticePresenter.shared.show("Pinned to snippets")
    }

    private func deleteSelected() {
        let rows = model.allRows
        guard model.selection < rows.count else { return }
        let row = rows[model.selection]
        if let clip = row.clip {
            // ⌘Delete removes a history item (PRV-3).
            history.remove(id: clip.id)
            rebuildRows()
        } else if let snippet = row.snippet {
            // ⌘Delete also removes a pinned snippet, immediately — the same
            // delete the Settings pane performs. The freed slot (1–9) becomes
            // available again for the next promote; nothing is renumbered.
            snippets.delete(id: snippet.id)
            rebuildRows()
        }
    }

    // MARK: Keyboard

    private func installEventMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            return self.handleKeyDown(event) ? nil : event
        }
    }

    private func removeEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    /// Returns true if the event was handled (and should be swallowed).
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = flags.contains(.command)
        let ctrl = flags.contains(.control)
        let shift = flags.contains(.shift)
        let option = flags.contains(.option)
        let code = Int(event.keyCode)
        let chars = event.charactersIgnoringModifiers ?? ""

        // Command combinations first — these fire regardless of filter text.
        if cmd {
            if let n = Int(chars), (1...9).contains(n) { pastePinnedSlot(n); return true }
            if chars == "p" { promoteSelected(); return true }
            if code == kVK_Delete {
                // While searching, ⌘⌫ clears the query to the start (standard
                // "delete to beginning of line"). With no query it falls back to
                // deleting the selected item.
                if model.query.isEmpty {
                    deleteSelected()
                } else {
                    model.query = ""
                    model.selection = 0
                    rebuildRows()
                }
                return true
            }
            if code == kVK_Return || code == kVK_ANSI_KeypadEnter { commitSelected(mode: .copyOnly); return true }
            return true // swallow other cmd combos while open
        }

        switch code {
        case kVK_Escape:
            hide(); return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            commitSelected(mode: shift ? .pasteAsPlainText : .pasteInPlace); return true
        case kVK_DownArrow:
            move(1); return true
        case kVK_UpArrow:
            move(-1); return true
        case kVK_Delete: // backspace edits the query
            if option {
                // ⌥⌫ deletes the previous word of the query (macOS convention).
                deleteWordFromQuery()
            } else if !model.query.isEmpty {
                model.query.removeLast()
                rebuildRows()
            }
            return true
        default:
            break
        }

        // Emacs-style navigation.
        if ctrl {
            if chars == "n" { move(1); return true }
            if chars == "p" { move(-1); return true }
            return false
        }

        // Type-to-filter: accumulate printable characters.
        if let scalars = event.characters, scalars.count == 1,
           let first = scalars.unicodeScalars.first,
           !CharacterSet.controlCharacters.contains(first) {
            model.query.append(scalars)
            model.selection = 0
            rebuildRows()
            return true
        }

        return false
    }

    // MARK: NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // Loss of key status dismisses (INV-4), unless we're already hiding as
        // part of a paste.
        guard isVisible, !isDismissing else { return }
        hide()
    }
}
