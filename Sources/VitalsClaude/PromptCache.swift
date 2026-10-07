import Foundation

// MARK: - Prompt cache from the transcripts

/// The prompt-cache state of one conversation, a session's main thread or one
/// subagent, from the usage blocks of its assistant entries. A request that
/// reads the cache keeps it warm; it goes cold one TTL after the last request.
/// Status line JSON would carry the same facts, but only a status line command
/// receives it, and desktop sessions and subagents have none.
public struct PromptCache: Codable, Equatable, Sendable {
    public enum TTLSource: String, Codable, Sendable {
        /// The ephemeral bucket the last writing request used.
        case observed
        /// `promptCacheTtl` / `subagentPromptCacheTtl` or their environment variables.
        case setting
        case standard = "default"
    }

    public enum MissCause: String, Codable, Sendable {
        case expired
        case modelSwitch = "model switch"
        case effortChange = "effort change"
        case fastMode = "fast mode"
        case compaction
        case upgrade = "Claude Code upgrade"
    }

    /// 300 or 3 600 seconds.
    public let ttl: TimeInterval
    public let ttlSource: TTLSource
    public let lastRequestAt: Date
    public let requests: Int
    /// Requests that paid most of the prompt again instead of reading it.
    public let misses: Int
    /// Tokens those misses wrote back into the cache.
    public let missRecacheTokens: Int
    public let lastMissAt: Date?
    public let lastMissCause: MissCause?
    /// Cache reads over all prompt tokens, 0...1.
    public let hitRatio: Double
    /// Prompt size of the last request: what the next message writes again
    /// once the cache is cold.
    public let recacheTokens: Int
    /// Claude Code version that sent the last request.
    public let version: String?

    public init(
        ttl: TimeInterval, ttlSource: TTLSource = .observed, lastRequestAt: Date, requests: Int, misses: Int = 0,
        missRecacheTokens: Int = 0, lastMissAt: Date? = nil, lastMissCause: MissCause? = nil,
        hitRatio: Double, recacheTokens: Int, version: String? = nil
    ) {
        self.ttl = ttl
        self.ttlSource = ttlSource
        self.lastRequestAt = lastRequestAt
        self.requests = requests
        self.misses = misses
        self.missRecacheTokens = missRecacheTokens
        self.lastMissAt = lastMissAt
        self.lastMissCause = lastMissCause
        self.hitRatio = hitRatio
        self.recacheTokens = recacheTokens
        self.version = version
    }

    public var expiresAt: Date { lastRequestAt.addingTimeInterval(ttl) }

    public func remaining(now: Date) -> TimeInterval { max(0, expiresAt.timeIntervalSince(now)) }

    public func isWarm(now: Date) -> Bool { now < expiresAt }

    /// Warm with less than a fifth of the TTL left.
    public func isExpiring(now: Date) -> Bool { isWarm(now: now) && remaining(now: now) < ttl * 0.2 }
}

/// A subagent transcript under `<session>/subagents`, labelled from its
/// `.meta.json` description.
public struct SubagentCache: Codable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let cache: PromptCache

    public init(id: String, label: String, cache: PromptCache) {
        self.id = id
        self.label = label
        self.cache = cache
    }
}

public struct SessionCache: Codable, Equatable, Sendable {
    /// Nil until the session's first API response.
    public let main: PromptCache?
    public let subagents: [SubagentCache]
    /// At most one, and only where it applies.
    public let hint: String?

    public init(main: PromptCache?, subagents: [SubagentCache] = [], hint: String? = nil) {
        self.main = main
        self.subagents = subagents
        self.hint = hint
    }
}

/// TTL overrides from `settings.json` (`promptCacheTtl`, `subagentPromptCacheTtl`,
/// or the same as `CLAUDE_CODE_PROMPT_CACHE_TTL` / `CLAUDE_CODE_SUBAGENT_PROMPT_CACHE_TTL`
/// in its `env` block or Vitals' own environment). Used only when no request
/// in the tail wrote to the cache; an observed bucket always wins.
public struct CacheTTLConfig: Equatable, Sendable {
    public var main: TimeInterval?
    public var subagent: TimeInterval?

