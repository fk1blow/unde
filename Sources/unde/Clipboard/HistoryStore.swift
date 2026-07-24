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

    /// Supplies the current retention cutoff, or nil when retention is off
    /// ("Forever"). Injected by the owner so the store stays free of a
    /// `Preferences` dependency. Defaults to "never expire".
    var retentionCutoff: () -> Date? = { nil }

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
        // Prune anything that has aged out before adding — the "you're actively
        // copying, so the pass runs" path (RET-5). The fresh item is never caught.
        evictExpired()
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

    /// Remove several items at once (multi-select delete). Mutates the in-memory
    /// list a single time so the UI refreshes once, then mirrors each removal to
    /// disk — `delete(hash:)` also cleans up any backing image file per item.
    func remove(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        items.removeAll { ids.contains($0.id) }
        ids.forEach { repository?.delete(hash: $0) }
    }

    /// Drop items older than the retention window (RET-3), both in memory and on
    /// disk. No-op when retention is off. Only republishes `items` when something
    /// actually changed, so calling it on every insert costs no spurious UI refresh
    /// — and since the in-memory list is the newest `capacity` rows, an unchanged
    /// list means the on-disk set (trimmed to the same cap) has nothing older either.
    func evictExpired() {
        guard let cutoff = retentionCutoff() else { return }
        let survivors = items.filter { $0.createdAt >= cutoff }
        guard survivors.count != items.count else { return }
        items = survivors
        repository?.evict(olderThan: cutoff)
    }

    func clear() {
        items.removeAll()
        repository?.clear()
    }
}
