import Foundation
import VitalsClaude

/// Where a server definition comes from. Claude Code merges these scopes
/// per project; Vitals shows them side by side with the scope as a tag.
public enum MCPScope: Sendable, Hashable {
    /// `~/.claude.json` → `mcpServers`.
    case user
    /// `~/.claude.json` → `projects[path].mcpServers`.
    case local(project: String)
    /// `<project>/.mcp.json`, needs per-project approval.
    case project(project: String)
    /// `.mcp.json` inside an installed plugin. Claude names the server
    /// `plugin:<plugin>:<key>`.
    case plugin(name: String)

    public var label: String {
        switch self {
        case .user: "user"
        case .local: "local"
        case .project: "project"
        case .plugin: "plugin"
        }
    }

    /// The project this definition is bound to, if any.
    public var project: String? {
        switch self {
        case let .local(project), let .project(project): project
        case .user, .plugin: nil
        }
    }
}

public enum MCPTransport: Sendable, Equatable {
    case stdio(command: String, arguments: [String], environment: [String: String])
    case http(url: String, headers: [String: String])
    case sse(url: String, headers: [String: String])
    case other(type: String)

    public var summary: String {
        switch self {
        case let .stdio(command, arguments, _):
            ([command] + arguments).joined(separator: " ")
        case let .http(url, _): url
        case let .sse(url, _): url
        case let .other(type): type
        }
    }

    public var isProbeable: Bool {
        switch self {
        case .stdio, .http: true
        case .sse, .other: false
        }
    }
}

/// Per-project verdict on one server, mirroring what `/mcp` would show
/// inside a session started in that directory.
public enum MCPStatus: String, Sendable, Equatable {
    case enabled
    case disabled
    /// A `.mcp.json` server the user has not approved yet.
    case pendingApproval
    /// The plugin that provides it is switched off in settings.json.
    case pluginOff
}

public struct MCPServer: Sendable, Equatable, Identifiable {
    /// Exactly the name Claude Code uses (`qyl`, `plugin:playwright:playwright`).
    public let name: String
    public let scope: MCPScope
    public let transport: MCPTransport
    /// Where a stdio server is launched from: the project for project and
    /// local scopes, the plugin directory for plugins, home otherwise.
    public let workingDirectory: String?
    /// Status in every project Vitals was asked about, keyed by path.
    public let status: [String: MCPStatus]

    public var id: String { "\(scope.label):\(scope.project ?? scope.pluginName ?? ""):\(name)" }

    public init(name: String, scope: MCPScope, transport: MCPTransport, workingDirectory: String?, status: [String: MCPStatus]) {
        self.name = name
        self.scope = scope
        self.transport = transport
        self.workingDirectory = workingDirectory
        self.status = status
    }

    public var isEnabledAnywhere: Bool { status.values.contains(.enabled) }
    public var isEnabledEverywhere: Bool { !status.isEmpty && status.values.allSatisfy { $0 == .enabled } }
}

extension MCPScope {
    var pluginName: String? {
        if case let .plugin(name) = self { return name }
        return nil
    }
}

public struct MCPSnapshot: Sendable, Equatable {
    public let servers: [MCPServer]
    /// Projects the snapshot was evaluated for (live session cwds + home).
    public let projects: [String]
    public let capturedAt: Date

    public init(servers: [MCPServer], projects: [String], capturedAt: Date) {
        self.servers = servers
        self.projects = projects
        self.capturedAt = capturedAt
    }

    public static let empty = MCPSnapshot(servers: [], projects: [], capturedAt: .distantPast)
}

public enum MCPConfigError: Error, Equatable {
    case unreadable(String)
    case malformed(String)
}

/// Reads every place Claude Code looks for MCP servers and evaluates each
/// server for a set of projects. Pure with respect to its inputs: the file
/// contents are passed in by `load`, the parsing is `evaluate`.
public enum MCPConfigStore {
    public struct Inputs {
        /// Parsed `~/.claude.json`.
        public var claudeConfig: [String: Any]
        /// Parsed `~/.claude/settings.json`.
        public var settings: [String: Any]
        /// Parsed `installed_plugins.json`.
        public var installedPlugins: [String: Any]
        /// `<project>/.mcp.json` per project path, already parsed.
        public var projectFiles: [String: [String: Any]]
        /// Plugin `.mcp.json` per install path, already parsed.
        public var pluginFiles: [String: [String: Any]]

        public init(
            claudeConfig: [String: Any] = [:],
            settings: [String: Any] = [:],
            installedPlugins: [String: Any] = [:],
            projectFiles: [String: [String: Any]] = [:],
            pluginFiles: [String: [String: Any]] = [:]
        ) {
            self.claudeConfig = claudeConfig
            self.settings = settings
            self.installedPlugins = installedPlugins
            self.projectFiles = projectFiles
            self.pluginFiles = pluginFiles
        }
    }

    public static func load(
        home: ClaudeHome = ClaudeHome(),
        projects: [String],
        now: Date = Date()
    ) -> MCPSnapshot {
        let claudeConfig = readJSON(home.configFileURL)
        let settings = readJSON(home.settingsURL)
        let installed = readJSON(home.installedPluginsURL)
        var projectFiles: [String: [String: Any]] = [:]
        for project in projects {
            let file = URL(fileURLWithPath: project, isDirectory: true).appendingPathComponent(".mcp.json")
            let parsed = readJSON(file)
            if !parsed.isEmpty { projectFiles[project] = parsed }
        }
        var pluginFiles: [String: [String: Any]] = [:]
        for path in installPaths(installedPlugins: installed) {
            let parsed = readJSON(URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(".mcp.json"))
            if !parsed.isEmpty { pluginFiles[path] = parsed }
        }
        return evaluate(
            Inputs(
                claudeConfig: claudeConfig,
                settings: settings,
                installedPlugins: installed,
                projectFiles: projectFiles,
                pluginFiles: pluginFiles
            ),
            projects: projects,
            now: now
        )
    }

