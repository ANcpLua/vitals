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
        {"pid":2663,"sessionId":"b30104f9","cwd":"/Users/ancplua/example-org/example-app",
         "startedAt":\(nowMillis - 420_000),"kind":"interactive","entrypoint":"cli",
         "name":"example-app-1","status":"busy","updatedAt":\(nowMillis - 1_000),"version":"2.1.239"}
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
    try write("3001.json", """
        {"pid":3001,"sessionId":"bg01","cwd":"/Users/ancplua","startedAt":\(nowMillis - 600_000),"kind":"bg","jobId":"bg01",
         "name":"Setup health check","status":"waiting","waitingFor":"input needed","updatedAt":\(nowMillis - 2_000)}
        """)
    try write("3002.json", """
        {"pid":3002,"sessionId":"bg01","cwd":"/Users/ancplua","startedAt":\(nowMillis - 700_000),"kind":"interactive",
         "parkedJobId":"bg01","name":"parked terminal","status":"idle"}
        """)
    try write("3003.json", """
        {"pid":3003,"sessionId":"sup","cwd":"/","startedAt":\(nowMillis),"kind":"daemon","name":"supervisor","status":"idle"}
        """)
    try write("3004.json", """
        {"pid":3004,"sessionId":"worker","cwd":"/","startedAt":\(nowMillis),"kind":"daemon-worker","name":"pty host","status":"busy"}
        """)
    try write("3005.json", """
        {"pid":3005,"sessionId":"sh05","cwd":"/Users/ancplua","startedAt":\(nowMillis - 900_000),"kind":"interactive",
         "name":"shell-one","status":"shell"}
        """)
    // A process the daemon started ahead of time, a newer idle session whose
    // waitingFor has the wrong JSON type, a record whose parkedJobId is not a
    // string (absent to Claude Code, so not parked), and one without a status.
    try write("3006.json", """
        {"pid":3006,"sessionId":"sp06","cwd":"/","startedAt":\(nowMillis),"kind":"bg","jobId":"sp06","spare":true}
        """)
    try write("3007.json", """
        {"pid":3007,"sessionId":"id07","cwd":"/Users/ancplua","startedAt":\(nowMillis - 60_000),"kind":"interactive",
         "name":"fresh-idle","status":"idle","waitingFor":7}
        """)
    try write("3008.json", """
        {"pid":3008,"sessionId":"pk08","cwd":"/Users/ancplua","startedAt":\(nowMillis - 90_000),"kind":"interactive","parkedJobId":5,
         "name":"numeric job id","status":"idle"}
        """)
    try write("3009.json", """
        {"pid":3009,"sessionId":"un09","cwd":"/Users/ancplua","startedAt":\(nowMillis - 30_000),"kind":"interactive","name":"no-status"}
        """)
    // Idle for three days: listed while the process started when the record
    // says it did, gone when another process holds the pid.
    let longAgo = registryNow.addingTimeInterval(-4 * 86_400)
    let lstart = DateFormatter()
    lstart.locale = Locale(identifier: "en_US_POSIX")
    lstart.timeZone = TimeZone(secondsFromGMT: 0)
    lstart.dateFormat = "EEE MMM d HH:mm:ss yyyy"
    for (pid, name) in [(3010, "three days idle"), (3011, "reused pid")] {
        try write("\(pid).json", """
            {"pid":\(pid),"sessionId":"old\(pid)","cwd":"/Users/ancplua","startedAt":\(nowMillis - 4 * 86_400_000),
             "updatedAt":\(nowMillis - 3 * 86_400_000),"kind":"bg","name":"\(name)","status":"idle",
             "procStart":"\(lstart.string(from: longAgo))"}
            """)
    }
    // The same age without a recorded process start: the 24 hour rule applies.
    try write("3012.json", """
        {"pid":3012,"sessionId":"old3012","cwd":"/Users/ancplua","startedAt":\(nowMillis - 4 * 86_400_000),
         "updatedAt":\(nowMillis - 3 * 86_400_000),"kind":"interactive","name":"no recorded start","status":"idle"}
        """)
    try write("1.json", "not json")
    try write("notes.json", """
        {"pid":1,"sessionId":"x","cwd":"/","startedAt":\(nowMillis)}
        """)
    let registry = ClaudeSessionStore.load(
        home: ClaudeHome(root: sessionsRoot),
        now: registryNow,
        isAlive: { $0 != 9999 },
        processStart: { pid in
            switch pid {
            case 3010, 3012: longAgo.addingTimeInterval(1)
            case 3011: longAgo.addingTimeInterval(600)
            default: nil
            }
        }
    )
    expect(
        registry.sessions.map { $0.name }
            == ["example-app-1", "shell-one", "Setup health check", "no-status", "fresh-idle", "numeric job id", "ancplua-bd", "three days idle"],
        "session registry did not filter dead, cloud, parked, spare, daemon, malformed, stale entries or sort working, waiting, rest: \(registry.sessions.map { $0.name })"
    )
    expect(registry.busyCount == 2, "busy and shell sessions both count as busy: \(registry.busyCount)")
    expect(registry.waitingCount == 1, "waiting session count is wrong: \(registry.waitingCount)")
    expect(registry.summary == "2 busy · 1 waiting · 5 idle", "sessions summary: \(registry.summary)")
    expect(
        registry.sessions.first { $0.pid == 3007 }?.statusText == "idle",
        "a waitingFor of the wrong JSON type must read as absent, not hide the session"
    )
    let paddedStart = try ClaudeSessionParser.parse(
        Data(#"{"pid":7,"sessionId":"s","cwd":"/","startedAt":1,"procStart":"Tue Nov  3 02:38:36 2026"}"#.utf8)
    )
    expect(
        paddedStart?.processStartedAt == Date(timeIntervalSince1970: 1_793_673_516),
        "procStart is the ps lstart layout in UTC, day padded with a space: \(String(describing: paddedStart?.processStartedAt))"
    )
    let unreadableStart = try ClaudeSessionParser.parse(
        Data(#"{"pid":7,"sessionId":"s","cwd":"/","startedAt":1,"procStart":"yesterday"}"#.utf8)
    )
    expect(
        unreadableStart != nil && unreadableStart?.processStartedAt == nil,
        "an unreadable procStart is absent, not an error"
    )
    let impossibleStart = try ClaudeSessionParser.parse(
        Data(#"{"pid":7,"sessionId":"s","cwd":"/","startedAt":1,"procStart":"Tue Nov 31 25:61:61 2026"}"#.utf8)
    )
    expect(impossibleStart != nil && impossibleStart?.processStartedAt == nil, "a date that does not exist is absent, not rolled over")
    let background = registry.sessions.first { $0.pid == 3001 }
    expect(
        background?.kind == "bg" && background?.displayKind == "background"
            && background?.status == .waiting && background?.statusText == "waiting: input needed",
        "a background session keeps its kind and says what it waits for: \(String(describing: background))"
    )
    expect(
        registry.sessions.first?.abbreviatedCwd(homeDirectory: "/Users/ancplua")
            == "~/example-org/example-app"
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
    expect(emptyRegistry.summary == "none running", "empty sessions summary: \(emptyRegistry.summary)")
    expect(
        ClaudeSessionsSnapshot(sessions: registry.sessions.filter { $0.status != .waiting }, capturedAt: registryNow).summary
            == "2 busy · 5 idle",
        "the waiting part must only appear when a session waits"
    )

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
            == "example-app-1  ·  interactive  ·  busy  ·  pid 2663  ·  /Users/ancplua/example-org/example-app  ·  session b30104f9  ·  Claude Code 2.1.239\n"
            + "shell-one  ·  interactive  ·  shell  ·  pid 3005  ·  /Users/ancplua  ·  session sh05\n"
            + "Setup health check  ·  background  ·  waiting: input needed  ·  pid 3001  ·  /Users/ancplua  ·  session bg01\n"
            + "no-status  ·  interactive  ·  unknown  ·  pid 3009  ·  /Users/ancplua  ·  session un09\n"
            + "fresh-idle  ·  interactive  ·  idle  ·  pid 3007  ·  /Users/ancplua  ·  session id07\n"
            + "numeric job id  ·  interactive  ·  idle  ·  pid 3008  ·  /Users/ancplua  ·  session pk08\n"
            + "ancplua-bd  ·  interactive  ·  idle  ·  pid 1274  ·  /Users/ancplua  ·  session f2b61b80\n"
            + "three days idle  ·  background  ·  idle  ·  pid 3010  ·  /Users/ancplua  ·  session old3010\n",
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
expect(ClaudeTranscripts.slug("/Users/ancplua/example-org/vitals") == "-Users-ancplua-example-org-vitals", "project slug")

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

// Burn presentation.
let burn = SessionBurn(pid: 4242, name: "ancplua-a4", cwd: "/Users/ancplua/x", counts: TokenCounts(calls: 10, input: 320, output: 16_976, cacheWrite: 20_621, cacheRead: 3_542_066), minutes: 15)
expect(burn.short == "×10 · 356k ctx" && abs(burn.outputPerMinute - 1_131.7) < 0.1 && abs(burn.tokensPerMinute - 238_665.5) < 0.1, "burn presentation: \(burn.short) \(burn.outputPerMinute)")

// Prompt cache from transcript usage
do {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    func request(_ id: String, at: Date, read: Int, write: Int, oneHour: Bool = true, model: String = "claude-opus-5-5", sidechain: Bool = false) -> String {
        let bucket = oneHour ? "\"ephemeral_1h_input_tokens\":\(write),\"ephemeral_5m_input_tokens\":0" : "\"ephemeral_1h_input_tokens\":0,\"ephemeral_5m_input_tokens\":\(write)"
        return #"{"type":"assistant","isSidechain":\#(sidechain),"version":"2.1.292","timestamp":"\#(iso.string(from: at))","message":{"id":"\#(id)","model":"\#(model)","usage":{"input_tokens":2,"cache_read_input_tokens":\#(read),"cache_creation_input_tokens":\#(write),"cache_creation":{\#(bucket)}}}}"#
    }
    let transcript = [
        request("m1", at: t0, read: 0, write: 100_000),
        request("m2", at: t0.addingTimeInterval(600), read: 100_000, write: 2_000),
        request("m2", at: t0.addingTimeInterval(601), read: 100_000, write: 2_000),
        request("side", at: t0.addingTimeInterval(700), read: 0, write: 50_000, sidechain: true),
        #"{"type":"assistant","timestamp":"\#(iso.string(from: t0.addingTimeInterval(800)))","message":{"id":"x","model":"<synthetic>","usage":{"input_tokens":0}}}"#,
        request("m3", at: t0.addingTimeInterval(600 + 4_000), read: 0, write: 102_500)
    ].joined(separator: "\n")
    let cache = PromptCacheParser.parse(transcript, subagent: false)
    expect(cache?.requests == 3 && cache?.ttl == 3_600 && cache?.ttlSource == .observed, "cache requests and ttl: \(String(describing: cache))")
    expect(cache?.misses == 1 && cache?.lastMissCause == .expired && cache?.missRecacheTokens == 102_500, "expired miss: \(String(describing: cache))")
    expect(cache?.recacheTokens == 102_502 && cache?.lastRequestAt == t0.addingTimeInterval(4_600), "recache tokens and last request")
    let switched = PromptCacheParser.parse([
        request("a", at: t0, read: 0, write: 80_000, oneHour: false),
        request("b", at: t0.addingTimeInterval(60), read: 3_000, write: 80_000, oneHour: false, model: "claude-sonnet-5-5")
    ].joined(separator: "\n"), subagent: true)
    expect(switched?.ttl == 300 && switched?.lastMissCause == .modelSwitch, "5m bucket and model switch: \(String(describing: switched))")
    expect(PromptCacheParser.parse("{\"type\":\"user\"}", subagent: false) == nil, "nothing before the first API response")

    let now = t0
    let warm = PromptCache(ttl: 3_600, lastRequestAt: now.addingTimeInterval(-22 * 60), requests: 10, hitRatio: 0.91, recacheTokens: 912_000)
    expect(PromptCacheText.line(warm, now: now) == "cache ● 1h ▓▓▓▓░ 38m left · hit 91% · misses 0", "warm line: \(PromptCacheText.line(warm, now: now))")
    expect(!warm.isExpiring(now: now) && warm.isExpiring(now: now.addingTimeInterval(27 * 60)), "expiring under a fifth of the TTL")
    let cold = PromptCache(ttl: 3_600, lastRequestAt: now.addingTimeInterval(-7_200), requests: 10, misses: 1, lastMissCause: .expired, hitRatio: 0.9, recacheTokens: 912_400, version: "2.1.292")
    expect(PromptCacheText.line(cold, now: now) == "cache ○ cold · next message re-caches 912k tokens · last miss: expired", "cold line: \(PromptCacheText.line(cold, now: now))")
    expect(PromptCacheText.hint(cold, runningVersion: "2.1.293", instructionsEdited: true, now: now) == "large and cold: resume from summary", "large cold hint wins")
    expect(PromptCacheText.hint(warm, runningVersion: nil, instructionsEdited: false, now: now) == nil, "no hint where none applies")
    let upgraded = PromptCache(ttl: 3_600, lastRequestAt: now.addingTimeInterval(-60), requests: 2, hitRatio: 0.9, recacheTokens: 50_000, version: "2.1.291")
    expect(PromptCacheText.hint(upgraded, runningVersion: "2.1.292", instructionsEdited: false, now: now) == "Claude Code upgrade: expect one full re-read", "pending upgrade hint")
    let smallCold = PromptCache(ttl: 300, lastRequestAt: now.addingTimeInterval(-900), requests: 2, hitRatio: 0.5, recacheTokens: 50_000, version: "2.1.291")
    expect(PromptCacheText.hint(smallCold, runningVersion: "2.1.292", instructionsEdited: false, now: now) == nil, "a cold cache gets no re-read hint")
    let subagent = SubagentCache(id: "a", label: "Run tests", cache: PromptCache(ttl: 300, lastRequestAt: now.addingTimeInterval(-280), requests: 4, misses: 2, missRecacheTokens: 180_000, hitRatio: 0.4, recacheTokens: 92_000))
    expect(PromptCacheText.subagentLine(subagent, now: now) == "↳ Run tests · ● 5m ▓░░░░ 20s left · misses 2, re-paid 180k", "subagent line: \(PromptCacheText.subagentLine(subagent, now: now))")

    let config = CacheTTLConfig.parse(settings: Data(#"{"promptCacheTtl":"5m","env":{"CLAUDE_CODE_SUBAGENT_PROMPT_CACHE_TTL":"1h"}}"#.utf8), environment: ["CLAUDE_CODE_PROMPT_CACHE_TTL": "1h"])
    expect(config == CacheTTLConfig(main: 3_600, subagent: 3_600), "ttl overrides: \(config)")
    expect(PromptCacheParser.parse(request("z", at: t0, read: 10, write: 0), subagent: false, configured: 300)?.ttlSource == .setting, "configured ttl when nothing was written")
}

// Auto-fix sessions of the desktop app
do {
    let record = DesktopSessionStore.parse(Data(#"{"sessionId":"local_1","cliSessionId":"c1","isArchived":false,"prs":[{"prNumber":4,"repo":"o/r","state":"MERGED","autoFix":true,"dismissed":true},{"prNumber":700,"repo":"example-org/example-tool","branch":"b","state":"OPEN","autoFix":true}]}"#.utf8))
    expect(record?.autoFixPR?.number == 700 && record?.cliSessionId == "c1", "desktop record: \(String(describing: record))")
    let arguments: [Int32: [String]] = [
        10: ["/Applications/Claude.app/Contents/Helpers/disclaimer", "--pgroup", "--", "/x/claude", "--resume=c1"],
        11: ["/x/claude.app/Contents/MacOS/claude", "--output-format", "stream-json", "--resume=c1"],
        12: ["/x/claude.app/Contents/MacOS/claude", "--output-format", "stream-json"],
        13: ["/Users/ancplua/.local/share/claude/versions/2.1.321", "--session-id", "c3"],
        14: ["/opt/other/versions/2.1.321", "--session-id", "c4"],
        15: ["/Users/ancplua/.local/share/claude/versions/helper", "--session-id", "c5"]
    ]
    expect(AutoFixMatch.pid(cliSessionId: "c1", arguments: arguments) == 11, "pid from --resume, not the disclaimer wrapper")
    expect(AutoFixMatch.pid(cliSessionId: "c3", arguments: arguments) == 13, "the native installer's versions/<version> executable is claude")
    expect(AutoFixMatch.pid(cliSessionId: "c4", arguments: arguments) == nil, "another tool's versions folder is not claude")
    expect(AutoFixMatch.pid(cliSessionId: "c5", arguments: arguments) == nil, "only a version-numbered file under claude/versions is claude")
    let fresh = DesktopCodeSession(localId: "local_2", cliSessionId: "c2", prs: [BoundPullRequest(number: 5, repo: "o/r")])
    let registry = [ClaudeSession(pid: 12, sessionId: "c2", name: "n", status: .idle, cwd: "/", startedAt: Date(), updatedAt: Date(), version: nil, hostSessionId: "local_2")]
    let matched = AutoFixMatch.sessions(records: [record!, fresh], registry: registry, arguments: arguments)
    expect(matched[11]?.pr.number == 700 && matched[12]?.pr.number == 5, "auto-fix sessions by pid: \(matched.keys.sorted())")

    let pr = Data(#"{"state":"OPEN","reviewDecision":"","mergeable":"MERGEABLE","autoMergeRequest":null,"statusCheckRollup":[]}"#.utf8)
    let approval = PullRequestStatus.parse(pr: pr, runs: Data(#"[{"status":"completed","conclusion":"action_required","workflowName":"build"}]"#.utf8), at: Date())
    expect(approval?.ci == .approval && approval?.reviewDecision == nil && approval?.autoMerge == false, "action_required run: \(String(describing: approval))")
    let failing = PullRequestStatus.parse(pr: Data(#"{"state":"OPEN","mergeable":"MERGEABLE","autoMergeRequest":{"mergeMethod":"SQUASH"},"statusCheckRollup":[{"__typename":"CheckRun","name":"ubuntu","status":"COMPLETED","conclusion":"FAILURE"},{"__typename":"StatusContext","context":"ci/x","state":"PENDING"}]}"#.utf8), runs: nil, at: Date())
    expect(failing?.ci == .failing && failing?.failingChecks == ["ubuntu"] && failing?.autoMerge == true, "failing rollup: \(String(describing: failing))")
    expect(PullRequestStatus.parse(pr: pr, runs: Data("[]".utf8), at: Date())?.ci == PullRequestStatus.CI.none, "no checks at all")

    let bound = BoundPullRequest(number: 700, repo: "example-org/example-tool")
    func state(_ status: PullRequestStatus?, activity: AutoFixActivity? = nil, busy: Bool = false) -> AutoFixState {
        AutoFix.state(AutoFixSession(pid: 1, localId: "l", cliSessionId: nil, pr: bound, activity: activity, status: status), busy: busy)
    }
    let at = Date()
    expect(state(PullRequestStatus(state: "OPEN", ci: .pending, fetchedAt: at)) == .watching, "watching")
    expect(state(PullRequestStatus(state: "OPEN", ci: .failing, fetchedAt: at), activity: AutoFixActivity(kinds: ["CI failure"], at: at), busy: true) == .working, "working on event")
    expect(state(PullRequestStatus(state: "OPEN", ci: .failing, fetchedAt: at)) == .failing("CI failing"), "CI failing")
    expect(state(PullRequestStatus(state: "OPEN", ci: .passing, mergeable: "CONFLICTING", fetchedAt: at)) == .failing("merge conflict"), "merge conflict")
    expect(state(PullRequestStatus(state: "OPEN", ci: .approval, fetchedAt: at)).label == "waiting for approval", "waiting for approval")
    expect(state(PullRequestStatus(state: "OPEN", ci: .passing, mergeable: "MERGEABLE", fetchedAt: at)) == .ready, "green and mergeable")
    expect(state(PullRequestStatus(state: "MERGED", ci: .passing, fetchedAt: at)) == .closed("merged"), "merged is dimmed")

    let event = #"<ci-monitor-event>\"Auto-fix pull requests\" is watching o/r PR #7 and detected the following.\n\no/r PR #7 has 1 new review comment (quoted below).\nQuoted from GitHub\nComment 1 — review summary\n> has merge conflicts\n(End of quoted GitHub text.)\n</ci-monitor-event>"#
    let log = [
        #"{"type":"user","timestamp":"2026-10-07T01:00:00.000Z","message":{"role":"user","content":"\#(event)"}}"#,
        #"{"type":"assistant","timestamp":"2026-10-07T01:01:00.000Z","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git push origin b"}}]}}"#,
        #"{"type":"user","timestamp":"2026-10-07T01:01:05.000Z","message":{"content":[{"type":"tool_result","content":"To github.com:o/r.git\n   4deb8d9..da8f1b6  b -> b"}]}}"#,
        #"{"type":"assistant","timestamp":"2026-10-07T01:02:00.000Z","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"gh api repos/o/r/pulls/7/comments/1/replies -f body=x"}}]}}"#
    ]
    let activity = AutoFixEvents.last(in: log.joined(separator: "\n"))
    expect(activity?.kinds == ["review comment"] && activity?.action == "pushed da8f1b6, replied" && activity?.unanswered == true, "event and action: \(String(describing: activity))")
    let answered = AutoFixEvents.last(in: (log + [#"{"type":"user","origin":{"kind":"human"},"message":{"content":"thanks"}}"#]).joined(separator: "\n"))
    expect(answered?.unanswered == false, "a human message ends the event")
    expect(AutoFixEvents.kinds("x\nFailing checks (1):\n> \"build\"") == ["CI failure"], "CI failure entry line")
    expect(AutoFixEvents.kinds("o/r PR #7 has merge conflicts with main.") == ["merge conflict"], "merge conflict sentence")
}

// Status incidents as the incident page shows them
do {
    let summary = Data(#"{"status":{"indicator":"minor","description":"Minor Service Outage"},"components":[{"name":"Claude Console","status":"degraded_performance"}],"incidents":[{"name":"Elevated errors","incident_updates":[{"status":"identified","body":"Cause found.","created_at":"2026-10-07T17:28:02.568Z","display_at":"2026-10-07T17:28:02.568Z"},{"status":"investigating","body":"Still on it.","created_at":"2026-10-07T16:36:44.789Z","display_at":"2026-10-07T16:36:44.789Z"},{"status":"investigating","body":"Looking.","created_at":"2026-10-07T13:25:04.271Z","display_at":"2026-10-07T13:25:04.271Z"}]}]}"#.utf8)
    let health = try ClaudeStatusParser.parse(summary)
    let expected = "Claude Console\n\nElevated errors\n\nIdentified - Cause found.\nOct 07, 2026 - 17:28 UTC\n\nUpdate - Still on it.\nOct 07, 2026 - 16:36 UTC\n\nInvestigating - Looking.\nOct 07, 2026 - 13:25 UTC"
    expect(health.level == .degraded && health.hoverText == expected, "incident hover text:\n\(health.hoverText)")
} catch {
    expect(false, "status incidents: \(error)")
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
