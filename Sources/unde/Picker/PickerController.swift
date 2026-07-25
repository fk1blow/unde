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

    // The preview lives in its own panel to the right of the main card. Keeping it
    // separate means a shrinking or vanishing preview clears its own window backing
    // (resize/orderOut) instead of ghosting a stale raster on the main panel.
    private let previewPanel = PickerPanel(acceptsKey: false)
    private var previewHostingView: NSHostingView<PickerView>!

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
                // list under the pointer. A hover collapses any keyboard-built
                // range back to the single hovered row.
                self.model.suppressAutoScroll = true
                self.model.selection = index
                self.model.anchor = index
            }
        )
        hostingView = NSHostingView(rootView: view)
        panel.contentView = hostingView
        panel.delegate = self

        // The preview panel renders the same model through the `.preview` surface.
        // The surface reports its natural size back through `onPreviewSize`, driven
        // by SwiftUI layout, so the panel resizes in lockstep with the content it
        // renders — never lagging a selection behind (which showed a stale preview
        // or clipped taller content into a too-small panel).
        let previewView = PickerView(
            model: model,
            surface: .preview,
            onPreviewSize: { [weak self] size in self?.applyPreviewSize(size) }
        )
        previewHostingView = NSHostingView(rootView: previewView)
        previewPanel.contentView = previewHostingView
        previewPanel.ignoresMouseEvents = true

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
        model.anchor = 0
        model.accessibilityTrusted = Permissions.isAccessibilityTrusted
        model.showPreview = prefs.showPreview
        model.uiScale = CGFloat(prefs.uiScale)
        // Force the preview surface to re-measure for this open (re-fires onAppear).
        model.previewGeneration &+= 1
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

        // Order the preview panel in above the main card so its hosting view lays
        // out and reports a size. It stays transparent until `applyPreviewSize`
        // gives it real content, so there's no stale flash while SwiftUI renders
        // the first selection. It never becomes key (canBecomeKey == false), so it
        // can't steal focus and dismiss the picker.
        previewPanel.alphaValue = 0
        previewPanel.order(.above, relativeTo: panel.windowNumber)
    }

    func hide() {
        guard isVisible else { return }
        isDismissing = true
        removeEventMonitor()
        previewPanel.orderOut(nil)
        panel.orderOut(nil)
        isVisible = false
        isDismissing = false
    }

    // MARK: Preview panel

    /// Size, position and show/hide the detached preview panel to match the current
    /// selection. Called by the `.preview` surface's `onPreviewSize` callback as
    /// SwiftUI lays the content out, so `designSize` is always the size of what's
    /// *currently* rendered — never a selection behind (the stale/clipping bug).
    ///
    /// `designSize` is the unscaled (design) size — the surface reports it before
    /// its `scaleEffect`, so we multiply by the UI scale here.
    private func applyPreviewSize(_ designSize: CGSize) {
        guard isVisible, model.showPreview, designSize.height > 4 else {
            // A near-zero height is the "no preview" sentinel (Color.clear 1×1);
            // keep the panel ordered-in but transparent so it keeps laying out
            // (and reporting sizes) for the next selection.
            previewPanel.alphaValue = 0
            return
        }
        let scale = model.uiScale
        let size = NSSize(width: (PickerView.previewWidth * scale).rounded(),
                          height: (designSize.height * scale).rounded())
        previewPanel.setContentSize(size)
        positionPreviewPanel(size: size)
        previewPanel.alphaValue = 1
    }

    /// Place the preview panel to the right of the main panel, top-aligned; if it
    /// would run off the screen's right edge, place it to the left instead.
    private func positionPreviewPanel(size: NSSize) {
        let main = panel.frame
        let gap = PickerView.cardGap * model.uiScale
        var x = main.maxX + gap
        let y = main.maxY - size.height
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: main.midX, y: main.midY)) } ?? NSScreen.main
        if let visible = screen?.visibleFrame, x + size.width > visible.maxX {
            x = main.minX - gap - size.width
        }
        previewPanel.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
    }

    // Fixed main-panel size — modest, consistent on every open. The panel holds
    // only the main card now; the preview floats in its own panel to the right.
    static let panelWidth: CGFloat = PickerView.mainWidth
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
        let parsed = QueryParser.parse(model.query)
        model.scope = parsed.scope
        model.queryText = parsed.text

        // Typing a partial `#…` token: show the autocomplete list instead of
        // results (FLT-5). Nothing else runs — there are no rows to filter yet.
        if parsed.completing != nil {
            model.suggestionRows = parsed.suggestions.map { DisplayRow.suggestion($0) }
            model.pinnedRows = []
            model.clipRows = []
            clampSelection()
            return
        }
        model.suggestionRows = []

        let query = parsed.text
        let scope = parsed.scope
        // A scope other than #pinned hides the pinned section; #pinned hides history.
        // Unscoped shows both (the original behaviour).
        let showPinned = (scope == nil || scope == .pinned)
        let showClips = (scope == nil || scope != .pinned)

        // Pinned snippets: filtered by query but never reordered by it (SEL-4).
        // The ⌘n badge is the snippet's *position* in the ordered list (1–9), not
        // its stored slot — so with two pinned items you always see ⌘1 and ⌘2,
        // never a gap like ⌘3 left behind by a deleted slot.
        let pinned = !showPinned ? [] : snippets.ordered.enumerated().compactMap { index, snippet -> DisplayRow? in
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

        // Clipboard history: narrowed to the active kind scope (FLT-2, FLT-3), then
        // fuzzy-filtered and ranked by score when querying.
        let scoped = scope == nil ? history.items : history.items.filter { Self.matchesScope($0, scope!) }
        let clipItems: [ClipboardItem]
        if !showClips {
            clipItems = []
        } else if query.isEmpty {
            clipItems = scoped
        } else {
            clipItems = scoped
                .compactMap { item -> (ClipboardItem, Int)? in
                    guard let score = FuzzyMatcher.score(query: query, candidate: item.preview) else { return nil }
                    return (item, score)
                }
                .sorted { $0.1 > $1.1 }
                .map { $0.0 }
        }

        let clips = clipItems.map { item -> DisplayRow in
            // Files carry a small Finder icon (leading glyph) but no `image`, so
            // they never trigger the image preview card. Images keep their
            // thumbnail in `image`.
            let icon: NSImage? = item.kind == .file
                ? item.filePath.map { Self.fileIcon(for: $0) }
                : nil
            return DisplayRow(
                id: "c-\(item.id)",
                kind: .clip,
                text: item.rowLabel,
                meta: item.rowMeta,
                slot: nil,
                image: item.kind == .file ? nil : item.resolvedImage(using: imageStore),
                icon: icon,
                snippet: nil,
                clip: item
            )
        }

        model.pinnedRows = pinned
        model.clipRows = clips
        clampSelection()
        // The preview resizes itself: the `.preview` surface re-renders whenever the
        // rows or selection change and reports its new size through `applyPreviewSize`.
    }

    /// Whether a history item belongs to a kind scope (FLT-3). `#pinned` is handled
    /// by hiding history entirely, so it never matches a clip here.
    private static func matchesScope(_ item: ClipboardItem, _ scope: QueryScope) -> Bool {
        switch scope {
        case .image:  return item.kind == .image
        case .file:   return item.kind == .file
        case .text:   return item.kind == .text
        case .link:   return item.kind == .text && item.classification == "link"
        case .pinned: return false
        }
    }

    /// Keep `selection`/`anchor` inside the current row set after a rebuild.
    private func clampSelection() {
        let last = max(0, model.count - 1)
        if model.selection >= model.count { model.selection = last }
        if model.anchor >= model.count { model.anchor = last }
    }

    /// A small Finder icon for a file path, sized for a row's leading glyph.
    private static func fileIcon(for path: String) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }

    // MARK: Selection

    private func move(_ delta: Int, isRepeat: Bool = false) {
        let n = model.count
        guard n > 0 else { return }
        // Keyboard navigation should scroll the selection into view.
        model.suppressAutoScroll = false
        let next = model.selection + delta
        if next < 0 || next >= n {
            // At a boundary. Wrap only on a deliberate fresh press — while the key
            // is auto-repeating (held down) we clamp, so reaching an end stops there
            // instead of looping straight past it. Release and press again to wrap.
            if isRepeat { return }
            model.selection = (next + n) % n
        } else {
            model.selection = next
        }
        // A plain arrow collapses any multi-selection back to a single row.
        model.anchor = model.selection
    }

    /// Shift+arrow: move the focus while leaving the anchor fixed, growing or
    /// shrinking the selected range. Unlike `move`, this clamps at the ends rather
    /// than wrapping — extending a selection past the list edge makes no sense.
    private func extend(_ delta: Int) {
        let n = model.count
        guard n > 0 else { return }
        let next = model.selection + delta
        guard next >= 0, next < n else { return }
        model.suppressAutoScroll = false
        model.selection = next
    }

    // MARK: Commit / paste

    private func commit(at index: Int, mode: Paster.PasteMode, asPath: Bool = false) {
        let rows = model.allRows
        guard index >= 0, index < rows.count else { return }
        // A suggestion row isn't pasteable — selecting it completes its scope token
        // (FLT-5), whether reached by Enter or a click.
        if rows[index].kind == .suggestion {
            completeToken(rows[index].scopeToken)
            return
        }
        performPaste(row: rows[index], mode: mode, asPath: asPath)
    }

    /// Replace the query with a completed scope token and re-filter (FLT-5). The
    /// trailing space moves the parser out of "completing" into an active scope.
    private func completeToken(_ scope: QueryScope?) {
        guard let scope else { return }
        model.query = scope.token + " "
        model.selection = 0
        model.anchor = 0
        rebuildRows()
    }

    private func completeSelectedToken() {
        let rows = model.allRows
        guard model.selection >= 0, model.selection < rows.count else { return }
        completeToken(rows[model.selection].scopeToken)
    }

    /// ⌘A selects every currently-listed row, so a scoped list can be swept in one
    /// gesture: `#image` · ⌘A · ⌘⌫ (FLT-9). Scope-respecting for free — the list is
    /// already narrowed. A no-op while the token autocomplete is showing.
    private func selectAllVisible() {
        guard !model.isCompleting else { return }
        let n = model.count
        guard n > 0 else { return }
        model.suppressAutoScroll = false
        model.anchor = 0
        model.selection = n - 1
    }

    private func commitSelected(mode: Paster.PasteMode, asPath: Bool = false) {
        // A multi-row selection is for deletion only — pasting a range makes no
        // sense, so Enter is a no-op until the selection is narrowed to one row.
        guard !model.isMultiSelecting else { return }
        commit(at: model.selection, mode: mode, asPath: asPath)
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

    private func performPaste(row: DisplayRow, mode: Paster.PasteMode, asPath: Bool = false) {
        let app = previousApp
        let outcome: Paster.Outcome

        if let clip = row.clip, clip.kind == .file, let path = clip.filePath {
            // Files: ⌥⏎ (asPath) or the "Keep its path" mode pastes the path as
            // text; otherwise paste the actual file. A reference can dangle, so
            // check existence first and surface a notice rather than paste nothing.
            hide()
            if asPath || prefs.fileCaptureMode == .keepPath {
                outcome = paster.paste(text: path, previousApp: app, mode: mode)
            } else if FileManager.default.fileExists(atPath: path) {
                outcome = paster.paste(fileURL: URL(fileURLWithPath: path), previousApp: app, mode: mode)
            } else {
                NoticePresenter.shared.show("That file has moved or was deleted. Its path is still available with ⌥⏎.")
                return
            }
        } else if let snippet = row.snippet {
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
        model.anchor = 0
        rebuildRows()
    }

    private func promoteSelected() {
        let rows = model.allRows
        guard model.selection < rows.count else { return }
        // Already a pinned snippet — nothing to promote, and no notice needed.
        guard let clip = rows[model.selection].clip else { return }
        // Snippets are text; an image has no text to pin. Say so rather than
        // silently doing nothing (which reads as "pinning is broken").
        guard let text = clip.text, !text.isEmpty else {
            NoticePresenter.shared.show("Only text can be pinned")
            return
        }
        // Don't create a second copy of something already pinned (SNP dedup).
        if snippets.isPinned(content: text) {
            NoticePresenter.shared.show("Already pinned")
            return
        }
        snippets.promote(text: text)
        rebuildRows()
        NoticePresenter.shared.show("Pinned to snippets")
    }

    /// ⌘Delete removes the selected row(s). With a single selection this is one
    /// history item or pinned snippet (PRV-3); with a Shift-extended range it
    /// removes every row in the range at once. Freed snippet slots (1–9) become
    /// available again for the next promote; nothing is renumbered.
    private func deleteSelected() {
        let rows = model.allRows
        guard !rows.isEmpty else { return }
        let range = model.selectionRange.clamped(to: rows.indices.lowerBound...(rows.count - 1))

        // Gather the ids to delete before touching any store, so removals don't
        // shift the indices out from under us.
        var clipIDs = Set<String>()
        var snippetIDs = [UUID]()
        for i in range {
            let row = rows[i]
            if let clip = row.clip { clipIDs.insert(clip.id) }
            else if let snippet = row.snippet { snippetIDs.append(snippet.id) }
        }

        history.remove(ids: clipIDs)
        snippetIDs.forEach { snippets.delete(id: $0) }

        // Collapse to a single selection at the range's start; rebuildRows clamps
        // it if it now sits past the end of the shortened list.
        let landing = range.lowerBound
        model.selection = landing
        model.anchor = landing
        rebuildRows()
    }

    /// ⌘R reveals the selected file in Finder. No-op for non-file rows.
    private func revealSelectedInFinder() {
        let rows = model.allRows
        guard model.selection < rows.count, let path = rows[model.selection].filePath else { return }
        hide()
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
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
            if chars == "a" { selectAllVisible(); return true }
            if chars == "p" { promoteSelected(); return true }
            if chars == "r" { revealSelectedInFinder(); return true }
            if code == kVK_Delete {
                // While searching, ⌘⌫ clears the query to the start (standard
                // "delete to beginning of line"). With no query it falls back to
                // deleting the selected item.
                if model.query.isEmpty {
                    deleteSelected()
                } else {
                    model.query = ""
                    model.selection = 0
                    model.anchor = 0
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
        case kVK_Tab:
            // Tab completes the highlighted token while the autocomplete is showing;
            // otherwise it has no meaning in the picker.
            if model.isCompleting { completeSelectedToken(); return true }
            return false
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if option {
                // ⌥⏎ pastes a file's path as text (harmless for non-file rows,
                // which have no path and fall back to a normal paste).
                commitSelected(mode: .pasteInPlace, asPath: true)
            } else {
                commitSelected(mode: shift ? .pasteAsPlainText : .pasteInPlace)
            }
            return true
        case kVK_DownArrow:
            shift ? extend(1) : move(1, isRepeat: event.isARepeat); return true
        case kVK_UpArrow:
            shift ? extend(-1) : move(-1, isRepeat: event.isARepeat); return true
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
            if chars == "n" { move(1, isRepeat: event.isARepeat); return true }
            if chars == "p" { move(-1, isRepeat: event.isARepeat); return true }
            return false
        }

        // Type-to-filter: accumulate printable characters.
        if let scalars = event.characters, scalars.count == 1,
           let first = scalars.unicodeScalars.first,
           !CharacterSet.controlCharacters.contains(first) {
            model.query.append(scalars)
            model.selection = 0
            model.anchor = 0
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
