import AppKit
import VitalsCore
import VitalsKernel

/// Polls the general pasteboard. macOS has no change notification, so every
/// clipboard manager does this; 0.5 s costs nothing measurable. Text wins
/// when a write carries both, otherwise a copied image is kept as a PNG.
@MainActor
final class ClipboardMonitor {
    private(set) var history: ClipboardHistory
    private(set) var lastError: String?
    private var changeCount: Int
    var onChange: (@MainActor () -> Void)?

    init() {
        history = ClipboardStore.load()
        changeCount = NSPasteboard.general.changeCount
        ClipboardStore.prune(keeping: history.imageDigests)
    }

    func start() {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                self.poll()
            }
        }
    }

    func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != changeCount else { return }
        changeCount = pasteboard.changeCount
        let types = (pasteboard.types ?? []).map(\.rawValue)
        guard ClipboardHistory.records(types: types) else { return }
        if let text = pasteboard.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            update(history.adding(text, at: Date()))
            return
        }
        guard let picture = ClipboardPicture(pasteboard: pasteboard) else { return }
        record(picture)
    }

    /// Puts an entry back on the pasteboard and moves it to the top. The
    /// change count is taken right after the write so the poll skips it.
    func copy(_ entry: ClipboardEntry) {
        let pasteboard = NSPasteboard.general
        if let image = entry.image {
            guard let data = ClipboardStore.imageData(digest: image.digest) else {
                lastError = "clipboard image \(image.digest.prefix(8)) is gone"
                onChange?()
                return
            }
            pasteboard.clearContents()
            pasteboard.setData(data, forType: .png)
            if let tiff = NSBitmapImageRep(data: data)?.tiffRepresentation {
                pasteboard.setData(tiff, forType: .tiff)
            }
            changeCount = pasteboard.changeCount
            update(history.adding(image, at: Date()))
            return
        }
        pasteboard.clearContents()
        pasteboard.setString(entry.text, forType: .string)
        changeCount = pasteboard.changeCount
        update(history.adding(entry.text, at: Date()))
    }

    func clear() {
        update(.empty)
    }

    private func record(_ picture: ClipboardPicture) {
        guard ClipboardHistory.records(imageBytes: picture.png.count) else { return }
        do {
            let digest = try ClipboardStore.writeImage(picture.png)
            update(history.adding(
                ClipboardImage(digest: digest, width: picture.width, height: picture.height, bytes: picture.png.count),
                at: Date()
            ))
        } catch {
            lastError = "clipboard image: \(error.localizedDescription)"
            onChange?()
        }
    }

    private func update(_ next: ClipboardHistory) {
        guard next != history else { return }
        history = next
        do {
            try ClipboardStore.save(next)
            lastError = nil
        } catch {
            lastError = "clipboard.json: \(error.localizedDescription)"
        }
        ClipboardStore.prune(keeping: next.imageDigests)
        ClipboardThumbnails.forget(except: next.imageDigests)
        onChange?()
    }
}

/// A pasteboard image normalized to PNG. TIFF and the odd bitmap flavours
/// all arrive here; one format on disk keeps the panel and the store simple.
struct ClipboardPicture {
    let png: Data
    let width: Int
    let height: Int

    init?(pasteboard: NSPasteboard) {
        let candidates: [NSPasteboard.PasteboardType] = [.png, .tiff]
        guard let type = candidates.first(where: { pasteboard.data(forType: $0) != nil }),
              let data = pasteboard.data(forType: type),
              let rep = NSBitmapImageRep(data: data)
        else { return nil }
        guard let png = type == .png ? data : rep.representation(using: .png, properties: [:]) else { return nil }
        self.png = png
        width = rep.pixelsWide
        height = rep.pixelsHigh
    }
}
