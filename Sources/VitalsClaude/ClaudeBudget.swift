import Foundation

// MARK: - Samples and forecast

/// One reading of a limit row. Persisted so a Vitals restart keeps the rate.
public struct UsageSample: Codable, Equatable, Sendable {
    public let rowID: String
    public let at: Date
    public let utilization: Double

    public init(rowID: String, at: Date, utilization: Double) {
        self.rowID = rowID
        self.at = at
        self.utilization = utilization
    }
}

/// Where a limit row is heading at the rate of the last 15 minutes.
public struct UsageForecast: Equatable, Sendable {
    public let rowID: String
    public let label: String
    public let utilization: Double
    /// Percent of the limit consumed per hour over the window.
    public let percentPerHour: Double
    /// Seconds until 100 % at that rate; nil when nothing is being consumed.
    public let emptyIn: TimeInterval?
    public let resetsIn: TimeInterval?

    public init(rowID: String, label: String, utilization: Double, percentPerHour: Double, emptyIn: TimeInterval?, resetsIn: TimeInterval?) {
        self.rowID = rowID
        self.label = label
        self.utilization = utilization
        self.percentPerHour = percentPerHour
        self.emptyIn = emptyIn
        self.resetsIn = resetsIn
    }

    /// The limit runs out before it resets: the only case worth a warning.
    public var depletesBeforeReset: Bool {
        guard let emptyIn, let resetsIn else { return false }
        return emptyIn < resetsIn
    }

    public var critical: Bool {
        depletesBeforeReset && (emptyIn ?? .infinity) < 3_600
    }
}

public enum ClaudeBudget {
    public static let window: TimeInterval = 15 * 60
    public static let minimumSpan: TimeInterval = 4 * 60
    public static let retention: TimeInterval = 2 * 3_600

    /// Rate between the oldest and the newest sample inside the window. A
    /// reset inside the window (utilization dropped) discards everything
    /// before the drop. Fewer than four minutes of samples give no forecast:
    /// agent sessions are bursty and a two-sample slope would cry wolf.
    public static func forecast(row: ClaudeUsageRow, samples: [UsageSample], now: Date) -> UsageForecast? {
        var inWindow = samples
            .filter { $0.rowID == row.id && now.timeIntervalSince($0.at) <= window }
            .sorted { $0.at < $1.at }
        if let drop = inWindow.indices.last(where: { $0 > 0 && inWindow[$0].utilization < inWindow[$0 - 1].utilization }) {
            inWindow.removeFirst(drop)
        }
        guard let first = inWindow.first, let last = inWindow.last,
              last.at.timeIntervalSince(first.at) >= minimumSpan
        else { return nil }
        let hours = last.at.timeIntervalSince(first.at) / 3_600
        let rate = (last.utilization - first.utilization) / hours
        let remaining = max(0, 100 - row.utilization)
        return UsageForecast(
            rowID: row.id,
            label: row.label,
            utilization: row.utilization,
            percentPerHour: rate,
            emptyIn: rate > 0 ? remaining / rate * 3_600 : nil,
            resetsIn: row.resetsAt.map { max(0, $0.timeIntervalSince(now)) }
        )
    }

    public static func pruned(_ samples: [UsageSample], now: Date) -> [UsageSample] {
        samples.filter { now.timeIntervalSince($0.at) <= retention }
    }

    /// The forecast that deserves the warning: the one running out soonest
    /// among those that run out before their reset.
    public static func worst(_ forecasts: [UsageForecast]) -> UsageForecast? {
        forecasts.filter(\.depletesBeforeReset).min { ($0.emptyIn ?? .infinity) < ($1.emptyIn ?? .infinity) }
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let days = total / 86_400
        let hours = total % 86_400 / 3_600
        let minutes = total % 3_600 / 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        return "\(max(1, minutes))m"
    }

    public static func tokens(_ value: Double) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        if value >= 10_000 { return String(format: "%.0fk", value / 1_000) }
        if value >= 1_000 { return String(format: "%.1fk", value / 1_000) }
        return String(format: "%.0f", value)
    }
}

/// Samples under Application Support so the rate survives a restart.
public enum UsageSampleStore {
    public static func url(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/Vitals/usage-samples.json")
    }

    public static func load(from url: URL = url()) -> [UsageSample] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([UsageSample].self, from: data)) ?? []
    }

    public static func save(_ samples: [UsageSample], to url: URL = url()) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(samples).write(to: url, options: .atomic)
    }
}

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

