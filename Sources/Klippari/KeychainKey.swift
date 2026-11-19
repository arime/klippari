import CryptoKit
import Foundation
import Security

/// The key that encrypts the history on disk, kept in the login keychain
/// as a generic password. The keychain lets Klippari read it silently;
/// any other app that asks for it makes macOS ask the user first.
enum KeychainKey {
    struct Failure: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
            return "Keychain error \(status): \(message)"
        }
    }

    private static let service = "com.arime.Klippari"
    private static let account = "history-encryption-key"

    /// The stored key; nil when there is none. Throws when the keychain
    /// refuses or holds something unusable: the caller must then not
    /// touch the history on disk, which only the stored key can decrypt.
    static func load() throws -> SymmetricKey? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess {
            guard let data = result as? Data, data.count == 32 else { throw Failure(status: errSecDecode) }
            return SymmetricKey(data: data)
        }
        guard status == errSecItemNotFound else { throw Failure(status: status) }
        return nil
    }

    /// Makes a new key and stores it. Only for when no history sealed
    /// with an earlier key is on disk (see `ItemCipher.key`).
    static func create() throws -> SymmetricKey {
        let key = SymmetricKey(size: .bits256)
        let add: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrLabel: "Klippari history key",
            kSecAttrDescription: "Encrypts Klippari's clipboard history on disk",
            kSecValueData: key.withUnsafeBytes { Data($0) },
        ]
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw Failure(status: added) }
        return key
    }
}
