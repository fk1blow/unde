import AppKit
import SwiftUI

/// A single row rendered in the picker — either a pinned snippet or a clipboard
/// history item, flattened to what the view needs to draw.
struct DisplayRow: Identifiable {
    enum Kind { case pinned, clip, suggestion }

    let id: String
    let kind: Kind
    let text: String         // the single line shown: exactly what gets pasted
    let meta: String?        // faded, secondary detail shown after `text`
    let slot: Int?           // pinned slot for the ⌘n badge
    let image: NSImage?      // clip thumbnail (image content only — drives preview)
    var icon: NSImage? = nil // small leading glyph (e.g. a file's Finder icon)

    // Backing data for the action layer.
    let snippet: Snippet?
    let clip: ClipboardItem?

    /// For a `.suggestion` row: the scope its token completes to (FLT-5).
    var scopeToken: QueryScope? = nil

    /// A token-autocomplete row shown while the user is typing a partial `#…`.
    static func suggestion(_ scope: QueryScope) -> DisplayRow {
        DisplayRow(
            id: "tok-\(scope.rawValue)",
            kind: .suggestion,
            text: scope.suggestionLabel,
            meta: scope.suggestionHint,
            slot: nil,
            image: nil,
            snippet: nil,
            clip: nil,
            scopeToken: scope
        )
    }

    /// True when this row is a captured file reference.
    var isFile: Bool { clip?.kind == .file }

    /// The on-disk path for a file row, else nil.
    var filePath: String? { clip?.filePath }

    /// The full, untruncated text for the preview pane (keeps newlines, unlike
    /// the single-line `text`).
    var fullText: String {
        snippet?.content ?? clip?.text ?? text
    }
}

/// Observable state the SwiftUI picker renders. Owned and driven by
/// `PickerController` — selection is moved by the AppKit event monitor, not by
/// SwiftUI focus, so keyboard behaviour is deterministic.
final class PickerModel: ObservableObject {
    @Published var query: String = ""
    /// The focus row — drives the preview pane and auto-scroll. With no
    /// multi-selection this is simply "the selected row".
    @Published var selection: Int = 0
    /// The other end of a Shift-extended selection. Equal to `selection` when a
    /// single row is selected; the inclusive range between the two is the set of
    /// selected rows (see `selectionRange`).
    @Published var anchor: Int = 0
    @Published var pinnedRows: [DisplayRow] = []
    @Published var clipRows: [DisplayRow] = []
    /// Token-autocomplete rows shown *instead of* results while the user is typing
    /// a partial `#…` scope token (FLT-5). Non-empty ⇒ "completing" mode.
    @Published var suggestionRows: [DisplayRow] = []
    /// The active kind scope, or nil when unscoped. Drives the pill in the search
    /// row and the scope-aware count/empty labels.
    @Published var scope: QueryScope? = nil
    /// The residual fuzzy text after the scope token is stripped — what the search
    /// row draws next to the pill (so it shows "foo", not "#image foo").
    @Published var queryText: String = ""
    /// The total number of pinned snippets (unfiltered), so the footer can show a
    /// ⌘n jump hint that matches how many slots actually exist. ⌘1–9 fire against
    /// the full ordered list regardless of the query, so this is deliberately not
    /// the filtered `pinnedRows.count`.
    @Published var pinnedSlotCount: Int = 0

    @Published var accessibilityTrusted: Bool = true

    /// Whether the detached preview card is allowed to appear (SET pref). When
    /// false, the picker is just the main card regardless of the selection type.
    @Published var showPreview: Bool = true

    /// Uniform scale for the whole picker UI (Appearance pref). 1.0 is the design
    /// size; the view applies it via `scaleEffect` and the controller sizes the
    /// panel to match.
    @Published var uiScale: CGFloat = 1.0

    /// Bumped by the controller each time the picker is shown. The preview surface
    /// keys its measured content on this, so re-opening the picker forces a fresh
    /// `onAppear` size report even when the previous session ended on an
    /// identically-sized preview (which would otherwise emit no change).
    @Published var previewGeneration: Int = 0

    /// Set true when a selection change comes from the mouse hovering a row, so
    /// the list does not auto-scroll to re-center under the pointer. Consumed and
    /// cleared by the list's onChange handler. Keyboard navigation leaves this
    /// false and scrolls the selection into view as before.
    var suppressAutoScroll: Bool = false

    /// True while the picker is showing token suggestions rather than results.
    var isCompleting: Bool { !suggestionRows.isEmpty }

    /// The navigable rows: the suggestion list while completing, else the results.
    /// Selection, count and commit all key off this, so nothing else needs to know
    /// which mode the picker is in.
    var allRows: [DisplayRow] { isCompleting ? suggestionRows : pinnedRows + clipRows }
    var isEmpty: Bool { pinnedRows.isEmpty && clipRows.isEmpty }
    var count: Int { allRows.count }

    /// The inclusive, contiguous range of currently-selected rows (a single row
    /// when `anchor == selection`).
    var selectionRange: ClosedRange<Int> { min(anchor, selection)...max(anchor, selection) }
    /// True when a Shift-extended selection spans more than one row.
    var isMultiSelecting: Bool { anchor != selection }
    /// Whether the row at `index` falls inside the current selection.
    func isSelected(_ index: Int) -> Bool { selectionRange.contains(index) }

    /// The currently highlighted row, if any — drives the preview pane.
    var selectedRow: DisplayRow? {
        let rows = allRows
        guard selection >= 0, selection < rows.count else { return nil }
        return rows[selection]
    }

    var countLabel: String {
        if isCompleting { return "\(count) \(count == 1 ? "filter" : "filters")" }
        if isMultiSelecting {
            return "\(selectionRange.count) selected"
        }
        let n = count
        if let scope { return "\(n) \(scope.countNoun(n))" }
        return "\(n) \(n == 1 ? "result" : "results")"
    }

    /// The footer's ⌘n jump-hint key, sized to the pinned slots that actually
    /// exist (1–9), or nil when nothing is pinned so the hint can be hidden.
    var jumpHintKey: String? {
        let n = min(9, pinnedSlotCount)
        switch n {
        case 0:  return nil
        case 1:  return "⌘1"
        default: return "⌘1–\(n)"
        }
    }

    /// The message shown when a query (or scope) matches nothing. Names the scope
    /// so an empty `#image` reads "No images", not a generic miss (FLT-7).
    var emptyMessage: String {
        if let scope { return "No \(scope.pluralNoun)" }
        return "No matches for “\(queryText)”"
    }
}
