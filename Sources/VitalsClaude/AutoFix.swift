import Foundation

// MARK: - Auto-fix pull requests of the Claude desktop app

/// A pull request the desktop app bound to a Code session, from the `prs`
/// list of `~/Library/Application Support/Claude/claude-code-sessions/<account>/<org>/local_<id>.json`.
/// The app watches GitHub itself and wakes the session with a
/// `<ci-monitor-event>` user message; between events the process idles.
public struct BoundPullRequest: Codable, Equatable, Sendable {
    public let number: Int
    public let repo: String
    public let branch: String?
    public let baseRef: String?
    /// OPEN, MERGED or CLOSED as the app last saw it.
    public let state: String?
    public let autoFix: Bool
    public let dismissed: Bool

    public init(number: Int, repo: String, branch: String? = nil, baseRef: String? = nil, state: String? = "OPEN", autoFix: Bool = true, dismissed: Bool = false) {
        self.number = number
        self.repo = repo
        self.branch = branch
        self.baseRef = baseRef
        self.state = state
        self.autoFix = autoFix
        self.dismissed = dismissed
    }

    public var reference: String { "\(repo)#\(number)" }
}

/// The desktop app's record of one Code session. Auto-merge is not stored
/// here: it is GitHub's own `auto_merge` on the PR.
public struct DesktopCodeSession: Equatable, Sendable {
    /// `local_<id>`, the session registry's `hostSessionId`.
    public let localId: String
    /// The conversation id the app passes to `claude --resume=`.
    public let cliSessionId: String?
    public let isArchived: Bool
    public let autoArchiveOnPrClose: Bool
    public let prs: [BoundPullRequest]

    public init(localId: String, cliSessionId: String?, isArchived: Bool = false, autoArchiveOnPrClose: Bool = false, prs: [BoundPullRequest]) {
        self.localId = localId
        self.cliSessionId = cliSessionId
        self.isArchived = isArchived
        self.autoArchiveOnPrClose = autoArchiveOnPrClose
        self.prs = prs
    }

    /// The first bound PR with Auto-fix on that the user did not dismiss.
    public var autoFixPR: BoundPullRequest? { prs.first { $0.autoFix && !$0.dismissed } }
}

public enum DesktopSessionStore {
    public static func directory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)
    }

    public static func parse(_ data: Data) -> DesktopCodeSession? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let localId = object["sessionId"] as? String
        else { return nil }
        let prs = (object["prs"] as? [[String: Any]] ?? []).compactMap { pr -> BoundPullRequest? in
            guard let number = pr["prNumber"] as? Int, let repo = pr["repo"] as? String else { return nil }
            return BoundPullRequest(
                number: number, repo: repo, branch: pr["branch"] as? String, baseRef: pr["baseRef"] as? String,
                state: pr["state"] as? String, autoFix: pr["autoFix"] as? Bool == true, dismissed: pr["dismissed"] as? Bool == true
            )
        }
        return DesktopCodeSession(
            localId: localId,
            cliSessionId: object["cliSessionId"] as? String,
            isArchived: object["isArchived"] as? Bool == true,
            autoArchiveOnPrClose: object["autoArchiveOnPrClose"] as? Bool == true,
            prs: prs
        )
    }

    /// Every `local_*.json` under `<account>/<org>/`. Read-only.
    public static func load(directory: URL = directory()) -> [DesktopCodeSession] {
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var sessions: [DesktopCodeSession] = []
        for case let file as URL in files where file.lastPathComponent.hasPrefix("local_") && file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file), let session = parse(data) { sessions.append(session) }
        }
        return sessions
    }
}

/// A live auto-fix session: the desktop record, its process and what
/// GitHub and the transcript say about it.
public struct AutoFixSession: Equatable, Sendable {
    public let pid: Int32
    public let localId: String
    public let cliSessionId: String?
    public let pr: BoundPullRequest
    public let autoArchiveOnPrClose: Bool
    public var activity: AutoFixActivity?
    public var status: PullRequestStatus?

