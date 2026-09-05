import Foundation

public struct MCPTool: Sendable, Equatable, Codable {
    public let name: String
    public let description: String

    public init(name: String, description: String) {
        self.name = name
        self.description = description
    }
}

public enum MCPText {
    public static let separator = "  ·  "

    /// The name Claude Code exposes a server tool under: `mcp__<server>__<tool>`
    /// with every character outside `[A-Za-z0-9_-]` in the server name turned
    /// into `_` (`plugin:playwright:playwright` → `plugin_playwright_playwright`).
    public static func callableName(server: String, tool: String) -> String {
        "mcp__\(sanitized(server))__\(tool)"
    }

    public static func sanitized(_ server: String) -> String {
        String(server.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
    }

    /// One line per server: name, scope, status per project, transport,
    /// then the callable tool names, ready to paste into a prompt.
    public static func line(_ server: MCPServer, tools: [MCPTool]?) -> String {
        var parts = [server.name, server.scope.label, statusSummary(server), server.transport.summary]
        if let tools {
            parts.append(tools.isEmpty
                ? "no tools"
                : tools.map { callableName(server: server.name, tool: $0.name) }.joined(separator: ", "))
        } else {
            parts.append("tools not probed")
        }
        return parts.joined(separator: separator)
    }

    public static func lines(_ servers: [MCPServer], tools: [String: [MCPTool]]) -> String {
        servers.map { line($0, tools: tools[$0.name]) + "\n" }.joined()
    }

    /// `ToolSearch` query that loads every tool of one server in one call.
    public static func toolSearchQuery(server: MCPServer, tools: [MCPTool]) -> String {
        "select:" + tools.map { callableName(server: server.name, tool: $0.name) }.joined(separator: ",")
    }

    public static func statusSummary(_ server: MCPServer) -> String {
        let states = Set(server.status.values)
        if states.isEmpty { return "no project" }
        if states.count == 1, let only = states.first { return only.rawValue }
        let enabled = server.status.values.filter { $0 == .enabled }.count
        return "enabled in \(enabled)/\(server.status.count)"
    }
}
