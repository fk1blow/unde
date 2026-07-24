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
    let image: NSImage?       // in-memory image (fresh capture), nil once persisted
    let imagePath: String?    // on-disk filename for a persisted image, else nil
    let imageWidth: Int?
    let imageHeight: Int?
    let byteSize: Int
    let sourceBundleID: String?
    var createdAt: Date

    static func == (lhs: ClipboardItem, rhs: ClipboardItem) -> Bool {
        lhs.id == rhs.id
    }

    /// The image to render: the in-memory copy if present, else loaded lazily
    /// from disk. Loading is left to the caller's `ImageStore`.
    func resolvedImage(using store: ImageStore?) -> NSImage? {
        if let image { return image }
        if let imagePath { return store?.loadImage(path: imagePath) }
        return nil
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

    /// The primary single-line label shown in a picker row. Text items show their
    /// preview; images have no filename (they're stored under a content hash), so
    /// the primary label is just "Image" with the details carried in `rowMeta`.
    var rowLabel: String {
        switch kind {
        case .text:  return preview
        case .image: return "Image"
        }
    }

    /// Faded, secondary metadata shown after `rowLabel` — dimensions and size for
    /// images, nil for text.
    var rowMeta: String? {
        guard kind == .image else { return nil }
        var parts: [String] = []
        if let w = imageWidth, let h = imageHeight, w > 0, h > 0 {
            parts.append("\(w) × \(h)")
        }
        if byteSize > 0 {
            parts.append(Self.formattedByteSize(byteSize))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func formattedByteSize(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    /// A short human classification shown in the row meta line.
    var classification: String {
        guard kind == .text, let t = text else { return "image" }
        if t.hasPrefix("http://") || t.hasPrefix("https://") { return "link" }
        // Check date and email before the generic code pattern, which would
        // otherwise swallow an ISO date (all digits and dashes).
        if t.range(of: "^\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression) != nil { return "date" }
        if t.contains("@"), !t.contains(" "), t.contains(".") { return "email" }
        if t.range(of: "^[A-Z0-9][A-Z0-9\\-_]{3,}$", options: .regularExpression) != nil { return "code" }
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
            imagePath: nil,
            imageWidth: nil,
            imageHeight: nil,
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
            imagePath: nil,
            imageWidth: Int(image.size.width),
            imageHeight: Int(image.size.height),
            byteSize: data.count,
            sourceBundleID: source,
            createdAt: date
        )
    }

    /// Reconstruct an item loaded from the database. The image itself is loaded
    /// lazily from `imagePath` via `resolvedImage(using:)`.
    static func persisted(
        hash: String,
        kind: Kind,
        text: String?,
        imagePath: String?,
        imageWidth: Int?,
        imageHeight: Int?,
        byteSize: Int,
        source: String?,
        createdAt: Date
    ) -> ClipboardItem {
        ClipboardItem(
            id: hash,
            kind: kind,
            text: text,
            image: nil,
            imagePath: imagePath,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            byteSize: byteSize,
            sourceBundleID: source,
            createdAt: createdAt
        )
    }

    static func hash(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
