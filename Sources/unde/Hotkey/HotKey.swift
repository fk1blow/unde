import AppKit
import Carbon.HIToolbox

/// A single global hotkey registered through the Carbon Event Manager. Carbon is
/// used deliberately: `RegisterEventHotKey` works with zero permissions, whereas
/// an `NSEvent` global monitor would require Accessibility. Deprecated in name
/// only — there is no supported replacement for permission-free global hotkeys.
///
/// One process-wide event handler is installed lazily and dispatches to the
/// registered instances via a keyed table, keeping the C trampoline trivial.
final class HotKey {

    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var eventHandlerInstalled = false

    private let id: UInt32
    private var ref: EventHotKeyRef?
    private let action: () -> Void

    init?(keyCombo: KeyCombo, action: @escaping () -> Void) {
        self.action = action
        self.id = HotKey.nextID
        HotKey.nextID += 1

        HotKey.installEventHandlerIfNeeded()

        // 'unde' as a four-char OSType signature keeps registrations distinct.
        let hotKeyID = EventHotKeyID(signature: OSType(0x756E6465), id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCombo.keyCode,
            keyCombo.modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            NSLog("unde: RegisterEventHotKey failed with status \(status)")
            return nil
        }
        self.ref = ref
        HotKey.handlers[id] = action
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        HotKey.handlers[id] = nil
    }

    private static func installEventHandlerIfNeeded() {
        guard !eventHandlerInstalled else { return }
        eventHandlerInstalled = true

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, _ -> OSStatus in
                var hkID = EventHotKeyID()
                let err = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID
                )
                if err == noErr, let handler = HotKey.handlers[hkID.id] {
                    handler()
                }
                return noErr
            },
            1,
            &spec,
            nil,
            nil
        )
    }
}