    public init(main: TimeInterval? = nil, subagent: TimeInterval? = nil) {
        self.main = main
        self.subagent = subagent
    }

    /// Subscription within plan usage: the main conversation gets 1h,
    /// subagents, forks and compaction 5m.
    public static let mainDefault: TimeInterval = 3_600
    public static let subagentDefault: TimeInterval = 300

    public static func seconds(_ raw: String?) -> TimeInterval? {
        switch raw?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "5m": 300
        case "1h": 3_600
        default: nil
        }
    }

    public static func parse(settings: Data?, environment: [String: String]) -> CacheTTLConfig {
        let object = settings.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let env = object["env"] as? [String: Any] ?? [:]
        func pick(_ variable: String, _ setting: String) -> TimeInterval? {
            seconds(environment[variable]) ?? seconds(env[variable] as? String) ?? seconds(object[setting] as? String)
        }
        return CacheTTLConfig(
            main: pick("CLAUDE_CODE_PROMPT_CACHE_TTL", "promptCacheTtl"),
            subagent: pick("CLAUDE_CODE_SUBAGENT_PROMPT_CACHE_TTL", "subagentPromptCacheTtl")
        )
    }

    public static func load(home: ClaudeHome = ClaudeHome(), environment: [String: String] = ProcessInfo.processInfo.environment) -> CacheTTLConfig {
        parse(settings: try? Data(contentsOf: home.settingsURL), environment: environment)
    }
}

public enum PromptCacheParser {
    private struct Request {
        var at: Date
        var model: String?
        var effort: String?
        var speed: String?
        var version: String?
        var input = 0
        var write = 0
        var read = 0
        var write1h = 0
        var write5m = 0
        /// Events between the previous request and this one.
        var marksBefore: Set<PromptCache.MissCause> = []
        var total: Int { input + write + read }
    }

    /// Below this many freshly written tokens a smaller cache read is a
    /// growing conversation, not a miss.
    static let missFloor = 1_024

    /// Nil until the transcript has an assistant entry with usage.
    public static func parse(_ text: String, subagent: Bool, configured: TimeInterval? = nil) -> PromptCache? {
        var requests: [String: Request] = [:]
        var order: [String] = []
        var pendingMarks: Set<PromptCache.MissCause> = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let isCompaction = line.contains("compact_boundary")
            guard line.contains("\"usage\"") || isCompaction,
                  let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if !subagent, object["isSidechain"] as? Bool == true { continue }
            if isCompaction, object["type"] as? String == "system", object["subtype"] as? String == "compact_boundary" {
                pendingMarks.insert(.compaction)
                continue
            }
            guard object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  message["model"] as? String != "<synthetic>",
                  let stamp = object["timestamp"] as? String,
                  let date = ClaudeTranscripts.date(stamp)
            else { continue }
            let creation = usage["cache_creation"] as? [String: Any] ?? [:]
            var request = Request(
                at: date,
                model: message["model"] as? String,
                effort: object["effort"] as? String,
                speed: usage["speed"] as? String,
                version: object["version"] as? String,
                input: usage["input_tokens"] as? Int ?? 0,
                write: usage["cache_creation_input_tokens"] as? Int ?? 0,
                read: usage["cache_read_input_tokens"] as? Int ?? 0,
                write1h: creation["ephemeral_1h_input_tokens"] as? Int ?? 0,
                write5m: creation["ephemeral_5m_input_tokens"] as? Int ?? 0
            )
            guard request.total > 0 else { continue }
            // Streaming writes one line per content block, all with the
            // message's usage; the last one carries the final numbers.
            let key = (message["id"] as? String) ?? (object["requestId"] as? String) ?? stamp
            if let existing = requests[key] {
                request.marksBefore = existing.marksBefore
                request.at = existing.at
            } else {
                order.append(key)
                request.marksBefore = pendingMarks
                pendingMarks = []
            }
            requests[key] = request
        }
        guard !order.isEmpty else { return nil }