    public init(pid: Int32, localId: String, cliSessionId: String?, pr: BoundPullRequest, autoArchiveOnPrClose: Bool = false, activity: AutoFixActivity? = nil, status: PullRequestStatus? = nil) {
        self.pid = pid
        self.localId = localId
        self.cliSessionId = cliSessionId
        self.pr = pr
        self.autoArchiveOnPrClose = autoArchiveOnPrClose
        self.activity = activity
        self.status = status
    }
}

public enum AutoFixMatch {
    /// The `claude` process the app started for this conversation: a resumed
    /// session carries `--resume=<id>`. Several sessions share one working
    /// directory, so the folder says nothing. The `disclaimer` wrapper repeats
    /// the arguments, so only an executable named `claude` counts.
    public static func pid(cliSessionId id: String, arguments: [Int32: [String]]) -> Int32? {
        for (pid, args) in arguments.sorted(by: { $0.key < $1.key }) {
            guard isClaude(args) else { continue }
            for (index, argument) in args.enumerated() {
                if argument == "--resume=\(id)" || argument == "--session-id=\(id)" { return pid }
                if ["--resume", "-r", "--session-id"].contains(argument), index + 1 < args.count, args[index + 1] == id { return pid }
            }
        }
        return nil
    }

    /// A registry pid reused by another program after a crash is not a session.
    static func isClaude(_ arguments: [String]?) -> Bool {
        guard let executable = arguments?.first else { return arguments == nil }
        return (executable as NSString).lastPathComponent == "claude"
    }

    /// Unarchived records with an auto-fix PR, keyed by process. A session
    /// started fresh has no id in its arguments; the registry file its own
    /// process wrote (`hostSessionId`) maps it instead.
    public static func sessions(records: [DesktopCodeSession], registry: [ClaudeSession], arguments: [Int32: [String]]) -> [Int32: AutoFixSession] {
        var result: [Int32: AutoFixSession] = [:]
        for record in records where !record.isArchived {
            guard let pr = record.autoFixPR,
                  let pid = record.cliSessionId.flatMap({ pid(cliSessionId: $0, arguments: arguments) })
                    ?? registry.first(where: { $0.hostSessionId == record.localId && isClaude(arguments[$0.pid]) })?.pid
            else { continue }
            result[pid] = AutoFixSession(pid: pid, localId: record.localId, cliSessionId: record.cliSessionId, pr: pr, autoArchiveOnPrClose: record.autoArchiveOnPrClose)
        }
        return result
    }
}

// MARK: GitHub state

public struct PullRequestStatus: Codable, Equatable, Sendable {
    public enum CI: String, Codable, Sendable {
        case passing
        case failing
        case pending
        /// A workflow run from a fork waits for a maintainer (`action_required`).
        case approval = "waiting for approval"
        case none
    }

    /// OPEN, MERGED or CLOSED.
    public let state: String
    public let ci: CI
    public let failingChecks: [String]
    /// APPROVED, CHANGES_REQUESTED, REVIEW_REQUIRED, or nil when none applies.
    public let reviewDecision: String?
    /// MERGEABLE, CONFLICTING or UNKNOWN.
    public let mergeable: String?
    public let autoMerge: Bool
    public let fetchedAt: Date

    public init(state: String, ci: CI, failingChecks: [String] = [], reviewDecision: String? = nil, mergeable: String? = nil, autoMerge: Bool = false, fetchedAt: Date) {
        self.state = state
        self.ci = ci
        self.failingChecks = failingChecks
        self.reviewDecision = reviewDecision
        self.mergeable = mergeable
        self.autoMerge = autoMerge
        self.fetchedAt = fetchedAt
    }

    public var isFinal: Bool { state == "MERGED" || state == "CLOSED" }

