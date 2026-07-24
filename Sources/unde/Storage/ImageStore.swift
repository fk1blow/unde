import AppKit
import CryptoKit

/// Content-addressed store for captured images. Files are named by the SHA-256
/// of their bytes and written as PNG under Application Support, so identical
/// images dedupe to one file on disk and the database only carries the path,
/// dimensions and size (STO-3).
final class ImageStore {
    private let directory: URL

    init() {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("unde/images", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        self.directory = support
    }

    private func url(forHash hash: String) -> URL {
        directory.appendingPathComponent("\(hash).png")
    }

    /// Persist image data as PNG keyed by hash. Returns the relative filename to
    /// store in the database. Skips the write if the file already exists.
    @discardableResult
    func save(data: Data, hash: String) -> String {
        let url = url(forHash: hash)
        if !FileManager.default.fileExists(atPath: url.path) {
            // Normalise to PNG regardless of the source representation.
            if let image = NSImage(data: data), let png = image.pngData() {
                try? png.write(to: url, options: .atomic)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
        return "\(hash).png"
    }

    func loadImage(path: String) -> NSImage? {
        NSImage(contentsOf: directory.appendingPathComponent(path))
    }

    func delete(path: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(path))
    }
}

extension NSImage {
    /// PNG encoding of the image's best bitmap representation.
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
