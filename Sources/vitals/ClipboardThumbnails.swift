import AppKit
import VitalsCore
import VitalsKernel

/// Thumbnails for copied images, decoded once per digest. The panel rebuilds
/// its rows on every keystroke, so decoding a PNG per row is not an option.
@MainActor
enum ClipboardThumbnails {
    static let maxWidth: CGFloat = 96
    static let maxHeight: CGFloat = 44
    private static var cache: [String: NSImage] = [:]

    static func thumbnail(for image: ClipboardImage) -> NSImage? {
        if let hit = cache[image.digest] { return hit }
        guard let data = ClipboardStore.imageData(digest: image.digest),
              let source = NSImage(data: data)
        else { return nil }
        let width = CGFloat(max(1, image.width))
        let height = CGFloat(max(1, image.height))
        let one: CGFloat = 1
        let scale = min(maxWidth / width, maxHeight / height, one)
        let size = NSSize(width: max(one, width * scale), height: max(one, height * scale))
        let thumbnail = NSImage(size: size)
        thumbnail.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: one)
        thumbnail.unlockFocus()
        cache[image.digest] = thumbnail
        return thumbnail
    }

    /// Drops thumbnails for images the history no longer holds.
    static func forget(except digests: Set<String>) {
        cache = cache.filter { digests.contains($0.key) }
    }
}
