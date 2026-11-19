import Foundation
import LibSignalClient

/// This device's key bookkeeping, next to the libsignal records themselves.
struct E2ELocalKeyState: Codable, Hashable, Sendable {
    var registrationID: UInt32
    /// Next ids to hand out. Like Signal's clients: a random 24-bit start,
    /// counting up and wrapping (1…0xFFFFFF).
    var nextPreKeyID: UInt32
    var nextSignedPreKeyID: UInt32
    var nextKyberPreKeyID: UInt32
    /// The signed prekey and Kyber last-resort key the server has now.
    var currentSignedPreKeyID: UInt32?
    var currentLastResortKyberID: UInt32?
    /// Replaced signed / last-resort keys, kept for `E2EKeyPolicy.keepReplacedKeys`
    /// so prekey messages already in flight still decrypt.
    var replacedSignedPreKeys: [UInt32: Date] = [:]
    var replacedLastResortKyber: [UInt32: Date] = [:]
    /// Every Kyber last-resort id (they live in the same id space as the
    /// one-time Kyber prekeys but are never deleted on use).
    var lastResortKyberIDs: Set<UInt32> = []
    /// One-time prekey id → the registration epoch it was uploaded in.
    /// `PUT /keys` replaces every one-time key on the server and starts a new
    /// epoch; keys of an old epoch are dropped once it's been replaced for
    /// `keepReplacedKeys`.
    var oneTimePreKeys: [UInt32: Int] = [:]
    var oneTimeKyberPreKeys: [UInt32: Int] = [:]
    var epoch = 0
    /// When each epoch was replaced by the next one.
    var epochReplacedAt: [Int: Date] = [:]
    /// The identity key (base64) the server confirmed with `PUT /keys`.
    var registeredIdentityKey: String?

    static func fresh() -> E2ELocalKeyState {
        E2ELocalKeyState(
            registrationID: UInt32.random(in: 1...16380),
            nextPreKeyID: E2EKeyPolicy.randomKeyID(),
            nextSignedPreKeyID: E2EKeyPolicy.randomKeyID(),
            nextKyberPreKeyID: E2EKeyPolicy.randomKeyID()
        )
    }
}

/// A `PUT /keys` upload saved before it's sent, so a failed attempt is
/// re-sent with the same keys instead of generating new ones.
struct E2EPendingRegistration: Codable, Hashable, Sendable {
    var registration: KeyRegistration
    /// The epoch its one-time keys belong to.
    var epoch: Int
}

/// An identity key we saw that differs from the one the user trusts, waiting
/// for the user to accept it.
struct E2EPendingIdentity: Codable, Hashable, Sendable {
    var identityKey: String
    var detectedAt: Date
}

enum E2EKeyPolicy {
    /// Signed prekey and Kyber last-resort key rotation (`docs/api.md`: about weekly).
    static let rotationInterval: TimeInterval = 7 * 24 * 3600
    /// How long replaced keys stay usable for in-flight prekey messages.
    static let keepReplacedKeys: TimeInterval = 30 * 24 * 3600
    /// Re-register (fresh one-time keys, same identity) once this many
    /// batches of one-time keys pile up locally: the server hands out the
    /// oldest first but never says which, so this is how old ones get dropped.
    static let maxLocalBatches = 4

    static func randomKeyID() -> UInt32 { UInt32.random(in: 1...0xFF_FFFF) }

    /// 1…0xFFFFFF, wrapping.
    static func next(after id: UInt32) -> UInt32 { id >= 0xFF_FFFF ? 1 : id + 1 }
}

/// libsignal's protocol stores over `E2ESecretStorage` (the Keychain), one
/// namespace per account. Write-through cache; a failed write throws, which
/// makes libsignal fail the whole operation instead of keeping state it
/// couldn't persist.
///
/// Trust: the first identity seen for someone is trusted (TOFU). A different
/// one later is *not* trusted (`isTrustedIdentity` → false, so libsignal
/// refuses to encrypt to it or decrypt from it) and is recorded as pending
/// until the user accepts it; see `E2EEngine.acceptIdentityChange`.
///
/// Not thread-safe: only `E2EEngine` (an actor) uses it.
final class E2EProtocolStore: IdentityKeyStore, PreKeyStore, SignedPreKeyStore, KyberPreKeyStore, LibSignalClient.SessionStore {
    let storage: any E2ESecretStorage
    let userID: Profile.ID
    let identityKeyPair: IdentityKeyPair
    private(set) var state: E2ELocalKeyState
    private var cache: [String: Data] = [:]
    private var pendingCache: [Profile.ID: E2EPendingIdentity]?
    /// Set when the account's keys were erased from this device (sign-out or
    /// account deletion). An operation that was already running then (a key
    /// upload, a decryption) fails instead of writing any of them back.
    private(set) var isRevoked = false

