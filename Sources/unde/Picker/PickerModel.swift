import AppKit
import SwiftUI

/// A single row rendered in the picker — either a pinned snippet or a clipboard
/// history item, flattened to what the view needs to draw.
struct DisplayRow: Identifiable {
    enum Kind { case pinned, clip }

    let id: String
    let kind: Kind
    let title: String        // snippet label / clip preview (first line)
    let subtitle: String?    // snippet content preview
    let meta: String?        // clip meta line ("Copied 2m ago · code")
    let slot: Int?           // pinned slot for the ⌘n badge
    let image: NSImage?      // clip thumbnail

    // Backing data for the action layer.
    let snippet: Snippet?
    let clip: ClipboardItem?
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

    var allRows: [DisplayRow] { pinnedRows + clipRows }
    var isEmpty: Bool { pinnedRows.isEmpty && clipRows.isEmpty }
    var count: Int { pinnedRows.count + clipRows.count }

    var countLabel: String {
        let n = count
        return "\(n) \(n == 1 ? "result" : "results")"
    }
}
