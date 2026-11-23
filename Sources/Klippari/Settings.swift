import AppKit
import Carbon.HIToolbox
import ClipboardCore

/// A global keyboard shortcut in the form Carbon's hotkey API wants.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    /// The key's printed label, captured when the shortcut was recorded.
    var keyLabel: String

    static let `default` = Shortcut(
        keyCode: UInt32(kVK_ANSI_V), carbonModifiers: UInt32(cmdKey | shiftKey), keyLabel: "V"
    )

    var displayString: String {
        var symbols = ""
        if carbonModifiers & UInt32(controlKey) != 0 { symbols += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { symbols += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { symbols += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { symbols += "⌘" }
        return symbols + keyLabel
    }

    /// Builds a shortcut from a key press; nil unless it includes Cmd,
    /// Ctrl or Option (a bare key would swallow ordinary typing).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        guard modifiers != 0 else { return nil }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        guard let label = event.charactersIgnoringModifiers?.uppercased(), !label.isEmpty else { return nil }
        self.init(keyCode: UInt32(event.keyCode), carbonModifiers: modifiers, keyLabel: label)
    }

    init(keyCode: UInt32, carbonModifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.keyLabel = keyLabel
    }
}

/// User settings, kept in UserDefaults.
@MainActor @Observable final class Settings {
    static let limitRange = 5...500

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var onChange: (() -> Void)?

    var historyLimit: Int {
        didSet {
            defaults.set(historyLimit, forKey: "historyLimit")
            onChange?()
        }
    }

    var shortcut: Shortcut {
        didSet {
            if let data = try? JSONEncoder().encode(shortcut) {
                defaults.set(data, forKey: "shortcut")
            }
            onChange?()
        }
    }

    /// Deliberately not persisted: a restart always resumes capture, so
    /// the app cannot stay silently paused.
    var isPaused = false {
        didSet { onChange?() }
    }

    /// Where the user dragged the panel to; nil until they move it, and
    /// again after 'Reset Panel Position'.
    var panelPlacement: PanelPlacement? {
        didSet {
            if let panelPlacement, let data = try? JSONEncoder().encode(panelPlacement) {
                defaults.set(data, forKey: "panelPlacement")
            } else {
                defaults.removeObject(forKey: "panelPlacement")
            }
        }
    }

    /// Set by the app when the chosen shortcut could not be registered.
    var shortcutUnavailable = false

    /// Point at a row to select it, click to paste it. Off by default:
    /// the panel is made for the keyboard.
    var mouseOnRows: Bool {
        didSet { defaults.set(mouseOnRows, forKey: "mouseOnRows") }
    }

    /// Open the panel next to the text field being typed in, or the
    /// mouse pointer, instead of its usual place. Off by default.
    var openAtPointer: Bool {
        didSet { defaults.set(openAtPointer, forKey: "openAtPointer") }
    }

    /// Show the selected image, or one whose thumbnail the pointer is
    /// over, large beside the panel, to tell similar screenshots apart.
    /// Off by default.
    var magnifyImages: Bool {
        didSet { defaults.set(magnifyImages, forKey: "magnifyImages") }
    }

    /// Mask passwords and API keys, kept in memory only for 10 minutes.
    /// Off by default: every copy is then saved as it is. Applies to
    /// new copies only.
    var detectSecrets: Bool {
        didSet {
            defaults.set(detectSecrets, forKey: "detectSecrets")
            onChange?()
        }
    }

    /// Nested under Secrets: Cmd+S in the panel masks a text always, or
    /// unmasks a secret, and copies holding a masked text are secrets.
    /// Off by default.
    var maskChosenTexts: Bool {
        didSet {
            defaults.set(maskChosenTexts, forKey: "maskChosenTexts")
            onChange?()
        }
    }

    /// The cleared history, for Settings to offer restoring. Kept up
    /// to date by the app; not stored in the preferences.
    var archive: ArchiveSummary?
    /// What the last restore could not do, such as items left behind
    /// because the history was full. Nil once it no longer applies.
    var restoreNote: String?
    /// Restores the cleared history.
    @ObservationIgnored var onRestoreArchive: (() -> Void)?
    /// Deletes the cleared history for good.
    @ObservationIgnored var onDeleteArchive: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedLimit = defaults.integer(forKey: "historyLimit")
        historyLimit = Self.limitRange.contains(storedLimit) ? storedLimit : 50
        shortcut = defaults.data(forKey: "shortcut")
            .flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? .default
        panelPlacement = defaults.data(forKey: "panelPlacement")
            .flatMap { try? JSONDecoder().decode(PanelPlacement.self, from: $0) }
        mouseOnRows = defaults.bool(forKey: "mouseOnRows")
        openAtPointer = defaults.bool(forKey: "openAtPointer")
        magnifyImages = defaults.bool(forKey: "magnifyImages")
        detectSecrets = defaults.bool(forKey: "detectSecrets")
        maskChosenTexts = defaults.bool(forKey: "maskChosenTexts")
    }
}
