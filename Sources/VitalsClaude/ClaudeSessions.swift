import Foundation

/// A running local Claude Code process, as registered in
/// `~/.claude/sessions/<pid>.json`.
public struct ClaudeSession: Sendable, Equatable, Identifiable {
    /// The registry's `status` field. Claude Code writes `busy`, `shell`,
    /// `idle` and `waiting`.
    public enum Status: String, Sendable, Equatable {
        case busy
        /// Running a shell command; Claude Code's own list shows it as working.
        case shell
        /// Blocked on the user: a permission prompt, a question, other input.
        case waiting
        case idle
        case unknown

        public var isWorking: Bool { self == .busy || self == .shell }
    }

    public let pid: Int32
    public let sessionId: String
    public let name: String
    /// The registry's `kind` field: `interactive` for a terminal session, `bg`
    /// for one the daemon hosts (started in or moved to the background).
    public let kind: String
    public let status: Status
    /// What a `waiting` session waits for, in Claude Code's words.
    public let waitingFor: String?
    public let cwd: String
    public let startedAt: Date
    public let updatedAt: Date
    public let version: String?
    /// The desktop app's `local_<id>` for a Code tab session; nil in a terminal.
    public let hostSessionId: String?
    /// When the process started, from the registry's `procStart`.
    public let processStartedAt: Date?

    public var id: Int32 { pid }

    public init(
        pid: Int32,
        sessionId: String,
        name: String,
        kind: String = "interactive",
        status: Status,
        cwd: String,
        startedAt: Date,
        updatedAt: Date,
        version: String?,
        hostSessionId: String? = nil,
        waitingFor: String? = nil,
        processStartedAt: Date? = nil
    ) {
        self.pid = pid
        self.sessionId = sessionId
        self.name = name
        self.kind = kind
        self.status = status
        self.cwd = cwd
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.version = version
        self.hostSessionId = hostSessionId
        self.waitingFor = waitingFor
        self.processStartedAt = processStartedAt
    }

    /// The kind as Claude Code's ListAgents words it.
    public var displayKind: String {
        kind == "bg" ? "background" : kind
    }

    /// `waiting: input needed` when the registry says what for.
    public var statusText: String {
        guard status == .waiting, let waitingFor, !waitingFor.isEmpty else { return status.rawValue }
        return "\(status.rawValue): \(waitingFor)"
    }

    /// `~/projects/example-app` for display.
    public func abbreviatedCwd(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String {
        if cwd == homeDirectory { return "~" }
        if cwd.hasPrefix(homeDirectory + "/") {
            return "~" + cwd.dropFirst(homeDirectory.count)
        }
        return cwd
    }
}

public struct ClaudeSessionsSnapshot: Sendable, Equatable {
    public let sessions: [ClaudeSession]
    public let capturedAt: Date

    public init(sessions: [ClaudeSession], capturedAt: Date) {
        self.sessions = sessions
        self.capturedAt = capturedAt
    }

    public static let empty = ClaudeSessionsSnapshot(
        sessions: [],
        capturedAt: .distantPast
    )

    public var busyCount: Int {
        sessions.filter { $0.status.isWorking }.count
    }

    public var waitingCount: Int {
        sessions.filter { $0.status == .waiting }.count
    }

    /// `2 busy · 1 waiting · 3 idle`; the waiting part only when a session waits.
    public var summary: String {
        if sessions.isEmpty { return "none running" }
        let busy = busyCount
        let waiting = waitingCount
        var parts = ["\(busy) busy"]
        if waiting > 0 { parts.append("\(waiting) waiting") }
        parts.append("\(sessions.count - busy - waiting) idle")
        return parts.joined(separator: " · ")
    }
}

public enum ClaudeSessionParser {
    /// The kinds Claude Code lists as sessions. Its registry also holds
    /// `daemon` and `daemon-worker`, the background supervisor's own processes.
    static let sessionKinds: Set<String> = ["interactive", "bg", "local"]

    /// Decodes a single `sessions/<pid>.json` registry file. Cloud sessions
    /// never appear on disk; anything with a `kind` outside `sessionKinds` is
    /// skipped so a future registry schema cannot surface them by accident. A
    /// record with `parkedJobId` is the terminal process a session left when it
    /// moved to the background; the `bg` record is that session now. A record
    /// with `spare` is a background process the daemon started ahead of time
    /// and no session has claimed yet. Claude Code's own list skips both.
    public static func parse(_ data: Data) throws -> ClaudeSession? {
        let payload = try JSONDecoder().decode(SessionPayload.self, from: data)
        if let kind = payload.kind, !sessionKinds.contains(kind) {
            return nil
        }
        if payload.parkedJobId?.value != nil || payload.spare?.value == true {
            return nil
        }
        if let entrypoint = payload.entrypoint, entrypoint == "cloud" {
            return nil
        }
        let started = Date(timeIntervalSince1970: Double(payload.startedAt) / 1_000)
        let updated = payload.updatedAt.map {
            Date(timeIntervalSince1970: Double($0) / 1_000)
        } ?? started
        return ClaudeSession(
            pid: payload.pid,
            sessionId: payload.sessionId,
            name: payload.name ?? "claude-\(payload.pid)",
            kind: payload.kind ?? "interactive",
            status: payload.status.flatMap(ClaudeSession.Status.init(rawValue:))
                ?? .unknown,
            cwd: payload.cwd,
            startedAt: started,
            updatedAt: updated,
            version: payload.version,
            hostSessionId: payload.hostSessionId,
            waitingFor: payload.waitingFor?.value,
            processStartedAt: processStart(payload.procStart?.value)
        )
    }

