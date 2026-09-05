import Foundation
import VitalsClaude
import VitalsMCP

var failures: [String] = []

@MainActor
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { failures.append(message) }
}

func json(_ text: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
}

let home = "/Users/x"
let workspace = "/Users/x/work"
let pluginPath = "/Users/x/.claude/plugins/cache/official/playwright/abc"

let inputs = MCPConfigStore.Inputs(
    claudeConfig: json("""
    {
      "mcpServers": {"global-http": {"type": "http", "url": "https://mcp.example/mcp", "headers": {"Authorization": "Bearer x"}}},
      "projects": {
        "\(home)": {"mcpServers": {}, "disabledMcpServers": ["plugin:playwright:playwright"], "enabledMcpjsonServers": [], "disabledMcpjsonServers": []},
        "\(workspace)": {"mcpServers": {"local-stdio": {"type": "stdio", "command": "npx", "args": ["-y", "some-server"], "env": {"TOKEN": "${TOKEN:-none}"}}},
                          "disabledMcpServers": ["global-http"], "enabledMcpjsonServers": [], "disabledMcpjsonServers": []}
      }
    }
    """),
    settings: json(#"{"enabledPlugins": {"playwright@official": true, "terraform@official": false}}"#),
    installedPlugins: json("""
    {"version": 2, "plugins": {
      "playwright@official": [{"scope": "user", "installPath": "\(pluginPath)"}],
      "terraform@official": [{"scope": "project", "projectPath": "\(workspace)", "installPath": "/Users/x/.claude/plugins/cache/official/terraform/1"}]
    }}
    """),
    projectFiles: [workspace: json(#"{"mcpServers": {"repo-server": {"command": "uvx", "args": ["repo-mcp"]}}}"#)],
    pluginFiles: [
        pluginPath: json(#"{"playwright": {"command": "npx", "args": ["@playwright/mcp@latest"]}}"#),
        "/Users/x/.claude/plugins/cache/official/terraform/1": json(#"{"terraform": {"command": "docker", "args": ["run"]}}"#)
    ]
)
let now = Date(timeIntervalSince1970: 1_787_000_000)
let snapshot = MCPConfigStore.evaluate(inputs, projects: [home, workspace], now: now)
let byName = Dictionary(uniqueKeysWithValues: snapshot.servers.map { ($0.name, $0) })

expect(
    Set(byName.keys) == ["global-http", "local-stdio", "repo-server", "plugin:playwright:playwright", "plugin:terraform:terraform"],
    "server discovery missed a scope: \(byName.keys.sorted())"
)
expect(byName["global-http"]?.status == [home: .enabled, workspace: .disabled], "user-scope status per project is wrong: \(String(describing: byName["global-http"]?.status))")
expect(byName["local-stdio"]?.status == [workspace: .enabled] && byName["local-stdio"]?.scope == .local(project: workspace), "local-scope server not bound to its project")
expect(byName["repo-server"]?.status == [workspace: .pendingApproval], ".mcp.json server without approval must be pending")
expect(byName["plugin:playwright:playwright"]?.status == [home: .disabled, workspace: .enabled], "plugin server ignores disabledMcpServers: \(String(describing: byName["plugin:playwright:playwright"]?.status))")
expect(byName["plugin:terraform:terraform"]?.status == [workspace: .pluginOff], "disabled plugin must report pluginOff, scoped to its project")
expect(byName["global-http"]?.transport == .http(url: "https://mcp.example/mcp", headers: ["Authorization": "Bearer x"]), "http transport not parsed")
expect(snapshot.servers.first?.isEnabledAnywhere == true && snapshot.servers.last?.isEnabledAnywhere == false, "enabled servers should sort first")

// Toggle: pure edit of the config object.
let disabledGlobal = MCPToggle.apply(.disable, server: byName["global-http"]!, project: home, to: inputs.claudeConfig)
let homeState = (disabledGlobal["projects"] as? [String: Any])?[home] as? [String: Any]
expect((homeState?["disabledMcpServers"] as? [String]) == ["plugin:playwright:playwright", "global-http"], "disable did not append to disabledMcpServers")
let reenabledPlaywright = MCPToggle.apply(.enable, server: byName["plugin:playwright:playwright"]!, project: home, to: disabledGlobal)
let homeState2 = (reenabledPlaywright["projects"] as? [String: Any])?[home] as? [String: Any]
expect((homeState2?["disabledMcpServers"] as? [String]) == ["global-http"], "enable did not remove the entry")
let approved = MCPToggle.apply(.enable, server: byName["repo-server"]!, project: workspace, to: inputs.claudeConfig)
let workState = (approved["projects"] as? [String: Any])?[workspace] as? [String: Any]
expect((workState?["enabledMcpjsonServers"] as? [String]) == ["repo-server"] && (workState?["disabledMcpServers"] as? [String]) == ["global-http"], ".mcp.json approval must use enabledMcpjsonServers only")
let untouched = MCPConfigStore.evaluate(
    MCPConfigStore.Inputs(claudeConfig: reenabledPlaywright, settings: inputs.settings, installedPlugins: inputs.installedPlugins, projectFiles: inputs.projectFiles, pluginFiles: inputs.pluginFiles),
    projects: [home, workspace], now: now
)
expect(untouched.servers.count == snapshot.servers.count, "toggle changed the server set")

// Text: callable names and lines.
expect(MCPText.callableName(server: "plugin:playwright:playwright", tool: "browser_click") == "mcp__plugin_playwright_playwright__browser_click", "callable name sanitization is wrong")
expect(MCPText.callableName(server: "claude-in-chrome", tool: "navigate") == "mcp__claude-in-chrome__navigate", "hyphens must survive sanitization")
let tools = [MCPTool(name: "browser_click", description: "Click"), MCPTool(name: "browser_close", description: "")]
expect(
    MCPText.line(byName["plugin:playwright:playwright"]!, tools: tools)
        == "plugin:playwright:playwright  ·  plugin  ·  enabled in 1/2  ·  npx @playwright/mcp@latest  ·  mcp__plugin_playwright_playwright__browser_click, mcp__plugin_playwright_playwright__browser_close",
    "server line has the wrong shape: \(MCPText.line(byName["plugin:playwright:playwright"]!, tools: tools))"
)
expect(MCPText.line(byName["local-stdio"]!, tools: nil).hasSuffix("tools not probed"), "unprobed server must say so")
expect(MCPText.toolSearchQuery(server: byName["plugin:playwright:playwright"]!, tools: tools) == "select:mcp__plugin_playwright_playwright__browser_click,mcp__plugin_playwright_playwright__browser_close", "ToolSearch query is wrong")

// Probe parsing: newline-delimited JSON and SSE bodies.
let ndjson = """
{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18"}}
{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"browser_click","description":"Perform click\\nSecond line"},{"name":"browser_close"}]}}
"""
let parsed = MCPProbe.findResponse(id: 2, in: ndjson).flatMap(MCPProbe.parseToolsResult)
expect(parsed == [MCPTool(name: "browser_click", description: "Perform click"), MCPTool(name: "browser_close", description: "")], "ndjson tools/list not parsed: \(String(describing: parsed))")
let sse = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[{\"name\":\"t\"}]}}\n\n"
expect(MCPProbe.findResponse(id: 2, in: sse).flatMap(MCPProbe.parseToolsResult)?.map(\.name) == ["t"], "SSE data line not parsed")
expect(MCPProbe.findResponse(id: 2, in: "{\"id\":1}\nnot json\n") == nil, "wrong id must not match")

// Cache round trip.
let cacheURL = FileManager.default.temporaryDirectory.appendingPathComponent("vitals-mcp-selftest-\(UUID().uuidString)/mcp-tools.json")
defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }
var cache = MCPToolCache()
cache.records["a"] = MCPProbeRecord(tools: tools, error: nil, probedAt: now)
cache.records["b"] = MCPProbeRecord(tools: [], error: "timeout", probedAt: now)
do {
    try cache.save(to: cacheURL)
    let loaded = MCPToolCache.load(from: cacheURL)
    expect(loaded == cache, "cache did not round-trip")
    expect(loaded.tools.keys.sorted() == ["a"] && loaded.toolCount == 2, "failed probes must not count as tools")
} catch {
    failures.append("cache threw: \(error)")
}
expect(MCPToolCache.load(from: cacheURL.appendingPathComponent("missing")) == MCPToolCache(), "missing cache must load empty")

// Config path resolution.
expect(ClaudeHome(environment: [:], homeDirectory: URL(fileURLWithPath: "/Users/x")).configFileURL.path == "/Users/x/.claude.json", "default ~/.claude.json path")
expect(ClaudeHome(environment: ["CLAUDE_CONFIG_DIR": "/tmp/alt"]).configFileURL.path == "/tmp/alt/.claude.json", "CLAUDE_CONFIG_DIR config path")

if failures.isEmpty {
    print("mcp selftest: ok")
    exit(0)
}
for failure in failures {
    FileHandle.standardError.write(Data("mcp selftest: \(failure)\n".utf8))
}
exit(1)
