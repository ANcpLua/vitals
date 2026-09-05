import AppKit
import Carbon

/// Global hotkey through Carbon's RegisterEventHotKey. Unlike an NSEvent
/// global monitor it needs neither Accessibility nor Input Monitoring, and
/// it still works on macOS 26.
@MainActor
final class HotKey {
    struct Modifiers: OptionSet {
        let rawValue: UInt32
        static let control = Modifiers(rawValue: UInt32(controlKey))
        static let shift = Modifiers(rawValue: UInt32(shiftKey))
        static let option = Modifiers(rawValue: UInt32(optionKey))
        static let command = Modifiers(rawValue: UInt32(cmdKey))
    }

    static let keyV = UInt32(kVK_ANSI_V)

    private static var handlers: [UInt32: @MainActor () -> Void] = [:]
    private static var installed = false
    private var reference: EventHotKeyRef?

    init?(keyCode: UInt32, modifiers: Modifiers, id: UInt32, handler: @escaping @MainActor () -> Void) {
        Self.installHandlerIfNeeded()
        let hotKeyID = EventHotKeyID(signature: 0x5654_4C53, id: id) // 'VTLS'
        var reference: EventHotKeyRef?
        guard RegisterEventHotKey(keyCode, modifiers.rawValue, hotKeyID, GetApplicationEventTarget(), 0, &reference) == noErr,
              let reference
        else { return nil }
        self.reference = reference
        Self.handlers[id] = handler
    }

    private static func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            // Carbon delivers application events on the main thread.
            MainActor.assumeIsolated { HotKey.handlers[hotKeyID.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
