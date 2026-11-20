import Foundation

/// A small file beside the history, sealed with the history's key:
///
///     ~/Library/Application Support/Klippari/key-check
///
/// It is written once the history is known to open with the key and
/// nothing written before encryption is left. From then on it tells at
/// launch whether the key in the keychain is the history's key, even
/// while the history is empty, and that plain items are no longer
/// expected: one that turns up later is not taken into the history.
public enum KeyCheck {
    public enum Verdict: Equatable, Sendable {
        /// The file opens with the key.
        case matches
        /// The file, or the history if there is no file yet, was sealed
        /// with another key.
        case wrongKey
        /// No file yet, and nothing on disk says the key is wrong.
        case notWritten
    }

    private static let name = "key-check"
    private static let context = "key-check"
    private static let contents = Data("Klippari history key".utf8)

    public static func url(in folder: URL) -> URL {
        folder.appendingPathComponent(name)
    }

    public static func exists(in folder: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url(in: folder).path)) != nil
    }

    /// Whether `cipher`'s key is the history's key. Without a file, a
    /// history with sealed items of which none opens with the key has
    /// the wrong key; one with no sealed items, or some that open, has
    /// not.
    public static func verdict(for cipher: ItemCipher, in folder: URL, sealedHistoryIn roots: [URL]) -> Verdict {
        do {
            let sealed = try Data(contentsOf: url(in: folder))
            return (try? cipher.open(sealed, context: context)) == contents ? .matches : .wrongKey
        } catch {
            // A file that is there but cannot be read cannot vouch for
            // the key either.
            guard ItemStorage.isMissing(error) else { return .wrongKey }
        }
        let sealed = roots.flatMap { ItemStorage.sealedItemFolders(in: $0) }
        guard !sealed.isEmpty else { return .notWritten }
        return sealed.contains { ItemStorage.manifestOpens($0, with: cipher) } ? .notWritten : .wrongKey
    }

    /// Writes the file for `cipher`'s key, replacing any earlier one in
    /// one step.
    public static func write(_ cipher: ItemCipher, in folder: URL) throws {
        let sealed = try cipher.seal(contents, context: context)
        let staged = folder.appendingPathComponent(".tmp-" + name)
        let fm = FileManager.default
        try? fm.removeItem(at: staged)
        guard fm.createFile(atPath: staged.path, contents: sealed, attributes: [.posixPermissions: 0o600]) else {
            throw ItemStorage.StorageError.writeFailed(name)
        }
        guard rename(staged.path, url(in: folder).path) == 0 else {
            try? fm.removeItem(at: staged)
            throw ItemStorage.StorageError.writeFailed(name)
        }
    }

    public static func remove(in folder: URL) {
        try? FileManager.default.removeItem(at: url(in: folder))
    }
}