        let fallback = configured ?? (subagent ? CacheTTLConfig.subagentDefault : CacheTTLConfig.mainDefault)
        var ttl: TimeInterval?
        var misses = 0
        var missTokens = 0
        var lastMissAt: Date?
        var lastMissCause: PromptCache.MissCause?
        var read = 0
        var total = 0
        var previous: Request?
        for key in order {
            let request = requests[key]!
            if let previous {
                let previousTTL = ttl ?? fallback
                if request.read < previous.total / 2, request.write + request.input >= missFloor {
                    misses += 1
                    missTokens += request.write
                    lastMissAt = request.at
                    lastMissCause = cause(request, after: previous, ttl: previousTTL)
                }
            }
            if request.write1h > 0 || request.write5m > 0 {
                ttl = request.write1h >= request.write5m ? 3_600 : 300
            }
            read += request.read
            total += request.total
            previous = request
        }
        let last = requests[order.last!]!
        return PromptCache(
            ttl: ttl ?? fallback,
            ttlSource: ttl != nil ? .observed : (configured != nil ? .setting : .standard),
            lastRequestAt: last.at,
            requests: order.count,
            misses: misses,
            missRecacheTokens: missTokens,
            lastMissAt: lastMissAt,
            lastMissCause: lastMissCause,
            hitRatio: total == 0 ? 0 : Double(read) / Double(total),
            recacheTokens: last.total,
            version: last.version
        )
    }

    private static func cause(_ request: Request, after previous: Request, ttl: TimeInterval) -> PromptCache.MissCause? {
        if request.at.timeIntervalSince(previous.at) > ttl { return .expired }
        if request.marksBefore.contains(.compaction) { return .compaction }
        if let model = request.model, let before = previous.model, model != before { return .modelSwitch }
        if let version = request.version, let before = previous.version, version != before { return .upgrade }
        if request.speed == "fast", previous.speed != "fast" { return .fastMode }
        if let effort = request.effort, let before = previous.effort, effort != before { return .effortChange }
        return nil
    }
}

public enum PromptCacheScanner {
    /// Subagents whose transcript changed in this window are listed; older
    /// ones finished long ago.
    public static let subagentWindow: TimeInterval = 30 * 60
    public static let maxSubagents = 3

    public static func scan(
        _ session: ClaudeSession, home: ClaudeHome, config: CacheTTLConfig, now: Date
    ) -> SessionCache {
        let project = home.root.appendingPathComponent("projects/\(ClaudeTranscripts.slug(session.cwd))")
        let main = ClaudeTranscripts.tail(project.appendingPathComponent("\(session.sessionId).jsonl"))
            .flatMap { PromptCacheParser.parse($0, subagent: false, configured: config.main) }
        var subagents: [SubagentCache] = []
        let directory = project.appendingPathComponent("\(session.sessionId)/subagents")
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        )) ?? []
        for file in files where file.pathExtension == "jsonl" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            guard now.timeIntervalSince(modified) < subagentWindow,
                  let text = ClaudeTranscripts.tail(file),
                  let cache = PromptCacheParser.parse(text, subagent: true, configured: config.subagent)
            else { continue }
            let id = file.deletingPathExtension().lastPathComponent
            subagents.append(SubagentCache(id: id, label: label(meta: directory.appendingPathComponent("\(id).meta.json"), id: id), cache: cache))
        }
        subagents.sort { $0.cache.lastRequestAt > $1.cache.lastRequestAt }
        let instructions = [
            home.root.appendingPathComponent("CLAUDE.md"),
            URL(fileURLWithPath: session.cwd).appendingPathComponent("CLAUDE.md"),
            URL(fileURLWithPath: session.cwd).appendingPathComponent("CLAUDE.local.md"),
            URL(fileURLWithPath: session.cwd).appendingPathComponent(".claude/CLAUDE.md")
        ]
        let instructionsEdited = instructions.contains { url in
            guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return false }
            return date > session.startedAt
        }
        return SessionCache(
            main: main,
            subagents: Array(subagents.prefix(maxSubagents)),
            hint: PromptCacheText.hint(main, runningVersion: session.version, instructionsEdited: instructionsEdited, now: now)
        )
    }

    private static func label(meta: URL, id: String) -> String {
        guard let data = try? Data(contentsOf: meta),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return id }
        return (object["description"] as? String) ?? (object["agentType"] as? String) ?? id
    }
}

