import Foundation
import Security

/// Small synchronous key → bytes storage for end-to-end encryption secrets
/// (identity key, prekeys, sessions, trusted identities). Synchronous because
/// libsignal's store callbacks are. Only ever used from `E2EEngine`, which
/// serializes access.
protocol E2ESecretStorage: AnyObject, Sendable {
    func read(_ key: String) throws -> Data?
    func write(_ data: Data, for key: String) throws
    func delete(_ key: String) throws
    /// Every stored key that starts with `prefix`.
    func keys(withPrefix prefix: String) throws -> [String]
}

extension E2ESecretStorage {
    func deleteAll(withPrefix prefix: String) throws {
        for key in try keys(withPrefix: prefix) { try delete(key) }
    }
}

/// The app's storage: one Keychain item per key.
///
/// - `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: never synced to
///   iCloud Keychain and never restored onto another device (an encrypted
///   backup restored to a new phone doesn't carry these items), but readable
///   while the app runs after the first unlock, like the session token. A
///   stricter "when unlocked" class would let a decrypt that races the
///   screen locking fail half way, after libsignal has used up a one-time
///   key, and lose the message.
/// - `kSecAttrSynchronizable` is explicitly false.
final class KeychainSecretStorage: E2ESecretStorage, @unchecked Sendable {
    let service: String

    struct KeychainError: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String { "Keychain error \(status)" }
    }

    init(service: String = "gay.stexx.app.e2e") {
        self.service = service
    }

    func read(_ key: String) throws -> Data? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess: return item as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainError(status: status)
        }
    }

    func write(_ data: Data, for key: String) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(baseQuery(key) as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError(status: status) }
        var add = baseQuery(key)
        add.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
    }

    func delete(_ key: String) throws {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    func keys(withPrefix prefix: String) throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kCFBooleanFalse!,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        switch status {
        case errSecSuccess:
            let list = items as? [[String: Any]] ?? []
            return list.compactMap { $0[kSecAttrAccount as String] as? String }.filter { $0.hasPrefix(prefix) }
        case errSecItemNotFound:
            return []
        default:
            throw KeychainError(status: status)
        }
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: kCFBooleanFalse!,
        ]
    }
}

/// For tests and previews.
final class InMemorySecretStorage: E2ESecretStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    /// Tests: make the next writes fail.
    var failWrites = false

    init() {}

    func read(_ key: String) throws -> Data? {
        lock.withLock { items[key] }
    }

    func write(_ data: Data, for key: String) throws {
        try lock.withLock {
            if failWrites { throw KeychainSecretStorage.KeychainError(status: errSecNotAvailable) }
            items[key] = data
        }
    }

    func delete(_ key: String) throws {
        lock.withLock { _ = items.removeValue(forKey: key) }
    }

    func keys(withPrefix prefix: String) throws -> [String] {
        lock.withLock { items.keys.filter { $0.hasPrefix(prefix) } }
    }
}
