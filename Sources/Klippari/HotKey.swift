import Carbon.HIToolbox
import os

/// A system-wide hotkey via Carbon's RegisterEventHotKey. This needs no
/// permission and consumes the keystroke, so the frontmost app never
/// sees it.
@MainActor final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let handler: () -> Void
    private static let logger = Logger(subsystem: "com.arime.Klippari", category: "hotkey")

    /// False when the shortcut could not be registered (for example,
    /// another app already owns it).
    private(set) var isRegistered = false

    init(shortcut: Shortcut, handler: @escaping () -> Void) {
        self.handler = handler

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
                // Carbon delivers hotkey events on the main thread.
                MainActor.assumeIsolated { hotKey.handler() }
                return noErr
            },
            1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handlerRef
        )
        register(shortcut)
    }

    func update(_ shortcut: Shortcut) {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        register(shortcut)
    }

    private func register(_ shortcut: Shortcut) {
        let id = EventHotKeyID(signature: OSType(0x434C_4950), id: 1) // 'CLIP'
        let status = RegisterEventHotKey(
            shortcut.keyCode, shortcut.carbonModifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef
        )
        isRegistered = status == noErr
        if !isRegistered {
            Self.logger.error("Could not register hotkey, status \(status)")
        }
    }
}
