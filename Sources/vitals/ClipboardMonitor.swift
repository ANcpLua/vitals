import AppKit
import VitalsCore
import VitalsKernel

/// Polls the general pasteboard. macOS has no change notification, so every
/// clipboard manager does this; 0.5 s costs nothing measurable. Text only.
@MainActor
final class ClipboardMonitor {
    private(set) var history: ClipboardHistory
    private(set) var lastError: String?
    private var changeCount: Int
    var onChange: (@MainActor () -> Void)?

    init() {
        history = ClipboardStore.load()
        changeCount = NSPasteboard.general.changeCount
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
        guard ClipboardHistory.records(types: types),
              let text = pasteboard.string(forType: .string)
        else { return }
        update(history.adding(text, at: Date()))
    }

    /// Puts an entry back on the pasteboard and moves it to the top. The
    /// change count is taken right after the write so the poll skips it.
    func copy(_ entry: ClipboardEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.text, forType: .string)
        changeCount = pasteboard.changeCount
        update(history.adding(entry.text, at: Date()))
    }

    func clear() {
        update(.empty)
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
        onChange?()
    }
}