    /// `pr` is `gh pr view --json statusCheckRollup,reviewDecision,mergeable,state,headRefOid,autoMergeRequest`,
    /// `runs` is `gh run list --commit <head> --json status,conclusion,workflowName`.
    public static func parse(pr: Data, runs: Data?, at date: Date) -> PullRequestStatus? {
        guard let object = try? JSONSerialization.jsonObject(with: pr) as? [String: Any],
              let state = object["state"] as? String
        else { return nil }
        var failing: [String] = []
        var pending = false
        var approval = false
        var seen = false
        for check in object["statusCheckRollup"] as? [[String: Any]] ?? [] {
            seen = true
            let name = (check["name"] as? String) ?? (check["context"] as? String) ?? "check"
            if let status = check["status"] as? String {
                guard status == "COMPLETED" else { pending = true; continue }
                switch check["conclusion"] as? String ?? "" {
                case "SUCCESS", "NEUTRAL", "SKIPPED": break
                case "ACTION_REQUIRED": approval = true
                default: failing.append(name)
                }
            } else {
                switch check["state"] as? String ?? "" {
                case "SUCCESS": break
                case "PENDING", "EXPECTED": pending = true
                default: failing.append(name)
                }
            }
        }
        let runList = runs.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
        for run in runList {
            seen = true
            let status = (run["status"] as? String ?? "").lowercased()
            let conclusion = (run["conclusion"] as? String ?? "").lowercased()
            if status == "action_required" || conclusion == "action_required" {
                approval = true
            } else if status != "completed" {
                pending = true
            } else if ["failure", "timed_out", "startup_failure"].contains(conclusion) {
                let name = run["workflowName"] as? String ?? "workflow"
                if !failing.contains(name) { failing.append(name) }
            }
        }
        let ci: CI = !failing.isEmpty ? .failing : approval ? .approval : pending ? .pending : seen ? .passing : .none
        let review = object["reviewDecision"] as? String
        return PullRequestStatus(
            state: state, ci: ci, failingChecks: failing,
            reviewDecision: review?.isEmpty == false ? review : nil,
            mergeable: object["mergeable"] as? String,
            autoMerge: object["autoMergeRequest"] is [String: Any],
            fetchedAt: date
        )
    }
}

public enum GitHubPullRequests {
    /// Read each PR at most once a minute.
    public static let refreshInterval: TimeInterval = 60

    public static func executable(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", home.appendingPathComponent(".local/bin/gh").path, "/usr/bin/gh"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Two read-only `gh` calls; blocks, so call it off the main actor.
    public static func fetch(_ pr: BoundPullRequest, now: Date = Date()) -> PullRequestStatus? {
        guard let gh = executable(),
              let view = run(gh, ["pr", "view", "\(pr.number)", "--repo", pr.repo, "--json",
                                  "statusCheckRollup,reviewDecision,mergeable,state,headRefOid,autoMergeRequest"])
        else { return nil }
        let head = (try? JSONSerialization.jsonObject(with: view) as? [String: Any])?["headRefOid"] as? String
        let runs = head.flatMap { run(gh, ["run", "list", "--repo", pr.repo, "--commit", $0, "--limit", "20", "--json", "status,conclusion,workflowName"]) }
        return PullRequestStatus.parse(pr: view, runs: runs, at: now)
    }

    private static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 20) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["NO_COLOR"] = "1"
        process.environment = environment
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        return process.terminationStatus == 0 ? data : nil
    }
}

// MARK: Events from the transcript

/// The last `<ci-monitor-event>` the app sent and what the session did
/// before the user next wrote.
public struct AutoFixActivity: Codable, Equatable, Sendable {
    /// "CI failure", "merge conflict", "review comment", "auto-fix enabled".
    public let kinds: [String]
    public let at: Date
    /// Short sha of the last push after the event, "" when the push output had none.
    public var pushed: String?
    public var replied = false
    /// No human message since the event: a busy session is working on it.
    public var unanswered = true

