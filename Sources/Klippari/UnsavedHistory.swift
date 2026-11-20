/// Why the history is kept for this run only instead of being saved.
/// The menu bar menu and the panel both say so, with the reason, so it
/// is never only in the log.
enum UnsavedHistory: Error {
    /// Encrypted history is on disk, but its key is not in the keychain.
    case missingKey
    /// The keychain holds a key, but not the one the history was
    /// encrypted with.
    case wrongKey
    /// The keychain refused, or holds something that is not the key.
    case keychain(String)
    /// The history folder could not be made or set up.
    case folder(String)

    /// The second, indented line under "History isn't being saved" in
    /// the menu.
    var menuReason: String {
        switch self {
        case .missingKey: "Its encryption key is missing from the keychain"
        case .wrongKey: "The key in the keychain doesn't open it"
        case .keychain: "The keychain did not give its encryption key"
        case .folder: "Its folder could not be set up"
        }
    }

    /// One line for the panel's footer.
    var panelWarning: String {
        switch self {
        case .missingKey: "History isn't being saved: its key is missing from the keychain."
        case .wrongKey: "History isn't being saved: the key in the keychain doesn't open it."
        case .keychain: "History isn't being saved: the keychain did not give its key."
        case .folder: "History isn't being saved: its folder could not be set up."
        }
    }

    /// The underlying error, for the menu line's tooltip.
    var detail: String? {
        switch self {
        case .missingKey: nil
        case .wrongKey:
            "The saved history was encrypted with another key. If you did not expect this, another app "
                + "may have replaced the key: delete 'Klippari history key' in Keychain Access and relaunch."
        case .keychain(let detail), .folder(let detail): detail
        }
    }
}
