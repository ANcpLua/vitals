import CoreGraphics
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import VitalsCore

/// Lid, power source and display facts from IOKit and CoreGraphics. No
/// process spawns; every call is a registry or framework read.
public enum PowerSampler {
    public static func context() -> PowerContext {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        defer { if root != 0 { IOObjectRelease(root) } }
        return PowerContext(
            lidClosed: bool(root, "AppleClamshellState"),
            lidClosesSleep: bool(root, "AppleClamshellCausesSleep"),
            source: source(),
            externalDisplays: externalDisplays()
        )
    }

    static func bool(_ service: io_service_t, _ key: String) -> Bool {
        guard service != 0,
              let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                  .takeRetainedValue()
        else { return false }
        return (value as? Bool) ?? ((value as? NSNumber)?.boolValue ?? false)
    }

    static func source() -> PowerContext.Source {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        else { return .unknown }
        switch type {
        case kIOPMACPowerKey: return .ac
        case kIOPMBatteryPowerKey, kIOPMUPSPowerKey: return .battery
        default: return .unknown
        }
    }

    static func externalDisplays() -> Int {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return 0 }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return 0 }
        return displays.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }.count
    }
}

/// Owns the two IOKit power assertions and the kernel's clamshell-sleep
/// override. Idempotent: `apply` creates what the decision wants and
/// releases what it no longer wants. The assertions die with the process.
/// The override is kernel state shared by every process (Clamshell.app
/// flips the same bit), so it is re-sent on every apply while wanted and
/// cleared only when this instance stops wanting it. Persisting the policy
/// and re-applying it at launch covers a restart.
@MainActor
public final class AwakeAssertions {
    private var system: IOPMAssertionID = 0
    private var display: IOPMAssertionID = 0
    /// User client on `IOPMrootDomain`, opened on first use and kept for the
    /// life of the process.
    private var rootDomain: io_connect_t = 0
    public private(set) var overridesLidSleep = false
    public private(set) var lastError: String?

    public init() {}

    public var holdsSystem: Bool { system != 0 }
    public var holdsDisplay: Bool { display != 0 }

    public func apply(_ decision: AwakeDecision) {
        lastError = nil
        toggle(&system, kIOPMAssertionTypePreventUserIdleSystemSleep as String, wanted: decision.holdSystem)
        toggle(&display, kIOPMAssertionTypePreventUserIdleDisplaySleep as String, wanted: decision.holdDisplay)
        overrideLidSleep(decision.overrideLidSleep)
    }

    public func releaseAll() {
        apply(AwakeDecision(holdSystem: false, holdDisplay: false, overrideLidSleep: false, reason: "off", warning: false))
    }

    /// `kPMSetClamshellSleepState` on `IOPMrootDomain`, the call Clamshell.app
    /// makes from its sandbox: no root, no daemon. 1 sets the powerd bit in
    /// the kernel's clamshell-sleep-disable mask, 0 clears it, and the kernel
    /// sleeps at once if the lid is closed on battery when the mask empties.
    /// `AppleClamshellCausesSleep` in the registry reflects the result.
    private func overrideLidSleep(_ wanted: Bool) {
        guard wanted || overridesLidSleep, connectRootDomain() else { return }
        var state: UInt64 = wanted ? 1 : 0
        let result = IOConnectCallScalarMethod(rootDomain, UInt32(kPMSetClamshellSleepState), &state, 1, nil, nil)
        if result == kIOReturnSuccess {
            overridesLidSleep = wanted
        } else {
            lastError = "kPMSetClamshellSleepState(\(state)) failed: IOReturn \(result)"
        }
    }

    private func connectRootDomain() -> Bool {
        if rootDomain != 0 { return true }
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else {
            lastError = "IOPMrootDomain not found"
            return false
        }
        defer { IOObjectRelease(root) }
        let result = IOServiceOpen(root, mach_task_self_, 0, &rootDomain)
        guard result == kIOReturnSuccess else {
            rootDomain = 0
            lastError = "IOPMrootDomain open failed: IOReturn \(result)"
            return false
        }
        return true
    }

    private func toggle(_ id: inout IOPMAssertionID, _ type: String, wanted: Bool) {
        if wanted, id == 0 {
            var created: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                type as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Vitals stay awake" as CFString,
                &created
            )
            if result == kIOReturnSuccess {
                id = created
            } else {
                lastError = "\(type) failed: IOReturn \(result)"
            }
        } else if !wanted, id != 0 {
            IOPMAssertionRelease(id)
            id = 0
        }
    }
}