    /// `Tue Nov 10 02:38:36 2026`: the layout of `ps -o lstart`, in UTC.
    static func processStart(_ raw: String?) -> Date? {
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        guard let parts = raw?.split(separator: " "), parts.count == 5 else { return nil }
        let clock = parts[3].split(separator: ":").map { Int($0) }
        guard let month = months.firstIndex(of: String(parts[1])), let day = Int(parts[2]), let year = Int(parts[4]),
              clock.count == 3, let hour = clock[0], let minute = clock[1], let second = clock[2],
              let utc = TimeZone(secondsFromGMT: 0)
        else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let wanted = DateComponents(year: year, month: month + 1, day: day, hour: hour, minute: minute, second: second)
        // A date such as Nov 31 would roll over into the next month.
        guard let date = calendar.date(from: wanted),
              calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date) == wanted
        else { return nil }
        return date
    }

    /// Working sessions first, then waiting ones, then the rest; newest first
    /// within each group.
    public static func sorted(_ sessions: [ClaudeSession]) -> [ClaudeSession] {
        func rank(_ status: ClaudeSession.Status) -> Int {
            if status.isWorking { return 0 }
            return status == .waiting ? 1 : 2
        }
        return sessions.sorted {
            let (left, right) = (rank($0.status), rank($1.status))
            if left != right { return left < right }
            return $0.startedAt > $1.startedAt
        }
    }
}

public enum ClaudeSessionStore {
    /// Registry files whose process has exited are ignored. A file older than
    /// `staleAfter` is also ignored even if its pid is alive, which covers pid
    /// reuse after a crash. Two things lift that cut-off, because the registry
    /// is only rewritten when a session's status changes and a session can idle
    /// for days: the pid is in `keeping` (its arguments already confirmed the
    /// session), or the process started at the moment the record says it did.
    public static func load(
        home: ClaudeHome = ClaudeHome(),
        now: Date = Date(),
        staleAfter: TimeInterval = 86_400,
        keeping: Set<Int32> = [],
        isAlive: (Int32) -> Bool = processIsAlive,
        processStart: (Int32) -> Date? = processStartedAt
    ) -> ClaudeSessionsSnapshot {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: home.sessionsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        var sessions: [ClaudeSession] = []
        for file in files where file.pathExtension == "json" {
            guard Int32(file.deletingPathExtension().lastPathComponent) != nil,
                  let data = try? Data(contentsOf: file),
                  case .some(.some(let session)) = (try? ClaudeSessionParser.parse(data)),
                  isAlive(session.pid),
                  now.timeIntervalSince(session.updatedAt) < staleAfter
                    || keeping.contains(session.pid)
                    || isSameProcess(recorded: session.processStartedAt, actual: processStart(session.pid))
            else { continue }
            sessions.append(session)
        }
        return ClaudeSessionsSnapshot(
            sessions: ClaudeSessionParser.sorted(sessions),
            capturedAt: now
        )
    }

    public static func processIsAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// The kernel's start time of a process; nil when it exited or belongs to
    /// another user.
    public static func processStartedAt(_ pid: Int32) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: Double(info.pbi_start_tvsec))
    }

    /// The registry records whole seconds, taken a moment after the start.
    static func isSameProcess(recorded: Date?, actual: Date?) -> Bool {
        guard let recorded, let actual else { return false }
        return abs(recorded.timeIntervalSince(actual)) <= 2
    }
}

private struct SessionPayload: Decodable {
    let pid: Int32
    let sessionId: String
    let cwd: String
    let startedAt: Int64
    let updatedAt: Int64?
    let name: String?
    let status: String?
    let kind: String?
    let entrypoint: String?
    let version: String?
    let hostSessionId: String?
    let waitingFor: Lenient<String>?
    let parkedJobId: Lenient<String>?
    let spare: Lenient<Bool>?
    let procStart: Lenient<String>?
}

/// A field newer Claude Code versions added. A value of another JSON type
/// reads as absent, as Claude Code itself treats it, instead of failing the
/// whole record and hiding the session.
private struct Lenient<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? decoder.singleValueContainer().decode(Value.self)
    }
}

/// Plain-text form of the session list, shaped like Claude Code's own
/// ListAgents output so it can be pasted straight into a chat, plus the
/// fields only Vitals knows (pid, cwd, full session id, version). No short
/// bracketed ref: Claude Code derives that one internally and does not write
/// it to the registry file, and the name alone is the messaging address.
public enum ClaudeSessionText {
    public static let separator = "  ·  "

    public static func line(_ session: ClaudeSession) -> String {
        var parts = [
            session.name,
            session.displayKind,
            session.statusText,
            "pid \(session.pid)",
            session.cwd,
            "session \(session.sessionId)"
        ]
        if let version = session.version {
            parts.append("Claude Code \(version)")
        }
        return parts.joined(separator: separator)
    }

    /// One line per session, newline-terminated, in registry order
    /// (working first, then waiting, then the rest; newest first in each).
    public static func lines(_ sessions: [ClaudeSession]) -> String {
        sessions.map(line).map { $0 + "\n" }.joined()
    }
}
