import Foundation
import Security

/// Persists the auth session. Tokens live in the Keychain, never in
/// UserDefaults.
protocol SessionStore: Sendable {
    func load() -> Session?
    func save(_ session: Session) throws
    func clear()
}

struct KeychainSessionStore: SessionStore {
    var service = "gay.stexx.app.session"
    var account = "current"

    struct KeychainError: Error {
        let status: OSStatus
    }

    func load() -> Session? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return try? JSONDecoder.stexx().decode(Session.self, from: data)
    }

    func save(_ session: Session) throws {
        let data = try JSONEncoder.stexx().encode(session)
        clear()
        var query = baseQuery
        query[kSecValueData as String] = data
        // Never synced to iCloud Keychain, never restored to another device.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func clear() {
        _ = SecItemDelete(baseQuery as CFDictionary)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// For previews and tests.
final class InMemorySessionStore: SessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var session: Session?

    init(session: Session? = nil) {
        self.session = session
    }

    func load() -> Session? {
        lock.withLock { session }
    }

    func save(_ session: Session) throws {
        lock.withLock { self.session = session }
    }

    func clear() {
        lock.withLock { session = nil }
    }
}
