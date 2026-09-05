import Foundation
import ServiceManagement

/// Login-item state for the menu toggle. Two mechanisms can start Vitals at
/// login and they must never both be active: the `dev.ancplua.vitals`
/// LaunchAgent that `install.sh` writes (KeepAlive, survives
/// crashes) and the user-facing `SMAppService` login item. When the agent
/// plist is present the toggle is shown but locked, so the installer's
/// choice wins and the user sees why.
enum LaunchAtLogin {
    enum State: Equatable {
        /// `~/Library/LaunchAgents/dev.ancplua.vitals.plist` exists.
        case managedByLaunchd
        case enabled
        case disabled
        /// Login items need System Settings approval before they run.
        case requiresApproval
        /// Not running from an app bundle (`swift run`), nothing to register.
        case unavailable
    }

    static let agentLabel = "dev.ancplua.vitals"

    static var agentPlist: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    static func state(agentInstalled: Bool = FileManager.default.fileExists(atPath: agentPlist.path)) -> State {
        if agentInstalled { return .managedByLaunchd }
        guard Bundle.main.bundleURL.pathExtension == "app" else { return .unavailable }
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered, .notFound: return .disabled
        @unknown default: return .disabled
        }
    }

    /// Flips the login item. Refuses while the LaunchAgent is installed so the
    /// app is never registered twice.
    static func toggle() -> Result<State, Error> {
        let current = state()
        switch current {
        case .managedByLaunchd, .unavailable:
            return .success(current)
        case .enabled, .requiresApproval:
            return Result { try SMAppService.mainApp.unregister() }.map { state() }
        case .disabled:
            return Result { try SMAppService.mainApp.register() }.map { state() }
        }
    }

    static func title(_ state: State) -> String {
        switch state {
        case .managedByLaunchd: "Launch at Login · managed by launchd"
        case .enabled: "Launch at Login"
        case .disabled: "Launch at Login"
        case .requiresApproval: "Launch at Login · approve in System Settings"
        case .unavailable: "Launch at Login · needs Vitals.app"
        }
    }
}
