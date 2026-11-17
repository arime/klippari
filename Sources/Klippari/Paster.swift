import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Pastes into the frontmost app by synthesizing Cmd+V, which macOS only
/// allows for apps granted the Accessibility permission.
@MainActor enum Paster {
    private static let promptedKey = "didRequestAccessibility"

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system's Accessibility prompt, once per install; after
    /// that the panel's notice is the reminder.
    static func requestTrustOnce() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: promptedKey) else { return }
        defaults.set(true, forKey: promptedKey)
        // The value of kAXTrustedCheckOptionPrompt, spelled out because the
        // imported global is not concurrency-safe in Swift 6.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func sendPaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = CGKeyCode(kVK_ANSI_V)
        // Flags are set explicitly so a Shift still held from Shift+Return
        // does not turn this into Shift+Cmd+V.
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: keyDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }
}
