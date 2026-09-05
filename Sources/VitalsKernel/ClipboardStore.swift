import Foundation
import VitalsCore

/// JSON under Application Support, owner-readable only. A missing or corrupt
/// file loads as empty: clipboard history is not worth a crash. Saves are
/// atomic.
public enum ClipboardStore {
    public static func url(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/Vitals/clipboard.json")
    }

    public static func load(from url: URL = url()) -> ClipboardHistory {
        guard let data = try? Data(contentsOf: url) else { return .empty }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(ClipboardHistory.self, from: data)) ?? .empty
    }

    public static func save(_ history: ClipboardHistory, to url: URL = url()) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(history).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