    public init(kinds: [String], at: Date, pushed: String? = nil, replied: Bool = false, unanswered: Bool = true) {
        self.kinds = kinds
        self.at = at
        self.pushed = pushed
        self.replied = replied
        self.unanswered = unanswered
    }

    /// "pushed 4deb8d9, replied", "replied" or "nothing".
    public var action: String {
        var parts: [String] = []
        if let pushed { parts.append(pushed.isEmpty ? "pushed" : "pushed \(pushed)") }
        if replied { parts.append("replied") }
        return parts.isEmpty ? "nothing" : parts.joined(separator: ", ")
    }
}

public enum AutoFixEvents {
    static let marker = "<ci-monitor-event>"

    /// Classifies by the app's own sentences, never by the quoted GitHub
    /// text after "Quoted from GitHub" whose lines start with ">".
    public static func kinds(_ text: String) -> [String] {
        if text.contains("was just enabled for this session") { return ["auto-fix enabled"] }
        let own = text.components(separatedBy: "Quoted from GitHub").first ?? text
        let entries = text.split(separator: "\n").filter { !$0.hasPrefix(">") }
        var kinds: [String] = []
        if entries.contains(where: { $0.hasPrefix("Failing checks (") }) { kinds.append("CI failure") }
        if own.contains("has merge conflicts") || own.contains("unresolved merge conflicts") { kinds.append("merge conflict") }
        if own.contains("new review comment") || entries.contains(where: { $0.hasPrefix("Comment 1 ") }) { kinds.append("review comment") }
        return kinds.isEmpty ? ["event"] : kinds
    }

    public static func last(in text: String) -> AutoFixActivity? {
        var activity: AutoFixActivity?
        var awaitingPushOutput = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let tracking = activity?.unanswered == true
            guard line.contains(marker) || line.contains("\"kind\":\"human\"")
                    || (tracking && (line.contains("git push") || line.contains("gh api") || line.contains("gh pr comment")
                                     || line.contains("gh pr review") || (awaitingPushOutput && line.contains("->")))),
                  let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = object["message"] as? [String: Any]
            else { continue }
            let blocks: [[String: Any]]
            if let content = message["content"] as? String {
                blocks = [["type": "text", "text": content]]
            } else {
                blocks = message["content"] as? [[String: Any]] ?? []
            }
            switch object["type"] as? String {
            case "user":
                let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
                if text.hasPrefix(marker), let stamp = object["timestamp"] as? String, let date = ClaudeTranscripts.date(stamp) {
                    activity = AutoFixActivity(kinds: kinds(text), at: date)
                    awaitingPushOutput = false
                } else if (object["origin"] as? [String: Any])?["kind"] as? String == "human", !text.isEmpty {
                    activity?.unanswered = false
                } else if tracking, awaitingPushOutput {
                    for block in blocks where block["type"] as? String == "tool_result" {
                        if let sha = pushedSha(resultText(block["content"])) {
                            activity?.pushed = sha
                            awaitingPushOutput = false
                        }
                    }
                }
            case "assistant" where tracking:
                for block in blocks where block["type"] as? String == "tool_use" {
                    guard let command = (block["input"] as? [String: Any])?["command"] as? String else { continue }
                    if command.contains("git push") {
                        if activity?.pushed == nil { activity?.pushed = "" }
                        awaitingPushOutput = true
                    }
                    if command.contains("gh pr comment") || command.contains("gh pr review")
                        || (command.contains("gh api") && (command.contains("/replies") || command.contains("/comments") || command.contains("resolveReviewThread"))) {
                        activity?.replied = true
                    }
                }
            default:
                continue
            }
        }
        return activity
    }

    /// Reads the whole transcript: an event can lie hours of work back.
    public static func last(at url: URL) -> AutoFixActivity? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return last(in: String(decoding: data, as: UTF8.self))
    }

    /// `   4deb8d9..da8f1b6  branch -> branch` from `git push` output.
    static func pushedSha(_ output: String) -> String? {
        for line in output.split(separator: "\n") where line.contains("->") {
            for word in line.split(separator: " ") where word.contains("..") {
                let parts = word.replacingOccurrences(of: "...", with: "..").components(separatedBy: "..")
                if parts.count == 2, let new = parts.last, new.count >= 7, new.allSatisfy(\.isHexDigit) {
                    return String(new.prefix(7))
                }
            }
        }
        return nil
    }

    private static func resultText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        return (content as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
}