    /// A write to a store whose keys were erased.
    struct RevokedError: Error {}

    static let deviceID: UInt32 = 1

    private init(storage: any E2ESecretStorage, userID: Profile.ID, identity: IdentityKeyPair, state: E2ELocalKeyState) {
        self.storage = storage
        self.userID = userID
        self.identityKeyPair = identity
        self.state = state
    }

    static func prefix(for userID: Profile.ID) -> String { "\(userID)/" }

    /// The account's stored keys, or `nil` if it has no identity yet.
    static func load(storage: any E2ESecretStorage, userID: Profile.ID) throws -> E2EProtocolStore? {
        let prefix = prefix(for: userID)
        guard let identityData = try storage.read(prefix + "identity"),
              let stateData = try storage.read(prefix + "state")
        else { return nil }
        let identity = try IdentityKeyPair(bytes: identityData)
        let state = try JSONDecoder().decode(E2ELocalKeyState.self, from: stateData)
        return E2EProtocolStore(storage: storage, userID: userID, identity: identity, state: state)
    }

    /// Loads the account's keys, or creates a new identity and registration
    /// id if there are none.
    static func loadOrCreate(storage: any E2ESecretStorage, userID: Profile.ID) throws -> E2EProtocolStore {
        if let existing = try load(storage: storage, userID: userID) { return existing }
        // A new identity. Anything left under this prefix (a half-written
        // earlier attempt) belongs to no identity and is dropped.
        let prefix = prefix(for: userID)
        try storage.deleteAll(withPrefix: prefix)
        let identity = IdentityKeyPair.generate()
        let state = E2ELocalKeyState.fresh()
        try storage.write(try JSONEncoder().encode(state), for: prefix + "state")
        try storage.write(identity.serialize(), for: prefix + "identity")
        return E2EProtocolStore(storage: storage, userID: userID, identity: identity, state: state)
    }

    /// Stops this instance from writing: its account's keys are being erased.
    func revoke() {
        isRevoked = true
        cache = [:]
        pendingCache = nil
    }

    /// Removes every secret of `userID` (sign-out and account deletion).
    static func wipe(storage: any E2ESecretStorage, userID: Profile.ID) throws {
        try storage.deleteAll(withPrefix: prefix(for: userID))
    }

    var localAddress: ProtocolAddress {
        // A Stexx user id is ASCII; ProtocolAddress only fails on invalid UTF-8.
        try! ProtocolAddress(name: userID, deviceId: Self.deviceID)
    }

    var identityKeyBase64: String { identityKeyPair.identityKey.serialize().base64EncodedString() }

    // MARK: Raw storage

    private func key(_ suffix: String) -> String { Self.prefix(for: userID) + suffix }

    private func get(_ suffix: String) throws -> Data? {
        let key = key(suffix)
        if let cached = cache[key] { return cached }
        let data = try storage.read(key)
        if let data { cache[key] = data }
        return data
    }

    private func put(_ data: Data, _ suffix: String) throws {
        guard !isRevoked else { throw RevokedError() }
        let key = key(suffix)
        try storage.write(data, for: key)
        cache[key] = data
    }

    private func remove(_ suffix: String) throws {
        let key = key(suffix)
        try storage.delete(key)
        cache[key] = nil
    }

    func updateState(_ change: (inout E2ELocalKeyState) -> Void) throws {
        var next = state
        change(&next)
        guard next != state else { return }
        try put(try JSONEncoder().encode(next), "state")
        state = next
    }

    private static func sessionKey(_ address: ProtocolAddress) -> String { "session.\(address.name).\(address.deviceId)" }

    // MARK: IdentityKeyStore

    func identityKeyPair(context: StoreContext) throws -> IdentityKeyPair { identityKeyPair }

    func localRegistrationId(context: StoreContext) throws -> UInt32 { state.registrationID }

