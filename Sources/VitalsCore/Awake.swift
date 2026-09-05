/// Lid, power and display facts the awake policy decides on. Read by the
/// kernel every tick; pure here.
public struct PowerContext: Sendable, Equatable, Codable {
    public enum Source: String, Sendable, Codable {
        case ac
        case battery
        case unknown
    }

    /// `AppleClamshellState`: the lid is physically closed.
    public let lidClosed: Bool
    /// `AppleClamshellCausesSleep`: closing the lid sleeps the Mac right now.
    /// macOS clears it on AC with an external display; any process can clear
    /// it through `kPMSetClamshellSleepState` on `IOPMrootDomain`, which is
    /// what `AwakeAssertions` does when the decision asks for it.
    public let lidClosesSleep: Bool
    public let source: Source
    public let externalDisplays: Int

    public init(lidClosed: Bool, lidClosesSleep: Bool, source: Source, externalDisplays: Int) {
        self.lidClosed = lidClosed
        self.lidClosesSleep = lidClosesSleep
        self.source = source
        self.externalDisplays = externalDisplays
    }
}

/// What the user asked for. Persisted, re-applied on every tick, so a
/// restart of Vitals re-establishes the same assertions instead of
/// dropping the external display.
public enum AwakeMode: String, Sendable, CaseIterable, Codable {
    case off
    /// Hold system and display awake unconditionally.
    case always
    /// Hold only while the lid is closed: the clamshell case.
    case lidClosed
    /// Hold only while an external display is attached.
    case externalDisplay

    public var title: String {
        switch self {
        case .off: "Off"
        case .always: "Always"
        case .lidClosed: "While the lid is closed"
        case .externalDisplay: "While an external display is attached"
        }
    }
}

public struct AwakeDecision: Sendable, Equatable {
    /// Hold `PreventUserIdleSystemSleep`.
    public let holdSystem: Bool
    /// Hold `PreventUserIdleDisplaySleep`.
    public let holdDisplay: Bool
    /// Keep the kernel's clamshell-sleep flag cleared so closing the lid does
    /// not sleep the Mac, on battery included. Armed ahead of the lid close:
    /// the kernel decides at the moment the lid shuts.
    public let overrideLidSleep: Bool
    /// One line for the menu: what is held and why, or why it cannot work.
    public let reason: String
    /// True when the mode wants to hold but the OS will sleep anyway.
    public let warning: Bool

    public init(holdSystem: Bool, holdDisplay: Bool, overrideLidSleep: Bool, reason: String, warning: Bool) {
        self.holdSystem = holdSystem
        self.holdDisplay = holdDisplay
        self.overrideLidSleep = overrideLidSleep
        self.reason = reason
        self.warning = warning
    }

    public var holdsAnything: Bool { holdSystem || holdDisplay || overrideLidSleep }
}

public enum Awake {
    public static func decide(mode: AwakeMode, context: PowerContext) -> AwakeDecision {
        // `hold` keeps the idle assertions; `override` keeps a closed lid from
        // sleeping the Mac. The override is armed before the lid closes, since
        // the kernel decides at the moment it shuts, and the lid and display
        // modes arm it only with an external display attached, so a closed
        // lid in a bag still sleeps. Always means always.
        let hold: Bool
        let override: Bool
        switch mode {
        case .off:
            hold = false
            override = false
        case .always:
            hold = true
            override = true
        case .lidClosed:
            hold = context.lidClosed
            override = context.externalDisplays > 0
        case .externalDisplay:
            hold = context.externalDisplays > 0
            override = hold
        }
        let state = switch (hold, override) {
        case (false, false): mode == .off ? "off" : "idle · \(describe(context))"
        case (false, true): "armed · \(describe(context))"
        case (true, true): "holding · \(describe(context))"
        case (true, false): "holding · \(describe(context)) · lid close sleeps without a display"
        }
        return AwakeDecision(
            holdSystem: hold,
            holdDisplay: hold,
            overrideLidSleep: override,
            reason: state,
            warning: hold && !override
        )
    }

    public static func describe(_ context: PowerContext) -> String {
        var parts = [context.lidClosed ? "lid closed" : "lid open"]
        switch context.source {
        case .ac: parts.append("AC")
        case .battery: parts.append("battery")
        case .unknown: break
        }
        parts.append(context.externalDisplays == 1 ? "1 external display" : "\(context.externalDisplays) external displays")
        return parts.joined(separator: " · ")
    }
}
