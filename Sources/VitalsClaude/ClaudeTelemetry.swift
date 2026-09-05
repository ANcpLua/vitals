import Foundation

public enum ClaudeHealthLevel: Sendable, Equatable {
    case operational
    case degraded
    case outage
    case unavailable

    var alertRank: Int {
        switch self {
        case .operational: 0
        case .degraded: 1
        case .outage: 2
        case .unavailable: -1
        }
    }
}

public struct ClaudeHealth: Sendable, Equatable {
    public let level: ClaudeHealthLevel
    public let label: String
    public let detail: String

    public init(level: ClaudeHealthLevel, label: String, detail: String) {
        self.level = level
        self.label = label
        self.detail = detail
    }
}

public struct ClaudeUsageRow: Sendable, Equatable {
    public let id: String
    public let label: String
    public let fraction: Double
    public let detail: String
    public let utilization: Double

    public init(
        id: String,
        label: String,
        fraction: Double,
        detail: String,
        utilization: Double
    ) {
        self.id = id
        self.label = label
        self.fraction = fraction
        self.detail = detail
        self.utilization = utilization
    }
}

public enum ClaudeUsageState: Sendable, Equatable {
    case available([ClaudeUsageRow])
    /// The Keychain refused the read (user hit Deny, or the item ACL changed).
    /// Background polling stops until an explicit refresh so the dialog never
    /// reappears on its own.
    case accessDenied
    case unavailable(String)

    public var rows: [ClaudeUsageRow] {
        switch self {
        case let .available(rows): rows
        case .accessDenied, .unavailable: []
        }
    }

    public var unavailableMessage: String? {
        switch self {
        case .available: nil
        case .accessDenied: "Keychain access denied · Refresh to retry"
        case let .unavailable(message): message
        }
    }

    public var isAccessDenied: Bool {
        self == .accessDenied
    }
}

public struct ClaudeTelemetrySnapshot: Sendable, Equatable {
    public let health: ClaudeHealth
    public let usage: ClaudeUsageState
    public let capturedAt: Date

    public init(
        health: ClaudeHealth,
        usage: ClaudeUsageState,
        capturedAt: Date
    ) {
        self.health = health
        self.usage = usage
        self.capturedAt = capturedAt
    }
}

public struct ClaudeAlert: Sendable, Equatable {
    public let title: String
    public let message: String
}

public struct ClaudeAlertState: Sendable, Equatable {
    public let initialized: Bool
    public let health: ClaudeHealthLevel
    public let utilization: [String: Double]

    public init(
        initialized: Bool = false,
        health: ClaudeHealthLevel = .unavailable,
        utilization: [String: Double] = [:]
    ) {
        self.initialized = initialized
        self.health = health
        self.utilization = utilization
    }
}

public struct ClaudeAlertDecision: Sendable, Equatable {
    public let state: ClaudeAlertState
    public let triggered: [ClaudeAlert]
}

public enum ClaudeAlerts {
    private static let thresholds = [75.0, 90.0, 100.0]

    public static func evaluate(
        snapshot: ClaudeTelemetrySnapshot,
        previous: ClaudeAlertState
    ) -> ClaudeAlertDecision {
        var triggered: [ClaudeAlert] = []
        let rows = snapshot.usage.rows

        if previous.initialized {
            let oldRank = previous.health.alertRank
            let newRank = snapshot.health.level.alertRank
            if newRank > oldRank, newRank > 0 {
                triggered.append(ClaudeAlert(
                    title: "Vitals · Claude status",
                    message: snapshot.health.detail
                ))
            }

            for row in rows {
                guard let oldValue = previous.utilization[row.id] else { continue }
                if let crossed = thresholds.last(where: {
                    oldValue < $0 && row.utilization >= $0
                }) {
                    triggered.append(ClaudeAlert(
                        title: "Vitals · Claude usage",
                        message: "\(row.label) reached \(Int(crossed))%"
                    ))
                }
            }
        }

        return ClaudeAlertDecision(
            state: ClaudeAlertState(
                initialized: true,
                health: snapshot.health.level,
                utilization: Dictionary(
                    rows.map { ($0.id, $0.utilization) },
                    uniquingKeysWith: { first, _ in first }
                )
            ),
            triggered: triggered
        )
    }
}

