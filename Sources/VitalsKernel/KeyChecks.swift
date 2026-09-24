import Foundation
import VitalsCore

/// `~/.config/vitals/keys.json`. Absent is a state of its own (the menu
/// offers to create it); corrupt is an error the menu shows.
public enum KeyRegisterStore {
    public static func url(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".config/vitals/keys.json")
    }

    public static func load(from url: URL = url()) -> Result<KeyRegister?, MetricsError> {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoSuchFileError { return .success(nil) }
            return .failure(.syscall(name: "read keys.json", code: Int32(error.code)))
        }
        return decode(data)
    }

    private static func decode(_ data: Data) -> Result<KeyRegister?, MetricsError> {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return .success(try decoder.decode(KeyRegister.self, from: data))
        } catch {
            return .failure(.unexpected(name: "keys.json", value: 0))
        }
    }

    public static func save(_ register: KeyRegister, to url: URL = url()) throws {
        try write(register, to: url)
        try backup(from: url)
    }

    public static func backupURL(for url: URL = url()) -> URL {
        url.deletingPathExtension().appendingPathExtension("last-good.json")
    }

    /// Keep the complete validated registry, including fields a newer version may use.
    public static func backup(from url: URL = url()) throws {
        let data = try Data(contentsOf: url)
        _ = try decode(data).get()
        let backup = backupURL(for: url)
        if (try? Data(contentsOf: backup)) == data { return }
        try data.write(to: backup, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
    }

    /// Creation must never replace an existing or unreadable registry, even during startup.
    @discardableResult
    public static func createExampleIfMissing(at url: URL = url()) throws -> Bool {
        if try load(from: url).get() != nil { return false }
        if FileManager.default.fileExists(atPath: backupURL(for: url).path) {
            throw MetricsError.unexpected(name: "recovery copy exists; use vitals keys restore", value: 0)
        }
        try write(.example, to: url, overwrite: false)
        try backup(from: url)
        return true
    }

    /// Explicit recovery only. Preserve the damaged file and never replace a valid registry.
    public static func restore(from url: URL = url()) throws {
        if case .success(.some) = load(from: url) {
            throw MetricsError.unexpected(name: "registry is valid; refusing to replace it", value: 0)
        }
        let data = try Data(contentsOf: backupURL(for: url))
        _ = try decode(data).get()
        if FileManager.default.fileExists(atPath: url.path) {
            let damaged = url.deletingPathExtension().appendingPathExtension("damaged-\(UUID().uuidString).json")
            try FileManager.default.copyItem(at: url, to: damaged)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: damaged.path)
        }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func write(_ register: KeyRegister, to url: URL, overwrite: Bool = true) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(register).write(to: url, options: overwrite ? .atomic : .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Presence only, never a value. Keychain: `security find-generic-password`
/// without `-w` returns metadata and never prompts; exit 44 is "not found".
/// Environment: the variable in this process or an `export NAME=` line in
/// the zsh rc files, since a LaunchAgent does not inherit the shell.
/// File: exists and is not empty. Reference: unchecked by design.
public enum KeyChecks {
    public static func presence(
        of storage: KeyEntry.Storage,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> KeyPresence {
        switch storage {
        case let .keychain(service, account):
            var arguments = ["find-generic-password", "-s", service]
            if let account { arguments += ["-a", account] }
            switch run("/usr/bin/security", arguments) {
            case 0: return .present
            case 44: return .missing
            default: return .unchecked
            }
        case let .environment(variable):
            if environment[variable].map({ !$0.isEmpty }) == true { return .present }
            for name in [".zshenv", ".zshrc", ".zprofile"] {
                let url = home.appendingPathComponent(name)
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                if text.contains("\(variable)=") { return .present }
            }
            return .missing
        case let .file(path):
            let expanded = path.hasPrefix("~") ? home.path + path.dropFirst() : path
            let size = (try? FileManager.default.attributesOfItem(atPath: expanded)[.size] as? Int) ?? 0
            return size > 0 ? .present : .missing
        case .reference:
            return .unchecked
        }
    }

    public static func check(_ register: KeyRegister, home: URL = FileManager.default.homeDirectoryForCurrentUser, localAuthentication: Bool = false) -> [KeyStatus] {
        let remote = authentication(home: home, local: localAuthentication)
        return register.keys.map { entry in
            let check = remote[entry.name]
            let localPresence = presence(of: entry.storage, home: home)
            return KeyStatus(entry: entry, presence: check?.presence.flatMap(KeyPresence.init(rawValue:)) ?? localPresence,
                             authentication: check?.checks ?? (entry.remoteChecks?.isEmpty == false || entry.localCheck != nil
                                ? [KeyAuthentication(label: "credential check", state: "unavailable", detail: "Check helper unavailable", checkedAt: "")] : []))
        }
    }

    private struct AuthenticationResult: Decodable {
        let checks: [KeyAuthentication]
        let presence: String?
    }

    private static func authentication(home: URL, local: Bool) -> [String: AuthenticationResult] {
        let script = Bundle.module.url(forResource: "credential_health", withExtension: "py")!
        let python = home.appendingPathComponent(".local/bin/pytools").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: FileManager.default.isExecutableFile(atPath: python) ? python : "/usr/bin/python3")
        process.arguments = [script.path, "--registry", KeyRegisterStore.url(home: home).path] + (local ? ["--local"] : [])
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        do { try process.run() } catch { return [:] }
        // Drain while running so a full pipe cannot deadlock the child.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [:] }
        return (try? JSONDecoder().decode([String: AuthenticationResult].self, from: data)) ?? [:]
    }

    private static func run(_ path: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
