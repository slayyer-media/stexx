import Foundation
import Security

/// Persists the auth session. Tokens live in the Keychain, never in
/// UserDefaults.
protocol SessionStore: Sendable {
    func load() -> Session?
    func save(_ session: Session) throws
    func clear()
    /// Saves `session` (or clears the store for `nil`) only if the stored
    /// session still belongs to `userID` and holds `refreshToken`, i.e.
    /// nobody signed out, signed in as someone else or rotated the tokens
    /// meanwhile. Returns whether the store changed.
    func replace(userID: Profile.ID, refreshToken: String, with session: Session?) -> Bool
}

extension SessionStore {
    /// Non-atomic fallback. `CachedSessionStore` and `InMemorySessionStore`
    /// do the check and the write under one lock.
    func replace(userID: Profile.ID, refreshToken: String, with session: Session?) -> Bool {
        guard let current = load(), current.userID == userID, current.refreshToken == refreshToken else { return false }
        guard let session else {
            clear()
            return true
        }
        return (try? save(session)) != nil
    }
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

/// The app's store: keeps the session in memory (the source of truth for
/// this launch) and persists it to `backing` (the Keychain) best-effort.
///
/// A failed Keychain write (missing entitlement, locked device) therefore
/// can't leave the app "signed in" with no readable token: requests keep
/// working with the in-memory session, it just won't survive a relaunch.
/// All reads and writes go through one lock, so `replace` is atomic with
/// respect to sign-in and sign-out.
final class CachedSessionStore: SessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private let backing: any SessionStore
    private var session: Session?

    init(backing: any SessionStore) {
        self.backing = backing
        self.session = backing.load()
    }

    func load() -> Session? {
        lock.withLock { session }
    }

    /// Never fails for the in-memory copy; a persistence error is rethrown
    /// after the session is already in use.
    func save(_ session: Session) throws {
        try lock.withLock {
            self.session = session
            try backing.save(session)
        }
    }

    func clear() {
        lock.withLock {
            session = nil
            backing.clear()
        }
    }

    func replace(userID: Profile.ID, refreshToken: String, with session: Session?) -> Bool {
        lock.withLock {
            guard let current = self.session, current.userID == userID, current.refreshToken == refreshToken else {
                return false
            }
            self.session = session
            if let session { try? backing.save(session) } else { backing.clear() }
            return true
        }
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

    func replace(userID: Profile.ID, refreshToken: String, with session: Session?) -> Bool {
        lock.withLock {
            guard let current = self.session, current.userID == userID, current.refreshToken == refreshToken else {
                return false
            }
            self.session = session
            return true
        }
    }
}