/// What one live session burned inside the window, from its transcript
/// under `~/.claude/projects`. Absolute numbers: the usage endpoint only
/// reports percentages.
public struct SessionBurn: Codable, Equatable, Sendable {
    public let pid: Int32
    public let name: String
    public let cwd: String
    public let counts: TokenCounts
    public let minutes: Double

    public init(pid: Int32, name: String, cwd: String, counts: TokenCounts, minutes: Double) {
        self.pid = pid
        self.name = name
        self.cwd = cwd
        self.counts = counts
        self.minutes = minutes
    }

    public var tokens: Int { counts.total }
    public var tokensPerMinute: Double { Double(counts.total) / minutes }
    public var outputPerMinute: Double { Double(counts.output) / minutes }
    public var weightedPerMinute: Double { counts.weighted / minutes }

    /// "×10 · 350k ctx": calls in the window and the context each carried.
    public var short: String {
        counts.calls == 0 ? "idle" : "×\(counts.calls) · \(ClaudeBudget.tokens(Double(counts.context))) ctx"
    }

    public var long: String {
        counts.calls == 0 ? "no calls in the last \(Int(minutes)) min" :
            "\(counts.calls) calls in \(Int(minutes)) min, \(ClaudeBudget.tokens(Double(counts.context))) context each, "
            + "\(ClaudeBudget.tokens(outputPerMinute)) output/min, \(ClaudeBudget.tokens(Double(counts.cacheRead) / minutes)) cache read/min, "
            + "weighted \(ClaudeBudget.tokens(weightedPerMinute))/min"
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

    public static func burn(for session: ClaudeSession, home: ClaudeHome, now: Date, window: TimeInterval = ClaudeBudget.window) -> SessionBurn {
        let since = now.addingTimeInterval(-window)
        return SessionBurn(
            pid: session.pid, name: session.name, cwd: session.cwd,
            counts: counts(at: transcriptURLs(for: session, home: home), since: since),
            minutes: window / 60
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

// MARK: - Warning file for the Claude Code hook

/// What the PreToolUse hook hands to a running agent. Written while a limit
/// is forecast to run out before its reset, removed when that clears.
public struct BudgetWarning: Codable, Equatable, Sendable {
    public let active: Bool
    public let row: String
    public let utilization: Double
    public let percentPerHour: Double
    public let emptyIn: String
    public let resetsIn: String
    public let sessions: [SessionBurn]
    public let advice: String
    public let updatedAt: Date

    public static func make(_ forecast: UsageForecast, sessions: [SessionBurn], now: Date) -> BudgetWarning {
        let emptyIn = forecast.emptyIn.map(ClaudeBudget.duration) ?? "never"
        let resetsIn = forecast.resetsIn.map(ClaudeBudget.duration) ?? "unknown"
        let heaviest = sessions.filter { $0.counts.calls > 0 }.sorted { $0.weightedPerMinute > $1.weightedPerMinute }.prefix(3)
        let burners = heaviest.isEmpty ? "no live session made a call in the window" : heaviest
            .map { "\($0.name) (pid \($0.pid), \($0.cwd)): \($0.long)" }
            .joined(separator: "; ")
        let advice = "Vitals budget warning: \(forecast.label) is at \(Int(forecast.utilization.rounded()))% and burning "
            + String(format: "%.1f", forecast.percentPerHour) + "%/h; at this rate it is empty in \(emptyIn), it resets in \(resetsIn). "
            + "Heaviest sessions: \(burners). Every call re-reads the whole context, so a large context is the usual cause: "
            + "compact or start a fresh session for the next task, use smaller models for subagents (opus or sonnet instead of fable), "
            + "avoid re-reading large files, disable MCP servers and plugins you are not using, or stop and let the user decide. "
            + "Advisory only; the user may choose to ignore it."
        return BudgetWarning(
            active: true, row: forecast.label, utilization: forecast.utilization, percentPerHour: forecast.percentPerHour,
            emptyIn: emptyIn, resetsIn: resetsIn, sessions: Array(heaviest), advice: advice, updatedAt: now
        )
    }
}

public enum BudgetWarningStore {
    public static func url(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".config/vitals/budget-warning.json")
    }

    public static func load(from url: URL = url()) -> BudgetWarning? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(BudgetWarning.self, from: data)
    }

    public static func save(_ warning: BudgetWarning, to url: URL = url()) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(warning).write(to: url, options: .atomic)
    }

    public static func clear(at url: URL = url()) {
        try? FileManager.default.removeItem(at: url)
    }
}