public enum PromptCacheText {
    /// A large cold session where Pro and Max offer resuming from a summary.
    public static let largeSession = 100_000

    public static func ttl(_ seconds: TimeInterval) -> String {
        seconds >= 3_600 ? "\(Int(seconds / 3_600))h" : "\(Int(seconds / 60))m"
    }

    /// "912k": always in thousands.
    public static func kilo(_ tokens: Int) -> String {
        "\(max(1, Int((Double(tokens) / 1_000).rounded())))k"
    }

    /// Five cells, one per fifth of the TTL still left, rounded up.
    public static func bar(_ cache: PromptCache, now: Date) -> String {
        let filled = min(5, Int((cache.remaining(now: now) / cache.ttl * 5).rounded(.up)))
        return String(repeating: "▓", count: filled) + String(repeating: "░", count: 5 - filled)
    }

    public static func left(_ cache: PromptCache, now: Date) -> String {
        let seconds = Int(cache.remaining(now: now))
        return seconds >= 60 ? "\(seconds / 60)m left" : "\(seconds)s left"
    }

    /// "cache ● 1h ▓▓▓▓░ 38m left · hit 91% · misses 0" or
    /// "cache ○ cold · next message re-caches 912k tokens · last miss: expired".
    public static func line(_ cache: PromptCache, now: Date) -> String {
        if cache.isWarm(now: now) {
            return "cache ● \(ttl(cache.ttl)) \(bar(cache, now: now)) \(left(cache, now: now))"
                + " · hit \(Int((cache.hitRatio * 100).rounded()))% · misses \(cache.misses)"
        }
        return "cache ○ cold · next message re-caches \(kilo(cache.recacheTokens)) tokens"
            + (cache.lastMissCause.map { " · last miss: \($0.rawValue)" } ?? "")
    }

    /// "↳ Verify candidates · ● 5m ▓▓░░░ 2m left · misses 1, re-paid 180k";
    /// the misses only when there were some.
    public static func subagentLine(_ subagent: SubagentCache, now: Date) -> String {
        let cache = subagent.cache
        let state = cache.isWarm(now: now)
            ? "● \(ttl(cache.ttl)) \(bar(cache, now: now)) \(left(cache, now: now))"
            : "○ cold · re-caches \(kilo(cache.recacheTokens))"
        let misses = cache.misses == 0 ? "" : " · misses \(cache.misses), re-paid \(kilo(cache.missRecacheTokens))"
        return "↳ \(subagent.label) · \(state)\(misses)"
    }

    /// One hint at most, in this order: a large cold session, a pending
    /// upgrade, a change that just forced a re-read, an edited CLAUDE.md.
    /// A cold cache re-reads everything anyway, so it gets no re-read hint.
    public static func hint(_ cache: PromptCache?, runningVersion: String?, instructionsEdited: Bool, now: Date) -> String? {
        guard let cache else { return nil }
        if !cache.isWarm(now: now) {
            if cache.recacheTokens >= largeSession { return "large and cold: resume from summary" }
            return instructionsEdited ? instructionsHint : nil
        }
        if let running = runningVersion, let last = cache.version, running != last {
            return "Claude Code upgrade: expect one full re-read"
        }
        if let cause = cache.lastMissCause, cache.lastMissAt == cache.lastRequestAt {
            switch cause {
            case .compaction:
                return "wrong path: /rewind keeps the existing cache, /compact builds a new one"
            case .modelSwitch, .effortChange, .fastMode, .upgrade:
                return "\(cause.rawValue): expect one full re-read"
            case .expired:
                break
            }
        }
        return instructionsEdited ? instructionsHint : nil
    }

    static let instructionsHint = "CLAUDE.md edited: cache kept, applies after /clear, /compact or a restart"
}