public actor ClaudeTelemetryClient {
    private static let statusURL = URL(
        string: "https://status.claude.com/api/v2/summary.json"
    )!
    private static let usageURL = URL(
        string: "https://api.anthropic.com/api/oauth/usage"
    )!

    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    public func fetch(
        includeUsage: Bool = true
    ) async -> ClaudeTelemetrySnapshot {
        async let healthResult = fetchHealth()
        async let usageResult = fetchUsage(includeUsage: includeUsage)
        let (health, usage) = await (healthResult, usageResult)
        return ClaudeTelemetrySnapshot(
            health: health,
            usage: usage,
            capturedAt: Date()
        )
    }

    private func fetchHealth() async -> ClaudeHealth {
        do {
            var request = URLRequest(url: Self.statusURL)
            request.setValue("Vitals/0.5.0", forHTTPHeaderField: "User-Agent")
            let data = try await responseData(for: request)
            return try ClaudeStatusParser.parse(data)
        } catch {
            return ClaudeHealth(
                level: .unavailable,
                label: "UNAVAILABLE",
                detail: "Anthropic status is unavailable"
            )
        }
    }

    private func fetchUsage(includeUsage: Bool) async -> ClaudeUsageState {
        guard includeUsage else {
            return .accessDenied
        }

        do {
            let credential = try await ClaudeCredentialStore.load()
            let expiry = Date(
                timeIntervalSince1970: Double(credential.expiresAt) / 1_000
            )
            guard expiry > Date().addingTimeInterval(30) else {
                return .unavailable("Open Claude Code to refresh sign-in")
            }

            var request = URLRequest(url: Self.usageURL)
            request.setValue(
                "Bearer \(credential.accessToken)",
                forHTTPHeaderField: "Authorization"
            )
            request.setValue(
                "oauth-2025-04-20",
                forHTTPHeaderField: "anthropic-beta"
            )
            request.setValue(
                "application/json",
                forHTTPHeaderField: "Content-Type"
            )
            request.setValue("Vitals/0.5.0", forHTTPHeaderField: "User-Agent")

            let data = try await responseData(for: request)
            let rows = try ClaudeUsageParser.parse(data, now: Date())
            guard !rows.isEmpty else {
                return .unavailable("No Claude usage limits")
            }
            return .available(rows)
        } catch ClaudeTelemetryError.accessDenied {
            return .accessDenied
        } catch let error as ClaudeTelemetryError {
            return .unavailable(error.userMessage)
        } catch {
            return .unavailable("Claude usage is unavailable")
        }
    }

    private func responseData(for request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw ClaudeTelemetryError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw ClaudeTelemetryError.httpStatus(response.statusCode)
        }
        return data
    }
}

public enum ClaudeStatusParser {
    public static func parse(_ data: Data) throws -> ClaudeHealth {
        let payload = try JSONDecoder().decode(StatuspagePayload.self, from: data)
        let degraded = payload.components.filter { $0.status != "operational" }
        let detail = degraded.isEmpty
            ? payload.status.description
            : degraded.map(\.name).joined(separator: ", ")

        switch payload.status.indicator {
        case "none":
            return ClaudeHealth(
                level: .operational,
                label: "OPERATIONAL",
                detail: detail
            )
        case "minor":
            return ClaudeHealth(
                level: .degraded,
                label: "DEGRADED",
                detail: detail
            )
        case "major", "critical":
            return ClaudeHealth(
                level: .outage,
                label: "OUTAGE",
                detail: detail
            )
        default:
            return ClaudeHealth(
                level: .unavailable,
                label: "UNKNOWN",
                detail: payload.status.description
            )
        }
    }
}

public enum ClaudeUsageParser {
    public static func parse(_ data: Data, now: Date) throws -> [ClaudeUsageRow] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let payload = try decoder.decode(UsagePayload.self, from: data)
        return payload.limits.compactMap { usageRow($0, now: now) }
            .sorted { $0.order < $1.order }
            .map(\.row)
    }

    private static func usageRow(
        _ limit: UsagePayload.Limit,
        now: Date
    ) -> (order: Int, row: ClaudeUsageRow)? {
        let id: String
        let label: String
        let order: Int

        switch limit.kind {
        case "session":
            id = "session"
            label = "5-hour limit"
            order = 0
        case "weekly_all":
            id = "weekly_all"
            label = "Weekly · all models"
            order = 1
        case "weekly_scoped":
            guard let model = limit.scope?.model?.displayName else { return nil }
            id = "weekly_scoped:\(model)"
            label = "Weekly · \(model)"
            order = 2
        default:
            return nil
        }

        let utilization = max(0, limit.percent)
        let fraction = min(utilization / 100, 1)
        var detail = String(format: "%.0f%%", utilization)
        if let reset = parseDate(limit.resetsAt) {
            detail += " · resets \(relativeReset(reset, now: now))"
        }

        return (
            order,
            ClaudeUsageRow(
                id: id,
                label: label,
                fraction: fraction,
                detail: detail,
                utilization: utilization
            )
        )
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func relativeReset(_ date: Date, now: Date) -> String {
        let seconds = max(0, date.timeIntervalSince(now))
        if seconds < 3_600 {
            return "\(max(1, Int(ceil(seconds / 60))))m"
        }
        if seconds < 172_800 {
            return "\(max(1, Int(ceil(seconds / 3_600))))h"
        }
        return "\(max(1, Int(ceil(seconds / 86_400))))d"
    }
}

