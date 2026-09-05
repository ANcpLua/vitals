import Foundation

/// Resolves the Claude Code configuration directory and the well-known files
/// inside it. Every reader of `~/.claude` goes through this type so a future
/// feature (settings.json, keybindings, daemon roster, cron jobs, …) adds a
/// property here instead of re-deriving the path.
public struct ClaudeHome: Sendable, Equatable {
    public let root: URL

    /// Honors `CLAUDE_CONFIG_DIR` the same way Claude Code does; otherwise
    /// `~/.claude`.
    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        if let override = environment["CLAUDE_CONFIG_DIR"], !override.isEmpty {
            root = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            root = homeDirectory.appendingPathComponent(".claude", isDirectory: true)
        }
    }

    public init(root: URL) {
        self.root = root
    }

    /// One `<pid>.json` per running local Claude Code process.
    public var sessionsDirectory: URL {
        root.appendingPathComponent("sessions", isDirectory: true)
    }

    public var settingsURL: URL {
        root.appendingPathComponent("settings.json")
    }

    /// `~/.claude.json`: user-scope MCP servers, per-project MCP state, OAuth
    /// bookkeeping. Lives next to `~/.claude`, or inside `CLAUDE_CONFIG_DIR`
    /// when that override is set, mirroring Claude Code.
    public var configFileURL: URL {
        if root.lastPathComponent == ".claude" {
            return root.deletingLastPathComponent().appendingPathComponent(".claude.json")
        }
        return root.appendingPathComponent(".claude.json")
    }

    public var pluginsDirectory: URL {
        root.appendingPathComponent("plugins", isDirectory: true)
    }

    public var installedPluginsURL: URL {
        pluginsDirectory.appendingPathComponent("installed_plugins.json")
    }

    public var daemonRosterURL: URL {
        root.appendingPathComponent("daemon", isDirectory: true)
            .appendingPathComponent("roster.json")
    }
}
