import Foundation

/// A user-authored fixed string. Permanent, manually ordered, never evicted,
/// always visible above history. An optional slot (1–9) binds it to a
/// Cmd+<n> shortcut so the most-used phrase is one keystroke, not a search.
struct Snippet: Identifiable, Codable, Equatable {
    let id: UUID
    var label: String?        // optional short label shown when content is long
    var content: String
    var slot: Int?            // 1...9, nil if unslotted
    var sortOrder: Int
    var createdAt: Date

    init(
        id: UUID = UUID(),
        label: String? = nil,
        content: String,
        slot: Int? = nil,
        sortOrder: Int,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.label = label
        self.content = content
        self.slot = slot
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }

    /// What to show as the row title: the label if set, otherwise the content.
    var title: String {
        if let label, !label.isEmpty { return label }
        return content.replacingOccurrences(of: "\n", with: "  ")
    }
}