/// Reads the Claude Code OAuth credential through `/usr/bin/security`, the
/// same binary Claude Code uses to write it (`add-generic-password -U`).
///
/// Keychain ACLs are bound to the *creating* application, so `security` is
/// always allowed to read the item without a dialog. Reading it from Vitals'
/// own process via `SecItemCopyMatching` does not work reliably: the app is
/// ad-hoc signed, so "Always Allow" binds to one exact binary (every rebuild
/// is a new identity), and Claude Code recreates the item on sign-in/out,
/// which drops the grant again. Going through `security` removes both
/// failure modes and the prompt with them.
public enum ClaudeCredentialStore {
    public static let service = "Claude Code-credentials"

    static func load(
        account: String = NSUserName(),
        securityPath: String = "/usr/bin/security"
    ) async throws -> OAuthCredential {
        let output = try await run(
            securityPath,
            ["find-generic-password", "-s", service, "-a", account, "-w"]
        )
        switch output.status {
        case 0:
            break
        case 44: // errSecItemNotFound
            throw ClaudeTelemetryError.itemNotFound
        case 36, 51, 128: // errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled (OSStatus low byte)
            throw ClaudeTelemetryError.accessDenied
        default:
            throw ClaudeTelemetryError.keychain(output.status)
        }
        return try decode(output.stdout)
    }

    public static func decode(_ data: Data) throws -> OAuthCredential {
        // `-w` prints the secret followed by a newline.
        let trimmed = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let envelope = try JSONDecoder().decode(
            CredentialEnvelope.self,
            from: Data(trimmed.utf8)
        )
        guard let credential = envelope.claudeAiOauth,
              !credential.accessToken.isEmpty else {
            throw ClaudeTelemetryError.invalidCredential
        }
        return credential
    }

    private struct Output {
        let status: Int32
        let stdout: Data
    }

    private static func run(_ path: String, _ arguments: [String]) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { process in
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: Output(
                    status: process.terminationStatus,
                    stdout: data
                ))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: ClaudeTelemetryError.keychain(-1))
            }
        }
    }
}

public struct OAuthCredential: Decodable, Sendable {
    public let accessToken: String
    /// Milliseconds since the Unix epoch, as written by Claude Code.
    public let expiresAt: Int64
}

private struct CredentialEnvelope: Decodable {
    let claudeAiOauth: OAuthCredential?
}

private struct StatuspagePayload: Decodable {
    struct Status: Decodable {
        let indicator: String
        let description: String
    }

    struct Component: Decodable {
        let name: String
        let status: String
    }

    let status: Status
    let components: [Component]
}

private struct UsagePayload: Decodable {
    struct Limit: Decodable {
        struct Scope: Decodable {
            struct Model: Decodable {
                let displayName: String?
            }

            let model: Model?
        }

        let kind: String
        let percent: Double
        let resetsAt: String?
        let scope: Scope?
    }

    let limits: [Limit]
}

public enum ClaudeTelemetryError: Error, Equatable {
    case accessDenied
    case itemNotFound
    case keychain(Int32)
    case invalidCredential
    case invalidResponse
    case httpStatus(Int)

    var userMessage: String {
        switch self {
        case .accessDenied:
            "Keychain access denied · Refresh to retry"
        case .itemNotFound:
            "Sign in with Claude Code"
        case .keychain:
            "Claude Keychain access unavailable"
        case .invalidCredential:
            "Claude Code sign-in is unavailable"
        case .invalidResponse, .httpStatus:
            "Claude usage is unavailable"
        }
    }
}
