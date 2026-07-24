import AppKit
import SwiftUI

/// A single row rendered in the picker — either a pinned snippet or a clipboard
/// history item, flattened to what the view needs to draw.
struct DisplayRow: Identifiable {
    enum Kind { case pinned, clip }

    let id: String
    let kind: Kind
    let text: String         // the single line shown: exactly what gets pasted
    let slot: Int?           // pinned slot for the ⌘n badge
    let image: NSImage?      // clip thumbnail

    // Backing data for the action layer.
    let snippet: Snippet?
    let clip: ClipboardItem?

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
    @Published var selection: Int = 0
    @Published var pinnedRows: [DisplayRow] = []
    @Published var clipRows: [DisplayRow] = []
    @Published var accessibilityTrusted: Bool = true

    /// Set true when a selection change comes from the mouse hovering a row, so
    /// the list does not auto-scroll to re-center under the pointer. Consumed and
    /// cleared by the list's onChange handler. Keyboard navigation leaves this
    /// false and scrolls the selection into view as before.
    var suppressAutoScroll: Bool = false

    var allRows: [DisplayRow] { pinnedRows + clipRows }
    var isEmpty: Bool { pinnedRows.isEmpty && clipRows.isEmpty }
    var count: Int { pinnedRows.count + clipRows.count }

    /// The currently highlighted row, if any — drives the preview pane.
    var selectedRow: DisplayRow? {
        let rows = allRows
        guard selection >= 0, selection < rows.count else { return nil }
        return rows[selection]
    }

    var countLabel: String {
        let n = count
        return "\(n) \(n == 1 ? "result" : "results")"
    }
}
