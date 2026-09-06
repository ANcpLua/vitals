import Foundation
import VitalsClaude

var failures: [String] = []

@MainActor
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures.append(message)
    }
}

func snapshot(
    health: ClaudeHealthLevel = .operational,
    utilization: Double = 10
) -> ClaudeTelemetrySnapshot {
    ClaudeTelemetrySnapshot(
        health: ClaudeHealth(
            level: health,
            label: health == .operational ? "OPERATIONAL" : "DEGRADED",
            detail: "Claude API"
        ),
        usage: .available([
            ClaudeUsageRow(
                id: "weekly_all",
                label: "Weekly · all models",
                fraction: min(utilization / 100, 1),
                detail: "\(Int(utilization))%",
                utilization: utilization
            )
        ]),
        capturedAt: Date(timeIntervalSince1970: 0)
    )
}

do {
    let usageData = Data(
        """
        {
          "limits": [
            {
              "kind": "weekly_scoped",
              "percent": 74,
              "resets_at": "2026-08-01T08:00:00.000000+00:00",
              "scope": {"model": {"display_name": "Fable"}}
            },
            {
              "kind": "future_limit",
              "percent": 99,
              "resets_at": null,
              "scope": null
            },
            {
              "kind": "session",
              "percent": 2,
              "resets_at": "2026-07-29T18:00:00.000000+00:00",
              "scope": null
            },
            {
              "kind": "weekly_all",
              "percent": 81,
              "resets_at": "2026-08-01T08:00:00.000000+00:00",
              "scope": null
            }
          ]
        }
        """.utf8
    )
    guard let now = ISO8601DateFormatter().date(
        from: "2026-07-29T14:00:00Z"
    ) else {
        throw SelftestError.invalidFixtureDate
    }
    let rows = try ClaudeUsageParser.parse(usageData, now: now)
    expect(
        rows.map(\.label) == [
            "5-hour limit",
            "Weekly · all models",
            "Weekly · Fable"
        ],
        "usage rows are not in the expected display order"
    )
    expect(
        rows.map(\.fraction) == [0.02, 0.81, 0.74],
        "usage fractions were not normalized"
    )
    expect(
        rows.map(\.detail) == [
            "2% · resets 4h",
            "81% · resets 3d",
            "74% · resets 3d"
        ],
        "usage reset details were not formatted correctly"
    )

    let operational = try ClaudeStatusParser.parse(Data(
        """
        {
          "status": {"indicator": "none", "description": "All Systems Operational"},
          "components": [{"name": "Claude API", "status": "operational"}]
        }
        """.utf8
    ))
    let degraded = try ClaudeStatusParser.parse(Data(
        """
        {
          "status": {"indicator": "minor", "description": "Partial degradation"},
          "components": [
            {"name": "Claude API", "status": "degraded_performance"},
            {"name": "Claude Code", "status": "operational"}
          ]
        }
        """.utf8
    ))
    expect(
        operational.level == .operational
            && operational.label == "OPERATIONAL",
        "operational status was not mapped correctly"
    )
    expect(
        degraded.level == .degraded
            && degraded.label == "DEGRADED"
            && degraded.detail == "Claude API",
        "degraded status did not identify the affected component"
    )

    var state = ClaudeAlertState()
    var decision = ClaudeAlerts.evaluate(
        snapshot: snapshot(utilization: 74),
        previous: state
    )
    expect(decision.triggered.isEmpty, "initial usage emitted an alert")
    state = decision.state

    decision = ClaudeAlerts.evaluate(
        snapshot: snapshot(utilization: 81),
        previous: state
    )
    expect(
        decision.triggered.map(\.message) == [
            "Weekly · all models reached 75%"
        ],
        "75% usage edge did not emit exactly once"
    )
    state = decision.state

    decision = ClaudeAlerts.evaluate(
        snapshot: snapshot(utilization: 82),
        previous: state
    )
    expect(decision.triggered.isEmpty, "usage alert repeated above its edge")
    state = decision.state

    decision = ClaudeAlerts.evaluate(
        snapshot: snapshot(utilization: 96),
        previous: state
    )
    expect(
        decision.triggered.map(\.message) == [
            "Weekly · all models reached 90%"
        ],
        "highest crossed usage edge was not selected"
    )
    state = decision.state

    decision = ClaudeAlerts.evaluate(
        snapshot: snapshot(utilization: 101),
        previous: state
    )
    expect(
        decision.triggered.map(\.message) == [
            "Weekly · all models reached 100%"
        ],
        "100% usage edge did not emit exactly once"
    )

    let initialHealth = ClaudeAlerts.evaluate(
        snapshot: snapshot(health: .operational),
        previous: ClaudeAlertState()
    )
    let degradedHealth = ClaudeAlerts.evaluate(
        snapshot: snapshot(health: .degraded),
        previous: initialHealth.state
    )
    let recoveredHealth = ClaudeAlerts.evaluate(
        snapshot: snapshot(health: .operational),
        previous: degradedHealth.state
    )
    expect(initialHealth.triggered.isEmpty, "initial health emitted an alert")
    expect(
        degradedHealth.triggered.map(\.title) == [
            "Vitals · Claude status"
        ],
        "health degradation did not emit an alert"
    )
    expect(
        recoveredHealth.triggered.isEmpty,
        "health recovery emitted an unwanted alert"
    )
    let denied = ClaudeUsageState.accessDenied
    expect(
        denied.isAccessDenied
            && denied.rows.isEmpty
            && denied.unavailableMessage == "Keychain access denied · Refresh to retry",
        "Keychain denial state is not explicit"
    )

    // Session registry: one local interactive session, one stale pid, one
    // cloud-shaped entry, one malformed file.
    let sessionsRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("vitals-claude-selftest-\(UUID().uuidString)", isDirectory: true)
    let sessionsDir = sessionsRoot.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: sessionsRoot) }
    let nowMillis: Int64 = 1_787_386_600_000
    let registryNow = Date(timeIntervalSince1970: Double(nowMillis) / 1_000)
    func write(_ name: String, _ json: String) throws {
        try Data(json.utf8).write(to: sessionsDir.appendingPathComponent(name))
    }
    try write("2663.json", """
        {"pid":2663,"sessionId":"b30104f9","cwd":"/Users/ancplua/repo-playground/customer-desk",
         "startedAt":\(nowMillis - 420_000),"kind":"interactive","entrypoint":"cli",
         "name":"customer-desk-82","status":"busy","updatedAt":\(nowMillis - 1_000),"version":"2.1.239"}
        """)
    try write("1274.json", """
        {"pid":1274,"sessionId":"f2b61b80","cwd":"/Users/ancplua",
         "startedAt":\(nowMillis - 3_900_000),"kind":"interactive",
         "name":"ancplua-bd","status":"idle","updatedAt":\(nowMillis - 60_000)}
        """)
    try write("9999.json", """
        {"pid":9999,"sessionId":"dead","cwd":"/tmp","startedAt":\(nowMillis),"name":"dead-00","status":"idle"}
        """)
    try write("4242.json", """
        {"pid":4242,"sessionId":"cloud","cwd":"/","startedAt":\(nowMillis),"kind":"cloud","name":"Opus comparison","status":"idle"}
        """)
    try write("1.json", "not json")
    try write("notes.json", """
        {"pid":1,"sessionId":"x","cwd":"/","startedAt":\(nowMillis)}
        """)
    let registry = ClaudeSessionStore.load(
        home: ClaudeHome(root: sessionsRoot),
        now: registryNow,
        isAlive: { $0 != 9999 }
    )
    expect(
        registry.sessions.map { $0.name } == ["customer-desk-82", "ancplua-bd"],
        "session registry did not filter dead, cloud, malformed entries or sort busy-first: \(registry.sessions.map { $0.name })"
    )
    expect(registry.busyCount == 1, "busy session count is wrong")
    expect(
        registry.sessions.first?.abbreviatedCwd(homeDirectory: "/Users/ancplua")
            == "~/repo-playground/customer-desk"
            && registry.sessions.last?.abbreviatedCwd(homeDirectory: "/Users/ancplua") == "~",
        "cwd abbreviation is wrong"
    )
    expect(
        registry.sessions.first.map { registryNow.timeIntervalSince($0.startedAt) } == 420,
        "startedAt was not decoded from milliseconds"
    )
    let emptyRegistry = ClaudeSessionStore.load(
        home: ClaudeHome(root: sessionsRoot.appendingPathComponent("missing")),
        now: registryNow
    )
    expect(emptyRegistry.sessions.isEmpty, "missing sessions directory did not yield an empty snapshot")

    let textSession = ClaudeSession(
        pid: 64779,
        sessionId: "8fda8e42-ad9a-4e43-9a38-11f4af698120",
        name: "ancplua-d6",
        kind: "interactive",
        status: .busy,
        cwd: "/Users/ancplua",
        startedAt: registryNow,
        updatedAt: registryNow,
        version: "2.1.261"
    )
    expect(
        ClaudeSessionText.line(textSession)
            == "ancplua-d6  ·  interactive  ·  busy  ·  pid 64779  ·  /Users/ancplua  ·  session 8fda8e42-ad9a-4e43-9a38-11f4af698120  ·  Claude Code 2.1.261",
        "session clipboard line has the wrong shape: \(ClaudeSessionText.line(textSession))"
    )
    expect(
        ClaudeSessionText.lines(registry.sessions)
            == "customer-desk-82  ·  interactive  ·  busy  ·  pid 2663  ·  /Users/ancplua/repo-playground/customer-desk  ·  session b30104f9  ·  Claude Code 2.1.239\n"
            + "ancplua-bd  ·  interactive  ·  idle  ·  pid 1274  ·  /Users/ancplua  ·  session f2b61b80\n",
        "session clipboard text does not list every session, one per line, version optional"
    )

    let credential = try ClaudeCredentialStore.decode(Data(
        """
        {"claudeAiOauth":{"accessToken":"sk-ant-test","expiresAt":1787400000000,"scopes":["user:inference"]}}

        """.utf8
    ))
    expect(
        credential.accessToken == "sk-ant-test" && credential.expiresAt == 1_787_400_000_000,
        "security -w output was not decoded"
    )
    do {
        _ = try ClaudeCredentialStore.decode(Data(#"{"claudeAiOauth":{"accessToken":"","expiresAt":1}}"#.utf8))
        failures.append("empty access token was accepted")
    } catch ClaudeTelemetryError.invalidCredential {
    }

    let home = ClaudeHome(environment: ["CLAUDE_CONFIG_DIR": "/tmp/claude-alt"])
    expect(
        home.sessionsDirectory.path == "/tmp/claude-alt/sessions",
        "CLAUDE_CONFIG_DIR override was not honored"
    )
    let defaultHome = ClaudeHome(environment: [:], homeDirectory: URL(fileURLWithPath: "/Users/x"))
    expect(
        defaultHome.root.path == "/Users/x/.claude",
        "default Claude home is not ~/.claude"
    )
} catch {
    failures.append("selftest threw: \(error)")
}

// A 429 (or any transient failure) keeps the last rows and their age; a
// fresh reading replaces them; access denial replaces them too.
let good = snapshot(utilization: 42)
let limited = ClaudeTelemetrySnapshot(health: good.health, usage: .unavailable("HTTP 429"), capturedAt: Date())
let kept = limited.keepingUsage(from: good)
expect(kept.usage == good.usage && kept.capturedAt == good.capturedAt, "429 must keep the previous rows and their capture time")
expect(limited.keepingUsage(from: nil) == limited, "no previous reading: the failure stands")
expect(snapshot(utilization: 50).keepingUsage(from: good).usage.rows.first?.utilization == 50, "a fresh reading must replace the old rows")
let denied = ClaudeTelemetrySnapshot(health: good.health, usage: .accessDenied, capturedAt: Date())
expect(denied.keepingUsage(from: good).usage.isAccessDenied, "access denial must not be papered over with old rows")

// Presentation helpers and the project slug.
let budgetNow = Date(timeIntervalSince1970: 1_800_000_000)
expect(ClaudeBurn.tokens(240_000) == "240k" && ClaudeBurn.tokens(1_260_000) == "1.3M" && ClaudeBurn.tokens(850) == "850", "token formatting")
expect(ClaudeTranscripts.slug("/Users/ancplua/repo-playground/vitals") == "-Users-ancplua-repo-playground-vitals", "project slug")

// Transcripts: assistant lines inside the window count once per message id
// even when streaming wrote several lines; older lines and user lines do not.
func line(_ type: String, id: String, at: Date, tokens: Int) -> String {
    let stamp = ISO8601DateFormatter()
    stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return "{\"type\":\"\(type)\",\"timestamp\":\"\(stamp.string(from: at))\",\"message\":{\"id\":\"\(id)\",\"usage\":{\"input_tokens\":\(tokens),\"output_tokens\":1,\"cache_creation_input_tokens\":2,\"cache_read_input_tokens\":3}}}"
}
let transcript = [
    line("assistant", id: "m1", at: budgetNow.addingTimeInterval(-60), tokens: 100),
    line("assistant", id: "m1", at: budgetNow.addingTimeInterval(-60), tokens: 100),
    line("assistant", id: "m2", at: budgetNow.addingTimeInterval(-3_600), tokens: 5_000),
    line("user", id: "u1", at: budgetNow.addingTimeInterval(-30), tokens: 999),
    "not json at all",
    line("assistant", id: "m3", at: budgetNow.addingTimeInterval(-120), tokens: 10)
].joined(separator: "\n")
let counted = ClaudeTranscripts.counts(in: transcript, since: budgetNow.addingTimeInterval(-900))
expect(counted.calls == 2 && counted.input == 110 && counted.output == 2 && counted.cacheWrite == 4 && counted.cacheRead == 6,
       "transcript counts must dedupe by message id and honor the window, got \(counted)")
expect(counted.total == 122 && counted.context == 60 && abs(counted.weighted - (110 + 5 + 0.6 + 10)) < 0.01, "totals, context and price weighting")

// Burn presentation, and the subagent spawn log the gate hook writes: a
// denied line is a reminder, not a spawn; everything else counts, Fable
// separately.
let burn = SessionBurn(pid: 4242, name: "ancplua-a4", cwd: "/Users/ancplua/x", counts: TokenCounts(calls: 10, input: 320, output: 16_976, cacheWrite: 20_621, cacheRead: 3_542_066), minutes: 15)
expect(burn.short == "×10 · 356k ctx" && abs(burn.outputPerMinute - 1_131.7) < 0.1 && abs(burn.tokensPerMinute - 238_665.5) < 0.1, "burn presentation: \(burn.short) \(burn.outputPerMinute)")
let spawnLog = [
    #"{"t": 1.0, "model": "fable", "fable": true, "denied": true, "description": "asked"}"#,
    #"{"t": 2.0, "model": "fable", "fable": true, "denied": false, "description": "kept"}"#,
    #"{"t": 3.0, "model": "opus", "fable": false, "denied": false, "description": "worker"}"#,
    "not json",
    #"{"t": 4.0, "model": "claude-fable-5-1", "source": "inherits parent", "fable": true, "denied": false}"#
].joined(separator: "\n")
let spawns = AgentSpawns.counts(in: spawnLog)
expect(spawns == SpawnCounts(spawned: 3, fable: 2, reminders: 1), "spawn log counts: \(spawns)")
expect(spawns.short == "3 agents, 2 Fable" && SpawnCounts().short == nil && SpawnCounts(spawned: 1).short == "1 agent", "spawn presentation")
let withSpawns = SessionBurn(pid: 1, name: "s", cwd: "/", counts: TokenCounts(), minutes: 15, spawns: spawns)
expect(withSpawns.short == "3 agents, 2 Fable" && withSpawns.long == "no calls in the last 15 min; 3 agents, 2 Fable spawned, 1 Fable reminder", "spawns without calls: \(withSpawns.long)")
let spawnDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vitals-claude-selftest-\(getpid())/agent-spawns")
do {
    try FileManager.default.createDirectory(at: spawnDir, withIntermediateDirectories: true)
    try spawnLog.write(to: spawnDir.appendingPathComponent("abc.jsonl"), atomically: true, encoding: .utf8)
    expect(AgentSpawns.counts(for: "abc", directory: spawnDir) == spawns, "spawn log is read per session id")
    expect(AgentSpawns.counts(for: "missing", directory: spawnDir) == SpawnCounts(), "a session without a log spawned nothing")
    try? FileManager.default.removeItem(at: spawnDir.deletingLastPathComponent())
} catch {
    expect(false, "spawn log store: \(error)")
}

if failures.isEmpty {
    print("claude selftest: ok")
    exit(0)
}

for failure in failures {
    FileHandle.standardError.write(Data("claude selftest: \(failure)\n".utf8))
}
exit(1)

enum SelftestError: Error {
    case invalidFixtureDate
}
