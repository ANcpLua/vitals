import Foundation
import VitalsClaude
import VitalsCore

enum Notifier {
    static func deliver(_ kind: AlarmKind, snapshot: Snapshot) {
        let message: String
        switch kind {
        case .diskLow:
            message = "disk available \(Format.gb(snapshot.disk.available)) — disk-guard kicked"
            kickstartDiskGuard()
        case .memoryRed:
            message = "memory pressure RED — available \(Format.gib(snapshot.memory.available))"
        }
        deliver(message: message, title: "Vitals")
    }

    static func deliver(_ alert: ClaudeAlert) {
        deliver(message: alert.message, title: alert.title)
    }

    /// The disk alarm latches once per red episode; hand that edge to the
    /// disk-guard LaunchAgent so cleanup starts now instead of at its next
    /// 5-minute poll. Missing agent → launchctl exits non-zero, nothing else.
    private static func kickstartDiskGuard() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["kickstart", "gui/\(getuid())/dev.ancplua.disk-guard"]
        try? process.run()
    }

    private static func deliver(message: String, title: String) {
        let script = "display notification \"\(escape(message))\" with title \"\(escape(title))\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        do {
            try process.run()
        } catch {
            FileHandle.standardError.write(Data("vitals: notification failed: \(error)\n".utf8))
            return
        }
        process.waitUntilExit()
    }

    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
