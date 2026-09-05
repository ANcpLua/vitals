import Foundation

/// What the last probe of a server returned. Kept on disk so the menu can
/// show tool lists immediately after a restart without relaunching servers.
public struct MCPProbeRecord: Sendable, Equatable, Codable {
    public let tools: [MCPTool]
    public let error: String?
    public let probedAt: Date

    public init(tools: [MCPTool], error: String?, probedAt: Date) {
        self.tools = tools
        self.error = error
        self.probedAt = probedAt
    }
}

public struct MCPToolCache: Sendable, Equatable, Codable {
    /// Keyed by server name.
    public var records: [String: MCPProbeRecord]

    public init(records: [String: MCPProbeRecord] = [:]) {
        self.records = records
    }

    public var tools: [String: [MCPTool]] {
        records.compactMapValues { $0.error == nil ? $0.tools : nil }
    }

    public var toolCount: Int {
        tools.values.reduce(0) { $0 + $1.count }
    }

    public static func defaultURL(
        caches: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    ) -> URL {
        caches.appendingPathComponent("dev.ancplua.vitals", isDirectory: true)
            .appendingPathComponent("mcp-tools.json")
    }

    public static func load(from url: URL = defaultURL()) -> MCPToolCache {
        guard let data = try? Data(contentsOf: url) else { return MCPToolCache() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(MCPToolCache.self, from: data)) ?? MCPToolCache()
    }

    public func save(to url: URL = defaultURL()) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
