import CryptoKit
import Foundation

/// Encrypts the files of history items with AES-GCM, so that the history
/// on disk is unreadable without the key, which the app keeps in the
/// Keychain.
///
/// A sealed file is the magic bytes 'KLP1' followed by AES-GCM's combined
/// form (nonce, ciphertext, tag). Each file is bound to its item and file
/// name as associated data, so files cannot be swapped between items or
/// renamed within one without failing to open.
public struct ItemCipher: Sendable {
    public enum CipherError: Error {
        case notSealed
        case sealFailed
    }

    /// Thrown instead of making a new key while a history sealed with
    /// the missing one is still on disk.
    public struct MissingKey: Error, CustomStringConvertible {
        public init() {}
        public var description: String { "The key the saved history was encrypted with is missing" }
    }

    /// The key to open the history with: the stored one, or a new one
    /// from `create` when there is none. A new key is only made while
    /// none of `roots` holds sealed items. With some there, a new key
    /// could not read them and they would look like damaged items, so
    /// `MissingKey` is thrown and the history must be left alone.
    public static func key(
        stored: SymmetricKey?, sealedHistoryIn roots: [URL], create: () throws -> SymmetricKey
    ) throws -> SymmetricKey {
        if let stored { return stored }
        guard !roots.contains(where: ItemStorage.holdsSealedItems) else { throw MissingKey() }
        return try create()
    }

    private static let magic = Data("KLP1".utf8)
    private let key: SymmetricKey

    public init(key: SymmetricKey) {
        self.key = key
    }

    /// A cipher with a fresh key that exists only in memory: what it seals
    /// cannot be opened after the app quits.
    public static func ephemeral() -> ItemCipher {
        ItemCipher(key: SymmetricKey(size: .bits256))
    }

    /// True when `data` starts like a sealed file. Files written before
    /// encryption start with JSON or raw pasteboard bytes instead.
    public static func isSealed(_ data: Data) -> Bool {
        data.starts(with: magic)
    }

    public func seal(_ data: Data, context: String) throws -> Data {
        let box = try AES.GCM.seal(data, using: key, authenticating: Data(context.utf8))
        guard let combined = box.combined else { throw CipherError.sealFailed }
        return Self.magic + combined
    }

    public func open(_ data: Data, context: String) throws -> Data {
        guard Self.isSealed(data) else { throw CipherError.notSealed }
        let box = try AES.GCM.SealedBox(combined: data.dropFirst(Self.magic.count))
        return try AES.GCM.open(box, using: key, authenticating: Data(context.utf8))
    }
}