    public static func evaluate(_ inputs: Inputs, projects: [String], now: Date) -> MCPSnapshot {
        let projectStates = inputs.claudeConfig["projects"] as? [String: Any] ?? [:]
        let enabledPlugins = inputs.settings["enabledPlugins"] as? [String: Bool] ?? [:]
        var servers: [MCPServer] = []

        func status(_ name: String, in project: String, approvalRequired: Bool, pluginOn: Bool) -> MCPStatus {
            let state = projectStates[project] as? [String: Any] ?? [:]
            if !pluginOn { return .pluginOff }
            if (state["disabledMcpServers"] as? [String] ?? []).contains(name) { return .disabled }
            if approvalRequired {
                if (state["disabledMcpjsonServers"] as? [String] ?? []).contains(name) { return .disabled }
                if (state["enabledMcpjsonServers"] as? [String] ?? []).contains(name) { return .enabled }
                if state["enableAllProjectMcpServers"] as? Bool == true { return .enabled }
                return .pendingApproval
            }
            return .enabled
        }

        // User scope: applies to every project.
        for (name, raw) in inputs.claudeConfig["mcpServers"] as? [String: Any] ?? [:] {
            guard let definition = raw as? [String: Any] else { continue }
            servers.append(MCPServer(
                name: name,
                scope: .user,
                transport: transport(definition),
                workingDirectory: nil,
                status: Dictionary(uniqueKeysWithValues: projects.map {
                    ($0, status(name, in: $0, approvalRequired: false, pluginOn: true))
                })
            ))
        }

        // Local scope: defined inside one project's entry in ~/.claude.json.
        for project in projects {
            let state = projectStates[project] as? [String: Any] ?? [:]
            for (name, raw) in state["mcpServers"] as? [String: Any] ?? [:] {
                guard let definition = raw as? [String: Any] else { continue }
                servers.append(MCPServer(
                    name: name,
                    scope: .local(project: project),
                    transport: transport(definition),
                    workingDirectory: project,
                    status: [project: status(name, in: project, approvalRequired: false, pluginOn: true)]
                ))
            }
        }

        // Project scope: .mcp.json checked into the repo, approval gated.
        for (project, file) in inputs.projectFiles {
            for (name, raw) in file["mcpServers"] as? [String: Any] ?? file {
                guard let definition = raw as? [String: Any], definition["command"] != nil || definition["url"] != nil else { continue }
                servers.append(MCPServer(
                    name: name,
                    scope: .project(project: project),
                    transport: transport(definition),
                    workingDirectory: project,
                    status: [project: status(name, in: project, approvalRequired: true, pluginOn: true)]
                ))
            }
        }

        // Plugins: every installed plugin with a .mcp.json, named plugin:<plugin>:<key>.
        let plugins = inputs.installedPlugins["plugins"] as? [String: Any] ?? [:]
        for (qualified, raw) in plugins {
            guard let installs = raw as? [[String: Any]] else { continue }
            let pluginName = String(qualified.split(separator: "@").first ?? Substring(qualified))
            let pluginOn = enabledPlugins[qualified] ?? true
            var seen = Set<String>()
            for install in installs {
                guard let path = install["installPath"] as? String, let file = inputs.pluginFiles[path] else { continue }
                let scopedProjects: [String] = (install["projectPath"] as? String).map { [$0] } ?? projects
                for (key, raw) in file["mcpServers"] as? [String: Any] ?? file {
                    guard let definition = raw as? [String: Any], definition["command"] != nil || definition["url"] != nil else { continue }
                    let name = "plugin:\(pluginName):\(key)"
                    guard seen.insert(name).inserted else { continue }
                    servers.append(MCPServer(
                        name: name,
                        scope: .plugin(name: qualified),
                        transport: transport(definition),
                        workingDirectory: path,
                        status: Dictionary(uniqueKeysWithValues: scopedProjects.filter(projects.contains).map {
                            ($0, status(name, in: $0, approvalRequired: false, pluginOn: pluginOn))
                        })
                    ))
                }
            }
        }

        servers.sort { lhs, rhs in
            if lhs.isEnabledAnywhere != rhs.isEnabledAnywhere { return lhs.isEnabledAnywhere }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        return MCPSnapshot(servers: servers, projects: projects, capturedAt: now)
    }

    static func transport(_ definition: [String: Any]) -> MCPTransport {
        let type = (definition["type"] as? String)?.lowercased()
        if let url = definition["url"] as? String {
            let headers = definition["headers"] as? [String: String] ?? [:]
            return type == "sse" ? .sse(url: url, headers: headers) : .http(url: url, headers: headers)
        }
        if let command = definition["command"] as? String {
            return .stdio(
                command: command,
                arguments: definition["args"] as? [String] ?? [],
                environment: definition["env"] as? [String: String] ?? [:]
            )
        }
        return .other(type: type ?? "unknown")
    }

    static func installPaths(installedPlugins: [String: Any]) -> [String] {
        var paths: [String] = []
        for raw in (installedPlugins["plugins"] as? [String: Any] ?? [:]).values {
            for install in raw as? [[String: Any]] ?? [] {
                if let path = install["installPath"] as? String, !paths.contains(path) {
                    paths.append(path)
                }
            }
        }
        return paths
    }

    static func readJSON(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }
}
