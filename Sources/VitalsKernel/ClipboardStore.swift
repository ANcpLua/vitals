import CryptoKit
import Foundation
import VitalsCore

/// JSON under Application Support, owner-readable only. A missing or corrupt
/// file loads as empty: clipboard history is not worth a crash. Saves are
/// atomic. Copied images are PNG files in `clipboard-images/` named by their
/// digest; the JSON only references them.
public enum ClipboardStore {
    public static func url(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/Vitals/clipboard.json")
    }

    /// Image folder beside the given clipboard.json, so tests and the app
    /// derive it the same way.
    public static func imagesURL(for clipboard: URL = url()) -> URL {
        clipboard.deletingLastPathComponent().appendingPathComponent("clipboard-images")
    }

    public static func imageURL(digest: String, in folder: URL = imagesURL()) -> URL {
        folder.appendingPathComponent("\(digest).png")
    }

    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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

    /// Writes the PNG once and answers its digest. Re-copying the same image
    /// hits the existing file.
    @discardableResult
    public static func writeImage(_ data: Data, in folder: URL = imagesURL()) throws -> String {
        let digest = digest(data)
        let file = imageURL(digest: digest, in: folder)
        guard !FileManager.default.fileExists(atPath: file.path) else { return digest }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return digest
    }

    public static func imageData(digest: String, in folder: URL = imagesURL()) -> Data? {
        try? Data(contentsOf: imageURL(digest: digest, in: folder))
    }

    /// Deletes PNGs no entry references any more. Best effort: a file that
    /// refuses to go is a leftover, not a failure worth surfacing.
    public static func prune(keeping digests: Set<String>, in folder: URL = imagesURL()) {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "png" && !digests.contains(file.deletingPathExtension().lastPathComponent) {
            try? manager.removeItem(at: file)
        }
    }
}
