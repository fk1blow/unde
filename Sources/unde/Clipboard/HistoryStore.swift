import AppKit
import Combine

/// The in-memory history of captured pasteboard items, newest-first. In v1 this
/// is the single source of truth for history; persistence is layered on later
/// (M6) without changing this interface. Filtering runs against `items`, never a
/// database, to stay inside the per-keystroke budget.
final class HistoryStore: ObservableObject {
    @Published private(set) var items: [ClipboardItem] = []

    private let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
    }

    /// Insert a freshly-captured item. Deduplicates by content hash: re-copying
    /// an existing item moves it to the top rather than adding a duplicate row
    /// (CAP-5). Evicts the oldest beyond the cap (STO-2).
    func insert(_ item: ClipboardItem) {
        if let existing = items.firstIndex(where: { $0.id == item.id }) {
            var bumped = items.remove(at: existing)
            bumped.createdAt = item.createdAt
            items.insert(bumped, at: 0)
        } else {
            items.insert(item, at: 0)
            if items.count > capacity {
                items.removeLast(items.count - capacity)
            }
        }
    }

    func remove(id: String) {
        items.removeAll { $0.id == id }
    }

    func clear() {
        items.removeAll()
    }
}
