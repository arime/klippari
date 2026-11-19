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
