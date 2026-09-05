import Foundation

/// One registered secret: where it lives and how to get at it, never the
/// value. The register is an index for the user and for agents, not a vault.
public struct KeyEntry: Codable, Equatable, Sendable, Identifiable {
    public enum Storage: Equatable, Sendable {
        /// `security find-generic-password -s service [-a account]`.
        case keychain(service: String, account: String?)
        /// A shell variable, exported from the rc files.
        case environment(variable: String)
        /// A file the tool reads itself, `~` allowed.
        case file(path: String)
        /// Anything Vitals cannot check: a 1Password reference, "ask the
        /// user", a vault name.
        case reference(String)
    }

    public let name: String
    public let storage: Storage
    /// Where a new key is created or an old one revoked.
    public let url: String?
    /// What the key is for and how an agent should use it.
    public let note: String?
    /// Last time the presence check passed. Written back by Vitals.
    public var verifiedAt: Date?

    public var id: String { name }

    public init(name: String, storage: Storage, url: String? = nil, note: String? = nil, verifiedAt: Date? = nil) {
        self.name = name
        self.storage = storage
        self.url = url
        self.note = note
        self.verifiedAt = verifiedAt
    }

    // Flat JSON, easy to edit by hand:
    // {"name": "reactbits", "kind": "keychain", "service": "reactbits", "account": "ancplua", "url": "...", "note": "..."}
    private enum CodingKeys: String, CodingKey {
        case name, kind, service, account, variable, path, reference, url, note, verifiedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        verifiedAt = try container.decodeIfPresent(Date.self, forKey: .verifiedAt)
        switch try container.decode(String.self, forKey: .kind) {
        case "keychain":
            storage = .keychain(
                service: try container.decode(String.self, forKey: .service),
                account: try container.decodeIfPresent(String.self, forKey: .account)
            )
        case "environment", "env":
            storage = .environment(variable: try container.decode(String.self, forKey: .variable))
        case "file":
            storage = .file(path: try container.decode(String.self, forKey: .path))
        case "reference":
            storage = .reference(try container.decode(String.self, forKey: .reference))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "unknown kind \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        switch storage {
        case let .keychain(service, account):
            try container.encode("keychain", forKey: .kind)
            try container.encode(service, forKey: .service)
            try container.encodeIfPresent(account, forKey: .account)
        case let .environment(variable):
            try container.encode("environment", forKey: .kind)
            try container.encode(variable, forKey: .variable)
        case let .file(path):
            try container.encode("file", forKey: .kind)
            try container.encode(path, forKey: .path)
        case let .reference(reference):
            try container.encode("reference", forKey: .kind)
            try container.encode(reference, forKey: .reference)
        }
        try container.encodeIfPresent(url, forKey: .url)
        try container.encodeIfPresent(note, forKey: .note)
        try container.encodeIfPresent(verifiedAt, forKey: .verifiedAt)
    }
}

public struct KeyRegister: Codable, Equatable, Sendable {
    public var keys: [KeyEntry]

    public init(keys: [KeyEntry]) {
        self.keys = keys
    }

    public static let empty = KeyRegister(keys: [])

    /// What `vitals keys init` writes: one real entry so the format is
    /// obvious, plus the note field that tells an agent what to do.
    public static let example = KeyRegister(keys: [
        KeyEntry(
            name: "Claude Code OAuth",
            storage: .keychain(service: "Claude Code-credentials", account: nil),
            url: "https://claude.ai/settings",
            note: "Written by Claude Code at login; Vitals reads it for the usage rows. Never copy it anywhere."
        ),
        KeyEntry(
            name: "Example API key",
            storage: .environment(variable: "EXAMPLE_API_KEY"),
            url: "https://example.com/account/api-keys",
            note: "Replace or delete this entry. kind: keychain | environment | file | reference."
        )
    ])
}

public enum KeyPresence: String, Sendable, Codable {
    case present
    case missing
    case unchecked
}

public struct KeyStatus: Equatable, Sendable {
    public let entry: KeyEntry
    public let presence: KeyPresence

    public init(entry: KeyEntry, presence: KeyPresence) {
        self.entry = entry
        self.presence = presence
    }
}

public enum Keys {
    public static func describe(_ storage: KeyEntry.Storage) -> String {
        switch storage {
        case let .keychain(service, account): "keychain \(service)" + (account.map { " · \($0)" } ?? "")
        case let .environment(variable): "env \(variable)"
        case let .file(path): "file \(path)"
        case let .reference(reference): reference
        }
    }

    /// "4 registered · 3 present · 1 missing", or the counts that apply.
    public static func summary(_ statuses: [KeyStatus]) -> String {
        guard !statuses.isEmpty else { return "none registered" }
        var parts = ["\(statuses.count) registered"]
        let present = statuses.filter { $0.presence == .present }.count
        let missing = statuses.filter { $0.presence == .missing }.count
        if present > 0 { parts.append("\(present) present") }
        if missing > 0 { parts.append("\(missing) missing") }
        return parts.joined(separator: " · ")
    }

    public static func line(_ status: KeyStatus, now: Date) -> String {
        var parts = [status.entry.name, describe(status.entry.storage), status.presence.rawValue]
        if let verified = status.entry.verifiedAt {
            let minutes = Int(now.timeIntervalSince(verified) / 60)
            parts.append(minutes < 1 ? "verified just now" : minutes < 60 ? "verified \(minutes)m ago" : minutes < 1_440 ? "verified \(minutes / 60)h ago" : "verified \(minutes / 1_440)d ago")
        }
        return parts.joined(separator: " · ")
    }

    /// The register with `verifiedAt` stamped on every entry whose check
    /// passed; entries that did not pass keep their old stamp.
    public static func stamped(_ register: KeyRegister, statuses: [KeyStatus], now: Date) -> KeyRegister {
        var next = register
        for index in next.keys.indices {
            if statuses.first(where: { $0.entry.name == next.keys[index].name })?.presence == .present {
                next.keys[index].verifiedAt = now
            }
        }
        return next
    }
}
