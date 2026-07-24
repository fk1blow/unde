import AppKit
import SwiftUI

/// A single row rendered in the picker — either a pinned snippet or a clipboard
/// history item, flattened to what the view needs to draw.
struct DisplayRow: Identifiable {
    enum Kind { case pinned, clip }

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

    var allRows: [DisplayRow] { pinnedRows + clipRows }
    var isEmpty: Bool { pinnedRows.isEmpty && clipRows.isEmpty }
    var count: Int { pinnedRows.count + clipRows.count }

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
        if isMultiSelecting {
            return "\(selectionRange.count) selected"
        }
        let n = count
        return "\(n) \(n == 1 ? "result" : "results")"
    }
}
