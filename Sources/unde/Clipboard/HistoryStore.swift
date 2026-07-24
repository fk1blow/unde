import AppKit
import Combine

/// The history of captured pasteboard items, newest-first. The in-memory `items`
/// array is the source of truth for the UI and for filtering (which must run in
/// memory to stay inside the per-keystroke budget); it is mirrored to a SQLite
/// repository so history survives quit and relaunch (STO-1).
final class HistoryStore: ObservableObject {
    @Published private(set) var items: [ClipboardItem] = []

    private let capacity: Int
    private let repository: HistoryRepository?

    init(capacity: Int, repository: HistoryRepository? = nil) {
        self.capacity = capacity
        self.repository = repository
        // Warm the in-memory list from disk at launch.
        if let repository {
            items = repository.loadRecent(limit: capacity)
        }
    }

    /// Insert a freshly-captured item. Deduplicates by content hash: re-copying
    /// an existing item moves it to the top rather than adding a duplicate row
    /// (CAP-5). Evicts the oldest beyond the cap (STO-2). Mirrors both to disk.
    func insert(_ item: ClipboardItem) {
        if let existing = items.firstIndex(where: { $0.id == item.id }) {
            var bumped = items.remove(at: existing)
            bumped.createdAt = item.createdAt
            items.insert(bumped, at: 0)
            repository?.upsert(bumped)
        } else {
            items.insert(item, at: 0)
            repository?.upsert(item)
            if items.count > capacity {
                items.removeLast(items.count - capacity)
                repository?.evict(keeping: capacity)
            }
        }
    }

    func remove(id: String) {
        items.removeAll { $0.id == id }
        repository?.delete(hash: id)
    }

    func clear() {
        items.removeAll()
        repository?.clear()
    }
}
