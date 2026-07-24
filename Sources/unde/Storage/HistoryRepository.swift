import Foundation

/// Persists clipboard history to SQLite. Dedup is enforced at the storage layer
/// by a UNIQUE index on `content_hash` plus an upsert that bumps `created_at`,
/// so re-copying an existing item moves it to the top for free (CAP-5).
final class HistoryRepository {

    private let db: SQLiteDatabase
    private let imageStore: ImageStore

    init(db: SQLiteDatabase, imageStore: ImageStore) {
        self.db = db
        self.imageStore = imageStore
        migrate()
    }

    private func migrate() {
        try? db.execute("""
            CREATE TABLE IF NOT EXISTS history_item (
                id            INTEGER PRIMARY KEY,
                kind          TEXT NOT NULL,
                content       TEXT,
                image_path    TEXT,
                image_width   INTEGER,
                image_height  INTEGER,
                byte_size     INTEGER NOT NULL,
                content_hash  TEXT NOT NULL,
                source_bundle TEXT,
                created_at    REAL NOT NULL,
                last_used_at  REAL
            );
            """)
        try? db.execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_history_hash ON history_item(content_hash);")
        try? db.execute("CREATE INDEX IF NOT EXISTS idx_history_created ON history_item(created_at DESC);")
    }

    // MARK: Reads

    func loadRecent(limit: Int) -> [ClipboardItem] {
        (try? db.query("""
            SELECT kind, content, image_path, image_width, image_height,
                   byte_size, content_hash, source_bundle, created_at
            FROM history_item ORDER BY created_at DESC LIMIT ?;
            """, [.int(Int64(limit))]) { row -> ClipboardItem in
                let kind: ClipboardItem.Kind
                switch row.text(0) {
                case "image": kind = .image
                case "file":  kind = .file
                default:      kind = .text
                }
                return ClipboardItem.persisted(
                    hash: row.text(6) ?? "",
                    kind: kind,
                    text: row.text(1),
                    imagePath: row.text(2),
                    imageWidth: row.int(3),
                    imageHeight: row.int(4),
                    byteSize: row.int(5) ?? 0,
                    source: row.text(7),
                    createdAt: Date(timeIntervalSince1970: row.double(8) ?? 0)
                )
            }) ?? []
    }

    // MARK: Writes

    func upsert(_ item: ClipboardItem) {
        try? db.execute("""
            INSERT INTO history_item
                (kind, content, image_path, image_width, image_height,
                 byte_size, content_hash, source_bundle, created_at, last_used_at)
            VALUES (?,?,?,?,?,?,?,?,?,NULL)
            ON CONFLICT(content_hash) DO UPDATE SET created_at = excluded.created_at;
            """, [
                .text(Self.kindString(item.kind)),
                .textOrNull(item.text),
                .textOrNull(item.imagePath),
                .intOrNull(item.imageWidth),
                .intOrNull(item.imageHeight),
                .int(Int64(item.byteSize)),
                .text(item.id),
                .textOrNull(item.sourceBundleID),
                .double(item.createdAt.timeIntervalSince1970),
            ])
    }

    func delete(hash: String) {
        // Remove the backing image file first, if any.
        if let path = imagePath(forHash: hash) {
            imageStore.delete(path: path)
        }
        try? db.execute("DELETE FROM history_item WHERE content_hash = ?;", [.text(hash)])
    }

    func clear() {
        for path in allImagePaths() {
            imageStore.delete(path: path)
        }
        try? db.execute("DELETE FROM history_item;")
    }

    /// Evict everything beyond the newest `capacity` rows, cleaning up their
    /// image files (STO-2).
    func evict(keeping capacity: Int) {
        let doomed = (try? db.query("""
            SELECT image_path FROM history_item
            ORDER BY created_at DESC LIMIT -1 OFFSET ?;
            """, [.int(Int64(capacity))]) { $0.text(0) }) ?? []
        for path in doomed.compactMap({ $0 }) {
            imageStore.delete(path: path)
        }
        try? db.execute("""
            DELETE FROM history_item WHERE content_hash IN (
                SELECT content_hash FROM history_item
                ORDER BY created_at DESC LIMIT -1 OFFSET ?
            );
            """, [.int(Int64(capacity))])
    }

    /// Evict every item older than `cutoff`, cleaning up their image files (RET-3).
    /// The age sibling of `evict(keeping:)`; `created_at` is indexed, so the scan
    /// is cheap even at the 2000-item ceiling.
    func evict(olderThan cutoff: Date) {
        let ts = cutoff.timeIntervalSince1970
        let doomed = (try? db.query(
            "SELECT image_path FROM history_item WHERE created_at < ?;",
            [.double(ts)]) { $0.text(0) }) ?? []
        for path in doomed.compactMap({ $0 }) {
            imageStore.delete(path: path)
        }
        try? db.execute("DELETE FROM history_item WHERE created_at < ?;", [.double(ts)])
    }

    // MARK: Helpers

    private static func kindString(_ kind: ClipboardItem.Kind) -> String {
        switch kind {
        case .image: return "image"
        case .file:  return "file"
        case .text:  return "text"
        }
    }

    private func imagePath(forHash hash: String) -> String? {
        (try? db.query("SELECT image_path FROM history_item WHERE content_hash = ?;",
                       [.text(hash)]) { $0.text(0) })?.first ?? nil
    }

    private func allImagePaths() -> [String] {
        ((try? db.query("SELECT image_path FROM history_item WHERE image_path IS NOT NULL;",
                        []) { $0.text(0) }) ?? []).compactMap { $0 }
    }
}
