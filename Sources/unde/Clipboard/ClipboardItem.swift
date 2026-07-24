import AppKit
import CryptoKit

/// A captured pasteboard entry. Ephemeral by nature: newest-first, capped,
/// evictable. Kept deliberately separate from `Snippet`, which is permanent.
struct ClipboardItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case text
        case image
    }

    let id: String            // content hash — also the dedup key
    let kind: Kind
    let text: String?         // text payload, nil for images
    let image: NSImage?       // in-memory image, nil for text
    let byteSize: Int
    let sourceBundleID: String?
    var createdAt: Date

    static func == (lhs: ClipboardItem, rhs: ClipboardItem) -> Bool {
        lhs.id == rhs.id
    }

    /// A single-line preview suitable for a row, collapsing whitespace.
    var preview: String {
        switch kind {
        case .image:
            return "Image"
        case .text:
            let collapsed = (text ?? "")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return collapsed
        }
    }

    /// A short human classification shown in the row meta line.
    var classification: String {
        guard kind == .text, let t = text else { return "image" }
        if t.hasPrefix("http://") || t.hasPrefix("https://") { return "link" }
        if t.range(of: "^[A-Z0-9][A-Z0-9\\-_]{3,}$", options: .regularExpression) != nil { return "code" }
        if t.range(of: "^\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression) != nil { return "date" }
        if t.contains("@"), !t.contains(" "), t.contains(".") { return "email" }
        return "text"
    }

    // MARK: Factory helpers

    static func text(_ string: String, source: String?, at date: Date = Date()) -> ClipboardItem {
        let hash = Self.hash(of: Data(string.utf8))
        return ClipboardItem(
            id: hash,
            kind: .text,
            text: string,
            image: nil,
            byteSize: string.utf8.count,
            sourceBundleID: source,
            createdAt: date
        )
    }

    static func image(_ image: NSImage, data: Data, source: String?, at date: Date = Date()) -> ClipboardItem {
        let hash = Self.hash(of: data)
        return ClipboardItem(
            id: hash,
            kind: .image,
            text: nil,
            image: image,
            byteSize: data.count,
            sourceBundleID: source,
            createdAt: date
        )
    }

    static func hash(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