    func saveIdentity(_ identity: IdentityKey, for address: ProtocolAddress, context: StoreContext) throws -> IdentityChange {
        let previous = try trustedIdentity(of: address.name)
        guard previous != identity else { return .newOrUnchanged }
        try put(identity.serialize(), "trusted.\(address.name)")
        return previous == nil ? .newOrUnchanged : .replacedExisting
    }

    func isTrustedIdentity(_ identity: IdentityKey, for address: ProtocolAddress, direction: Direction, context: StoreContext) throws -> Bool {
        guard let trusted = try trustedIdentity(of: address.name) else { return true }
        if trusted == identity { return true }
        // A key the user already moved on from (an old message from before a
        // key change): refused, but no new warning for it.
        if try retiredIdentities(of: address.name).contains(identity.serialize()) { return false }
        try recordPendingIdentity(identity, for: address.name)
        return false
    }

    func identity(for address: ProtocolAddress, context: StoreContext) throws -> IdentityKey? {
        try trustedIdentity(of: address.name)
    }

    func trustedIdentity(of peer: Profile.ID) throws -> IdentityKey? {
        try get("trusted.\(peer)").map { try IdentityKey(bytes: $0) }
    }

    /// Trusts `identity` for `peer`; the key it replaces is remembered as retired.
    func setTrustedIdentity(_ identity: IdentityKey, of peer: Profile.ID) throws {
        if let old = try trustedIdentity(of: peer), old != identity {
            var retired = try retiredIdentities(of: peer)
            retired.append(old.serialize())
            try put(try JSONEncoder().encode(Array(retired.suffix(10))), "retired.\(peer)")
        }
        try put(identity.serialize(), "trusted.\(peer)")
    }

    /// Refuses `identity` for `peer` from now on without a warning (a key the
    /// server never backed).
    func dismissIdentity(_ identity: IdentityKey, of peer: Profile.ID) throws {
        var retired = try retiredIdentities(of: peer)
        guard !retired.contains(identity.serialize()) else { return }
        retired.append(identity.serialize())
        try put(try JSONEncoder().encode(Array(retired.suffix(10))), "retired.\(peer)")
    }

    /// Keys the user moved on from, or that were dismissed: refused quietly.
    func retiredIdentities(of peer: Profile.ID) throws -> [Data] {
        try get("retired.\(peer)").map { try JSONDecoder().decode([Data].self, from: $0) } ?? []
    }

    // MARK: Uploads in flight

    func pendingRegistration() throws -> E2EPendingRegistration? {
        try get("upload.registration").map { try JSONDecoder().decode(E2EPendingRegistration.self, from: $0) }
    }

    func setPendingRegistration(_ upload: E2EPendingRegistration?) throws {
        if let upload { try put(try JSONEncoder().encode(upload), "upload.registration") } else { try remove("upload.registration") }
    }

    func pendingRotation() throws -> SignedPreKeyRotation? {
        try get("upload.rotation").map { try JSONDecoder().decode(SignedPreKeyRotation.self, from: $0) }
    }

    func setPendingRotation(_ rotation: SignedPreKeyRotation?) throws {
        if let rotation { try put(try JSONEncoder().encode(rotation), "upload.rotation") } else { try remove("upload.rotation") }
    }

    // MARK: Pending identity changes

    func pendingIdentity(of peer: Profile.ID) throws -> E2EPendingIdentity? {
        try get("pending.\(peer)").map { try JSONDecoder().decode(E2EPendingIdentity.self, from: $0) }
    }

    /// Every pending change (read from storage once, then kept current).
    func allPendingIdentities() throws -> [Profile.ID: E2EPendingIdentity] {
        if let pendingCache { return pendingCache }
        let prefix = key("pending.")
        var result: [Profile.ID: E2EPendingIdentity] = [:]
        for fullKey in try storage.keys(withPrefix: prefix) {
            let peer = String(fullKey.dropFirst(prefix.count))
            if let pending = try pendingIdentity(of: peer) { result[peer] = pending }
        }
        pendingCache = result
        return result
    }

    /// Records `identity` as waiting for the user (no-op if it's already the
    /// pending one).
    func recordPendingIdentity(_ identity: IdentityKey, for peer: Profile.ID, now: Date = .now) throws {
        let encoded = identity.serialize().base64EncodedString()
        if try pendingIdentity(of: peer)?.identityKey == encoded { return }
        let pending = E2EPendingIdentity(identityKey: encoded, detectedAt: now)
        _ = try allPendingIdentities()
        try put(try JSONEncoder().encode(pending), "pending.\(peer)")
        pendingCache?[peer] = pending
    }

