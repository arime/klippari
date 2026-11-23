import Foundation

/// Texts the user asked to have masked always (Cmd+S on an ordinary row
/// while Secrets is on), sealed with the history's key in a file beside
/// the history:
///
///     ~/Library/Application Support/Klippari/items-masked-texts
///
/// The list holds what the user wants hidden, so it is never written in
/// clear, and nothing in the app lists it.
public enum MaskedTexts {
    private static let context = "masked-texts"

    public static func url(forItems root: URL) -> URL {
        var base = root.lastPathComponent
        if base.hasSuffix(".noindex") { base.removeLast(".noindex".count) }
        return root.deletingLastPathComponent().appendingPathComponent(base + "-masked-texts")
    }

    /// Deletes the saved list, as when the key it was sealed with is gone.
    public static func remove(forItems root: URL) {
        try? FileManager.default.removeItem(at: url(forItems: root))
    }

    /// The shortest text that can be masked always. A shorter one, such
    /// as a single letter, would make nearly every copy a secret.
    public static let shortestText = 4

    /// The saved list; empty when there is none or it cannot be opened.
    public static func load(from url: URL, cipher: ItemCipher) -> [String] {
        guard let sealed = try? Data(contentsOf: url),
              let data = try? cipher.open(sealed, context: context),
              let texts = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return texts
    }

    /// Replaces the saved list in one step; an empty list removes the file.
    public static func save(_ texts: [String], to url: URL, cipher: ItemCipher) throws {
        let fm = FileManager.default
        guard !texts.isEmpty else {
            try? fm.removeItem(at: url)
            return
        }
        let sealed = try cipher.seal(JSONEncoder().encode(texts), context: context)
        let staged = url.deletingLastPathComponent().appendingPathComponent(".tmp-" + url.lastPathComponent)
        try? fm.removeItem(at: staged)
        guard fm.createFile(atPath: staged.path, contents: sealed, attributes: [.posixPermissions: 0o600]) else {
            throw ItemStorage.StorageError.writeFailed(url.lastPathComponent)
        }
        guard rename(staged.path, url.path) == 0 else {
            try? fm.removeItem(at: staged)
            throw ItemStorage.StorageError.writeFailed(url.lastPathComponent)
        }
    }
}
