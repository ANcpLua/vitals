import Foundation
import VitalsClaude

/// Enables or disables one server for one project by editing the
/// `disabledMcpServers` (and, for `.mcp.json` servers, the
/// `enabledMcpjsonServers` / `disabledMcpjsonServers`) arrays under
/// `projects[path]` in `~/.claude.json`, which is exactly what Claude Code's
/// own `/mcp` screen writes. Running sessions keep the server set they
/// started with; the next session in that project picks the change up.
public enum MCPToggle {
    public enum Change: Sendable, Equatable {
        case enable
        case disable
    }

    /// Pure: returns the updated top-level config object.
    public static func apply(
        _ change: Change,
        server: MCPServer,
        project: String,
        to config: [String: Any]
    ) -> [String: Any] {
        var config = config
        var projects = config["projects"] as? [String: Any] ?? [:]
        var state = projects[project] as? [String: Any] ?? [:]

        var disabled = state["disabledMcpServers"] as? [String] ?? []
        disabled.removeAll { $0 == server.name }
        if change == .disable, !isProjectFile(server) {
            disabled.append(server.name)
        }
        state["disabledMcpServers"] = disabled

        if isProjectFile(server) {
            var approved = state["enabledMcpjsonServers"] as? [String] ?? []
            var rejected = state["disabledMcpjsonServers"] as? [String] ?? []
            approved.removeAll { $0 == server.name }
            rejected.removeAll { $0 == server.name }
            if change == .enable { approved.append(server.name) } else { rejected.append(server.name) }
            state["enabledMcpjsonServers"] = approved
            state["disabledMcpjsonServers"] = rejected
        }

        projects[project] = state
        config["projects"] = projects
        return config
    }

    /// Reads, edits and atomically rewrites the config file. A one-time
    /// `.claude.json.vitals-backup` sits next to it before the first write.
    public static func write(
        _ change: Change,
        server: MCPServer,
        project: String,
        home: ClaudeHome = ClaudeHome()
    ) throws {
        let url = home.configFileURL
        let data = try Data(contentsOf: url)
        guard let config = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPConfigError.malformed(url.path)
        }
        let backup = url.deletingLastPathComponent().appendingPathComponent(".claude.json.vitals-backup")
        if !FileManager.default.fileExists(atPath: backup.path) {
            try data.write(to: backup)
        }
        let updated = apply(change, server: server, project: project, to: config)
        let output = try JSONSerialization.data(withJSONObject: updated, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let temp = url.deletingLastPathComponent().appendingPathComponent(".claude.json.vitals-\(getpid())")
        try output.write(to: temp)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
    }

    static func isProjectFile(_ server: MCPServer) -> Bool {
        if case .project = server.scope { return true }
        return false
    }
}