// MARK: State and text

public enum AutoFixState: Equatable, Sendable {
    /// Nothing to do: calm blue.
    case watching
    /// Woken by an event and still on it: amber.
    case working
    /// "CI failing" or "merge conflict": red.
    case failing(String)
    /// A fork's workflow run waits for a maintainer: gray.
    case approval
    /// CI green and mergeable: green.
    case ready
    /// "merged" or "closed": dimmed.
    case closed(String)

    public var label: String {
        switch self {
        case .watching: "watching"
        case .working: "working on event"
        case let .failing(reason): reason
        case .approval: "waiting for approval"
        case .ready: "CI green, mergeable"
        case let .closed(state): state
        }
    }
}

public enum AutoFix {
    public static func state(_ session: AutoFixSession, busy: Bool) -> AutoFixState {
        switch (session.status?.state ?? session.pr.state ?? "OPEN").uppercased() {
        case "MERGED": return .closed("merged")
        case "CLOSED": return .closed("closed")
        default: break
        }
        if busy, session.activity?.unanswered == true { return .working }
        guard let status = session.status else { return .watching }
        if status.ci == .failing { return .failing("CI failing") }
        if status.mergeable == "CONFLICTING" { return .failing("merge conflict") }
        if status.ci == .approval { return .approval }
        if status.ci == .passing, status.mergeable == "MERGEABLE" { return .ready }
        return .watching
    }

    public static func marker(_ pr: BoundPullRequest) -> String { "AUTO-FIX #\(pr.number)" }

    /// "Fallout-build/Fallout#700 · bugfix/migrate-paths-and-sdk-pin".
    public static func reference(_ pr: BoundPullRequest) -> String {
        [pr.reference, pr.branch].compactMap { $0 }.joined(separator: " · ")
    }

    /// "CI waiting for approval · review none · mergeable · auto-merge off".
    public static func checks(_ session: AutoFixSession) -> String {
        guard let status = session.status else { return "GitHub not read yet" }
        let ci: String
        switch status.ci {
        case .passing: ci = "CI passing"
        case .failing: ci = "CI failing" + (status.failingChecks.isEmpty ? "" : ": " + status.failingChecks.prefix(2).joined(separator: ", "))
        case .pending: ci = "CI pending"
        case .approval: ci = "CI waiting for approval"
        case .none: ci = "no CI"
        }
        let review: String
        switch status.reviewDecision {
        case "APPROVED": review = "approved"
        case "CHANGES_REQUESTED": review = "changes requested"
        case "REVIEW_REQUIRED": review = "review required"
        default: review = "review none"
        }
        let mergeable: String
        switch status.mergeable {
        case "MERGEABLE": mergeable = "mergeable"
        case "CONFLICTING": mergeable = "conflicting"
        default: mergeable = "mergeable unknown"
        }
        var parts = [ci, review, mergeable, status.autoMerge ? "auto-merge on" : "auto-merge off"]
        if session.autoArchiveOnPrClose { parts.append("archive on close") }
        return parts.joined(separator: " · ")
    }

    /// "review comment 16h ago → nothing".
    public static func event(_ activity: AutoFixActivity?, now: Date, working: Bool) -> String {
        guard let activity else { return "no event yet" }
        let action = working ? "working" : activity.action
        return "\(activity.kinds.joined(separator: ", ")) \(ago(activity.at, now: now)) → \(action)"
    }

    static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h ago" }
        return "\(Int(seconds / 86_400))d ago"
    }
}
