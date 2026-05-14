import Foundation
import CryptoKit
import Security
import TmpspaceCore

/// Handles AES-256-GCM encryption and decryption of panel data.
/// Manages a symmetric encryption key stored in the macOS Keychain,
/// with a file-based fallback if Keychain is unavailable.
final class EncryptionService: Sendable {

    // MARK: - Private state

    private let key: SymmetricKey

    // MARK: - Init

    init() throws {
        func blog(_ msg: String) {
            guard let data = (msg + "\n").data(using: .utf8) else { return }
            let url = URL(fileURLWithPath: "/tmp/tmpspace-boot.log")
            if let h = try? FileHandle(forWritingTo: url) {
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: data)
                try? h.close()
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
        blog("EncryptionService.init — loading or creating key...")
        self.key = try Self.loadOrCreateKey()
        blog("EncryptionService.init — key ready")
    }

    // MARK: - Public API

    /// Encrypts plaintext data using AES-256-GCM.
    /// - Parameter data: The plaintext data to encrypt.
    /// - Returns: Combined representation (nonce + ciphertext + authentication tag).
    func encrypt(_ data: Data) throws -> Data {
        let sealedBox = try AES.GCM.seal(data, using: key)
        guard let combined = sealedBox.combined else {
            throw EncryptionError.encryptionFailed
        }
        return combined
    }

    /// Decrypts data previously encrypted with `encrypt(_:)`.
    /// - Parameter data: The combined representation (nonce + ciphertext + tag).
    /// - Returns: The original plaintext data.
    func decrypt(_ data: Data) throws -> Data {
        let sealedBox = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(sealedBox, using: key)
    }

    // MARK: - Key management

    private static func loadOrCreateKey() throws -> SymmetricKey {
        func blog(_ msg: String) {
            guard let data = (msg + "\n").data(using: .utf8) else { return }
            let url = URL(fileURLWithPath: "/tmp/tmpspace-boot.log")
            if let h = try? FileHandle(forWritingTo: url) {
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: data)
                try? h.close()
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }

        blog("loadOrCreateKey — using file-based key storage")

        // Use file-based key exclusively to avoid Keychain deadlocks
        // that occur when the menu bar app hasn't finished launching.
        let fileURL = fallbackKeyFileURL()
        blog("loadOrCreateKey — file path: \(fileURL.path)")

        // Try loading existing key from file.
        if let fileKey = try? loadKeyFromFile(at: fileURL) {
            blog("loadOrCreateKey — loaded existing key from file")
            return fileKey
        }

        blog("loadOrCreateKey — generating new key...")
        let newKey = SymmetricKey(size: .bits256)
        try storeKeyInFile(key: newKey, at: fileURL)
        blog("loadOrCreateKey — new key stored in file")

        return newKey
    }

    // MARK: - Keychain operations

    private static func loadKeyFromKeychain(label: String) throws -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: label,
            kSecAttrAccount as String: label,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              data.count == SymmetricKeySize.bits256.bitCount / 8 else {
            throw EncryptionError.keychainReadFailed(status: status)
        }

        return SymmetricKey(data: data)
    }

    private static func storeKeyInKeychain(key: SymmetricKey, label: String) throws {
        let keyData = key.withUnsafeBytes { Data($0) }

        // Remove any previously stored key first (ignore not-found errors).
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: label,
            kSecAttrAccount as String: label,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: label,
            kSecAttrAccount as String: label,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw EncryptionError.keychainWriteFailed(status: status)
        }
    }

    // MARK: - Fallback file storage

    private static func fallbackKeyFileURL() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let directory = appSupport.appendingPathComponent("Tmpspace", isDirectory: true)
        return directory.appendingPathComponent(".encryption_key")
    }

    private static func loadKeyFromFile(at url: URL) throws -> SymmetricKey {
        let data = try Data(contentsOf: url)
        guard data.count == SymmetricKeySize.bits256.bitCount / 8 else {
            throw EncryptionError.corruptKeyFile
        }
        return SymmetricKey(data: data)
    }

    private static func storeKeyInFile(key: SymmetricKey, at url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )

        let keyData = key.withUnsafeBytes { Data($0) }
        try keyData.write(to: url, options: [.atomic, .completeFileProtection])
    }
}

// MARK: - EncryptionError

enum EncryptionError: LocalizedError {
    case keychainReadFailed(status: OSStatus)
    case keychainWriteFailed(status: OSStatus)
    case encryptionFailed
    case decryptionFailed
    case corruptKeyFile

    var errorDescription: String? {
        switch self {
        case .keychainReadFailed(let status):
            return "Failed to read encryption key from Keychain (OSStatus: \(status))"
        case .keychainWriteFailed(let status):
            return "Failed to write encryption key to Keychain (OSStatus: \(status))"
        case .encryptionFailed:
            return "Failed to encrypt data"
        case .decryptionFailed:
            return "Failed to decrypt data — the data may be corrupted"
        case .corruptKeyFile:
            return "The encryption-key file is corrupted (wrong size)"
        }
    }
}
