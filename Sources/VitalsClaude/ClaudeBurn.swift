import Foundation

// MARK: - Per-session token burn from the local transcripts

/// The four usage counters over a window plus the number of API calls.
/// Cache reads dominate by two orders of magnitude, because every call
/// re-reads the whole context, so the raw sum says little; `weighted`
/// applies the price ratios (input 1, cache write 1.25, cache read 0.1,
/// output 5) and `context` is what each call carried.
public struct TokenCounts: Codable, Equatable, Sendable {
    public var calls = 0
    public var input = 0
    public var output = 0
    public var cacheWrite = 0
    public var cacheRead = 0

    public init(calls: Int = 0, input: Int = 0, output: Int = 0, cacheWrite: Int = 0, cacheRead: Int = 0) {
        self.calls = calls
        self.input = input
        self.output = output
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
    }

    public var total: Int { input + output + cacheWrite + cacheRead }
    public var weighted: Double { Double(input) + 1.25 * Double(cacheWrite) + 0.1 * Double(cacheRead) + 5 * Double(output) }
    /// Average tokens a call carried in: the size of the conversation.
    public var context: Int { calls == 0 ? 0 : (input + cacheWrite + cacheRead) / calls }

    public static func + (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts {
        TokenCounts(calls: lhs.calls + rhs.calls, input: lhs.input + rhs.input, output: lhs.output + rhs.output,
                    cacheWrite: lhs.cacheWrite + rhs.cacheWrite, cacheRead: lhs.cacheRead + rhs.cacheRead)
    }
}

/// Subagents a session started, from the log the Claude Code hook
/// `fable-subagent-gate.sh` writes: one line per `Agent` tool call with the
/// resolved model, whether it was Fable, and whether the gate denied it.
public struct SpawnCounts: Codable, Equatable, Sendable {
    /// Calls that went through.
    public var spawned = 0
    /// Of those, on Fable.
    public var fable = 0
    /// Gate denials, each one a reminder the orchestrator had to answer.
    public var reminders = 0

    public init(spawned: Int = 0, fable: Int = 0, reminders: Int = 0) {
        self.spawned = spawned
        self.fable = fable
        self.reminders = reminders
    }

    /// "3 agents, 2 Fable"; nil when the session spawned nothing.
    public var short: String? {
        guard spawned > 0 else { return nil }
        let agents = spawned == 1 ? "1 agent" : "\(spawned) agents"
        return fable > 0 ? "\(agents), \(fable) Fable" : agents
    }
}

public enum AgentSpawns {
    public static func directory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".config/vitals/agent-spawns")
    }

    public static func counts(in text: String) -> SpawnCounts {
        var counts = SpawnCounts()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if object["denied"] as? Bool == true {
                counts.reminders += 1
                continue
            }
            counts.spawned += 1
            if object["fable"] as? Bool == true { counts.fable += 1 }
        }
        return counts
    }

    public static func counts(for sessionId: String, directory: URL = directory()) -> SpawnCounts {
        let url = directory.appendingPathComponent("\(sessionId).jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return SpawnCounts() }
        return counts(in: text)
    }
}

/// What one live session burned inside the window, from its transcript
/// under `~/.claude/projects`, plus the subagents it started. Absolute
/// numbers: the usage endpoint only reports percentages.
public struct SessionBurn: Codable, Equatable, Sendable {
    public let pid: Int32
    public let name: String
    public let cwd: String
    public let counts: TokenCounts
    public let minutes: Double
    public let spawns: SpawnCounts

    public init(pid: Int32, name: String, cwd: String, counts: TokenCounts, minutes: Double, spawns: SpawnCounts = SpawnCounts()) {
        self.pid = pid
        self.name = name
        self.cwd = cwd
        self.counts = counts
        self.minutes = minutes
        self.spawns = spawns
    }

    public var tokens: Int { counts.total }
    public var tokensPerMinute: Double { Double(counts.total) / minutes }
    public var outputPerMinute: Double { Double(counts.output) / minutes }
    public var weightedPerMinute: Double { counts.weighted / minutes }

    /// "×10 · 350k ctx · 3 agents, 2 Fable": calls in the window, the
    /// context each carried, and the subagents started so far.
    public var short: String {
        var parts: [String] = []
        if counts.calls > 0 { parts.append("×\(counts.calls) · \(ClaudeBurn.tokens(Double(counts.context))) ctx") }
        if let spawns = spawns.short { parts.append(spawns) }
        return parts.isEmpty ? "idle" : parts.joined(separator: " · ")
    }

