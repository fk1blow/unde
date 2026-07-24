import Foundation
import Combine

/// Persistent store of pinned snippets. Backed by a single JSON file in
/// Application Support — a handful of short strings that must survive relaunch.
/// (History, which is larger and churns, moves to SQLite at M6; snippets are
/// small and human-editable, so a plain file is the right weight here.)
final class SnippetStore: ObservableObject {
    @Published private(set) var snippets: [Snippet] = []

    private let fileURL: URL

    init() {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("unde", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        self.fileURL = support.appendingPathComponent("snippets.json")

        load()
        if snippets.isEmpty {
            seed()
        }
    }

    /// Snippets in display order (by explicit sortOrder).
    var ordered: [Snippet] {
        snippets.sorted { $0.sortOrder < $1.sortOrder }
    }

    func snippet(forSlot slot: Int) -> Snippet? {
        snippets.first { $0.slot == slot }
    }

    // MARK: Mutation

    func add(_ snippet: Snippet) {
        snippets.append(snippet)
        save()
    }

    func update(_ snippet: Snippet) {
        guard let idx = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        snippets[idx] = snippet
        save()
    }

    func delete(id: UUID) {
        snippets.removeAll { $0.id == id }
        save()
    }

    /// Promote arbitrary text (typically a selected history item) to a snippet,
    /// assigning the lowest free slot 1–9 if one is available (SNP-1).
    @discardableResult
    func promote(text: String, label: String? = nil) -> Snippet {
        let nextOrder = (snippets.map(\.sortOrder).max() ?? -1) + 1
        let snippet = Snippet(
            label: label,
            content: text,
            slot: lowestFreeSlot(),
            sortOrder: nextOrder
        )
        add(snippet)
        return snippet
    }

    func lowestFreeSlot() -> Int? {
        let used = Set(snippets.compactMap(\.slot))
        return (1...9).first { !used.contains($0) }
    }

    /// Reassign sortOrder to match a new ordering of ids.
    func reorder(_ orderedIDs: [UUID]) {
        for (index, id) in orderedIDs.enumerated() {
            if let i = snippets.firstIndex(where: { $0.id == id }) {
                snippets[i].sortOrder = index
            }
        }
        save()
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? JSONDecoder().decode([Snippet].self, from: data) {
            snippets = decoded
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(snippets) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// First-run seed matching the PRD's canonical construction-correspondence
    /// use case, so the app is useful the moment it launches.
    private func seed() {
        let seeds: [(String?, String, Int)] = [
            ("Master Schedule of Works", "Master Schedule of Works", 1),
            ("MoW — full reference line", "the Master Schedule of Works (MoW), Rev. ___, dated __/__/____", 2),
            ("RFI closing line", "Please advise at your earliest convenience to avoid impact to the Master Schedule of Works.", 3),
            ("Variation order intro", "Further to the approved Variation Order, the following amendment applies to the Master Schedule of Works:", 4),
            ("Practical Completion", "Practical Completion is targeted in accordance with the current Master Schedule of Works.", 5),
            ("Email sign-off", "Kind regards,\nJ. Okafor\nProject Controls — Site Delivery", 6),
        ]
        snippets = seeds.enumerated().map { index, seed in
            Snippet(label: seed.0, content: seed.1, slot: seed.2, sortOrder: index)
        }
        save()
    }
}
