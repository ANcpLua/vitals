import Foundation
import VitalsCore

/// `~/.config/vitals/keys.json`. Absent is a state of its own (the menu
/// offers to create it); corrupt is an error the menu shows.
public enum KeyRegisterStore {
    public static func url(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".config/vitals/keys.json")
    }

    public static func load(from url: URL = url()) -> Result<KeyRegister?, MetricsError> {
        guard let data = try? Data(contentsOf: url) else { return .success(nil) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return .success(try decoder.decode(KeyRegister.self, from: data))
        } catch {
            return .failure(.unexpected(name: "keys.json", value: 0))
        }
    }

    public static func save(_ register: KeyRegister, to url: URL = url()) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(register).write(to: url, options: .atomic)
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

    public static func check(_ register: KeyRegister, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [KeyStatus] {
        register.keys.map { KeyStatus(entry: $0, presence: presence(of: $0.storage, home: home)) }
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