    public var long: String {
        let calls = counts.calls == 0 ? "no calls in the last \(Int(minutes)) min" :
            "\(counts.calls) calls in \(Int(minutes)) min, \(ClaudeBurn.tokens(Double(counts.context))) context each, "
            + "\(ClaudeBurn.tokens(outputPerMinute)) output/min, \(ClaudeBurn.tokens(Double(counts.cacheRead) / minutes)) cache read/min, "
            + "weighted \(ClaudeBurn.tokens(weightedPerMinute))/min"
        guard let agents = spawns.short else { return calls }
        let reminders = spawns.reminders == 0 ? "" : ", \(spawns.reminders) Fable reminder\(spawns.reminders == 1 ? "" : "s")"
        return "\(calls); \(agents) spawned\(reminders)"
    }
}

public enum ClaudeBurn {
    public static let window: TimeInterval = 15 * 60

    public static func tokens(_ value: Double) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        if value >= 10_000 { return String(format: "%.0fk", value / 1_000) }
        if value >= 1_000 { return String(format: "%.1fk", value / 1_000) }
        return String(format: "%.0f", value)
    }
}

public enum ClaudeTranscripts {
    /// Claude Code names the project directory after the working directory
    /// with every non-alphanumeric character turned into a dash.
    public static func slug(_ cwd: String) -> String {
        String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }

    /// The session's own transcript plus anything under its subagent
    /// directory, when present.
    public static func transcriptURLs(for session: ClaudeSession, home: ClaudeHome) -> [URL] {
        let project = home.root.appendingPathComponent("projects/\(slug(session.cwd))")
        var urls = [project.appendingPathComponent("\(session.sessionId).jsonl")]
        let nested = project.appendingPathComponent(session.sessionId)
        if let files = FileManager.default.enumerator(at: nested, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let file as URL in files where file.pathExtension == "jsonl" {
                urls.append(file)
            }
        }
        return urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Counts every assistant line at or after `since`, one call per message
    /// id: streaming writes one line per content block, all carrying the
    /// message's usage, and the last line carries the final numbers.
    public static func counts(in text: String, since: Date) -> TokenCounts {
        var perMessage: [String: TokenCounts] = [:]
        var order: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains("\"usage\""),
                  let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "assistant",
                  let stamp = object["timestamp"] as? String,
                  let date = parse(stamp), date >= since,
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any]
            else { continue }
            let key = (message["id"] as? String) ?? (object["requestId"] as? String) ?? (object["uuid"] as? String) ?? stamp
            if perMessage[key] == nil { order.append(key) }
            perMessage[key] = TokenCounts(
                calls: 1,
                input: (usage["input_tokens"] as? Int) ?? 0,
                output: (usage["output_tokens"] as? Int) ?? 0,
                cacheWrite: (usage["cache_creation_input_tokens"] as? Int) ?? 0,
                cacheRead: (usage["cache_read_input_tokens"] as? Int) ?? 0
            )
        }
        return order.reduce(TokenCounts()) { $0 + perMessage[$1]! }
    }

    /// Reads only the tail of each file: a day of agent work is megabytes,
    /// the last 15 minutes fit in the last megabyte.
    public static func counts(at urls: [URL], since: Date, tailBytes: Int = 1 << 20) -> TokenCounts {
        var total = TokenCounts()
        for url in urls {
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
            try? handle.seek(toOffset: start)
            guard let data = try? handle.readToEnd(), var text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { continue }
            if start > 0, let newline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: newline)...])
            }
            total = total + counts(in: text, since: since)
        }
        return total
    }

    public static func burn(
        for session: ClaudeSession, home: ClaudeHome, now: Date,
        window: TimeInterval = ClaudeBurn.window, spawns: URL = AgentSpawns.directory()
    ) -> SessionBurn {
        let since = now.addingTimeInterval(-window)
        return SessionBurn(
            pid: session.pid, name: session.name, cwd: session.cwd,
            counts: counts(at: transcriptURLs(for: session, home: home), since: since),
            minutes: window / 60,
            spawns: AgentSpawns.counts(for: session.sessionId, directory: spawns)
        )
    }

    private static func parse(_ stamp: String) -> Date? {
        fractional.date(from: stamp) ?? plain.date(from: stamp)
    }

    // ISO8601DateFormatter is documented thread-safe; the annotation only
    // tells the compiler so.
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()
}
