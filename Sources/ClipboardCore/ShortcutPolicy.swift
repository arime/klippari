import Foundation

/// Which key combinations may not become the global shortcut. A global
/// hotkey swallows its keystroke in every app, so taking over a standard
/// editing or window key would break that key system-wide; Cmd+V would
/// also intercept the paste this app synthesizes itself.
public enum ShortcutPolicy {
    // Virtual key codes for A, Z, X, C, V, Q, W.
    private static let standardCommandKeys: Set<UInt32> = [0, 6, 7, 8, 9, 12, 13]
    private static let keyZ: UInt32 = 6

    public static func isReserved(
        keyCode: UInt32, command: Bool, control: Bool, option: Bool, shift: Bool
    ) -> Bool {
        guard command, !control, !option else { return false }
        if !shift { return standardCommandKeys.contains(keyCode) }
        return keyCode == keyZ // Shift+Cmd+Z is Redo
    }
}