    func clearPendingIdentity(of peer: Profile.ID) throws {
        _ = try allPendingIdentities()
        try remove("pending.\(peer)")
        pendingCache?[peer] = nil
    }

    // MARK: PreKeyStore

    func loadPreKey(id: UInt32, context: StoreContext) throws -> PreKeyRecord {
        guard let data = try get("prekey.\(id)") else { throw SignalError.invalidKeyIdentifier("no prekey \(id)") }
        return try PreKeyRecord(bytes: data)
    }

    func storePreKey(_ record: PreKeyRecord, id: UInt32, context: StoreContext) throws {
        try put(record.serialize(), "prekey.\(id)")
    }

    func removePreKey(id: UInt32, context: StoreContext) throws {
        try remove("prekey.\(id)")
        try updateState { $0.oneTimePreKeys[id] = nil }
    }

    // MARK: SignedPreKeyStore

    func loadSignedPreKey(id: UInt32, context: StoreContext) throws -> SignedPreKeyRecord {
        guard let data = try get("signed.\(id)") else { throw SignalError.invalidKeyIdentifier("no signed prekey \(id)") }
        return try SignedPreKeyRecord(bytes: data)
    }

    func storeSignedPreKey(_ record: SignedPreKeyRecord, id: UInt32, context: StoreContext) throws {
        try put(record.serialize(), "signed.\(id)")
    }

    func removeSignedPreKey(id: UInt32) throws {
        try remove("signed.\(id)")
    }

    // MARK: KyberPreKeyStore

    func loadKyberPreKey(id: UInt32, context: StoreContext) throws -> KyberPreKeyRecord {
        guard let data = try get("kyber.\(id)") else { throw SignalError.invalidKeyIdentifier("no kyber prekey \(id)") }
        return try KyberPreKeyRecord(bytes: data)
    }

    func storeKyberPreKey(_ record: KyberPreKeyRecord, id: UInt32, context: StoreContext) throws {
        try put(record.serialize(), "kyber.\(id)")
    }

    /// One-time Kyber keys are deleted. The last-resort key stays, but each
    /// (key, signed prekey, base key) combination is accepted only once, so
    /// a replayed prekey message can't set up a session again.
    func markKyberPreKeyUsed(id: UInt32, signedPreKeyId: UInt32, baseKey: PublicKey, context: StoreContext) throws {
        if state.lastResortKyberIDs.contains(id) {
            let usedKey = "kyber-used.\(id).\(signedPreKeyId)"
            var seen = try get(usedKey).flatMap { try? JSONDecoder().decode([Data].self, from: $0) } ?? []
            let base = baseKey.serialize()
            if seen.contains(base) { throw SignalError.invalidMessage("reused base key") }
            seen.append(base)
            try put(try JSONEncoder().encode(seen), usedKey)
        } else {
            try removeKyberPreKey(id: id)
        }
    }

    func removeKyberPreKey(id: UInt32) throws {
        try remove("kyber.\(id)")
        try storage.deleteAll(withPrefix: key("kyber-used.\(id)."))
        try updateState {
            $0.oneTimeKyberPreKeys[id] = nil
            $0.lastResortKyberIDs.remove(id)
        }
    }

    // MARK: SessionStore

    func loadSession(for address: ProtocolAddress, context: StoreContext) throws -> SessionRecord? {
        try get(Self.sessionKey(address)).map { try SessionRecord(bytes: $0) }
    }

    func loadExistingSessions(for addresses: [ProtocolAddress], context: StoreContext) throws -> [SessionRecord] {
        try addresses.map { address in
            guard let record = try loadSession(for: address, context: context) else {
                throw SignalError.sessionNotFound("\(address)")
            }
            return record
        }
    }

    func storeSession(_ record: SessionRecord, for address: ProtocolAddress, context: StoreContext) throws {
        try put(record.serialize(), Self.sessionKey(address))
    }

    func deleteSession(for address: ProtocolAddress) throws {
        try remove(Self.sessionKey(address))
    }

    func hasActiveSession(with address: ProtocolAddress) throws -> Bool {
        try loadSession(for: address, context: NullContext())?.hasCurrentState() ?? false
    }
}
