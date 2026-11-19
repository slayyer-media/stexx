import Foundation
import LibSignalClient

/// Why an end-to-end encrypted send didn't happen. Shown above the composer.
enum E2EError: LocalizedError, Equatable {
    /// The recipient's identity key changed and the user hasn't accepted it.
    case identityChanged(peer: Profile.ID)
    /// `E2E_MODE=required` and the recipient has no keys yet.
    case recipientHasNoKeys
    /// libsignal refused (bad bundle signature, broken session, Keychain).
    case encryptionFailed
    case messageTooLong
    case notSignedIn

    var errorDescription: String? {
        switch self {
        case .identityChanged:
            String(localized: "Their security key changed. Accept the new key at the top of the chat to keep messaging.")
        case .recipientHasNoKeys:
            String(localized: "They can't receive encrypted messages yet, so this wasn't sent. They need to update Stexx.")
        case .encryptionFailed:
            String(localized: "Couldn't encrypt this message. Try again in a moment.")
        case .messageTooLong:
            String(localized: "This message is too long to send.")
        case .notSignedIn:
            APIError.unauthorized.errorDescription
        }
    }
}

/// What the app shows about encryption (`E2EStatus` mirrors it on the main actor).
struct E2ESnapshot: Equatable, Sendable {
    var mode: E2EConfig.Mode = .off
    /// People whose identity key changed, waiting for the user to accept it.
    var keyChanges: [Profile.ID: Date] = [:]
    /// People this device has an encrypted session with.
    var encryptedPeers: Set<Profile.ID> = []
}

/// How a text message goes out.
enum E2EOutgoing: Equatable, Sendable {
    case plaintext
    case envelope(MessageEnvelope)
}

/// How a message to someone goes out, decided before anything is encrypted
/// or uploaded (`E2EEngine.route`).
enum E2ERoute: Equatable, Sendable {
    /// `E2E_MODE=off`, or `optional` and the recipient has no keys.
    case plaintext
    /// A session is ready: seal the content with `E2EEngine.seal`.
    case encrypt
}

/// What's inside an envelope: small UTF-8 JSON (`docs/api.md`, "Sending
/// encrypted messages"): the text and/or an encrypted photo's pointer.
/// Unknown fields are ignored.
struct E2EPayload: Codable, Equatable, Sendable {
    var text: String?
    var attachment: E2EAttachmentPointer? = nil
    /// The message's timer (the send's `expiresAfterSeconds`), so the
    /// recipient knows how long a photo can exist on the server (the server
    /// only reports `expiresAt` once the message is read). Omitted when
    /// `nil`; older versions ignore it.
    var expiresAfterSeconds: Int? = nil

    /// The server's longest timer.
    static let maxExpiresAfterSeconds = 30 * 24 * 3600

    /// `expiresAfterSeconds` if it's a timer the server could have accepted.
    var timer: Int? {
        guard let seconds = expiresAfterSeconds, (1...Self.maxExpiresAfterSeconds).contains(seconds) else { return nil }
        return seconds
    }

    private enum CodingKeys: String, CodingKey {
        case text, attachment, expiresAfterSeconds
    }
}

extension E2EPayload {
    /// Lenient about the timer: a malformed one is dropped, never the text
    /// and photo with it.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        attachment = try container.decodeIfPresent(E2EAttachmentPointer.self, forKey: .attachment)
        expiresAfterSeconds = (try? container.decodeIfPresent(Int.self, forKey: .expiresAfterSeconds)) ?? nil
    }
}

/// The Signal Protocol client: keys, sessions, encrypt and decrypt, for the
/// signed-in account. One instance for the app; it follows the session
/// (`currentUserID`) and keeps each account's keys apart.
///
/// - Keys: an identity key, registration id, signed prekey, Kyber
///   last-resort key and batches of one-time EC and Kyber prekeys, private
///   parts in the Keychain (`E2EProtocolStore`). `syncKeys()` registers,
///   replenishes and rotates them against `GET /keys/status`.
/// - Sending: `route` decides plaintext or envelope from `E2E_MODE`, runs
///   the text rules and sets up a session with PQXDH from a prekey bundle if
///   needed; `seal` encrypts the payload (text and/or a photo pointer) with
///   the Double Ratchet. `prepareOutgoing` does both for text.
/// - Receiving: `reveal` decrypts envelopes once and keeps the plaintext (and
///   photo keys) in the encrypted local history; later copies of the same
///   message (REST, websocket, conversation list) are read from there.
/// - Identity changes are held until the user accepts them; until then
///   nothing is sent to that person and their new-key messages stay hidden.
///
/// It's an actor, so libsignal's synchronous store callbacks never run
/// concurrently. Never logs keys, ciphertext or plaintext.
actor E2EEngine {
    private final class Account {
        let userID: Profile.ID
        let store: E2EProtocolStore
        var history: E2EHistory
        var historyDirty = false

        init(userID: Profile.ID, store: E2EProtocolStore, history: E2EHistory) {
            self.userID = userID
            self.store = store
            self.history = history
        }
    }

    private let api: any APIClient
    private let secrets: any E2ESecretStorage
    private let historyPersistence: any E2EHistoryPersistence
    private let currentUserID: @Sendable () async -> Profile.ID?
    private let now: @Sendable () -> Date
    private var onSnapshot: (@Sendable (E2ESnapshot) async -> Void)?

    private var account: Account?
    private var config: E2EConfig?
    private var configFetchedAt: Date?
    /// Whose config `config` is (`contentRules` are per account).
    private var configUserID: Profile.ID?
    /// Accounts deleted in this run: nothing may write their keys again.
    private var wipedUsers: Set<Profile.ID> = []
    /// Every protocol store opened per account (weakly), so erasing an
    /// account's keys also stops stores still held by running operations.
    private var openStores: [Profile.ID: [WeakStore]] = [:]
    private final class WeakStore {
        weak var store: E2EProtocolStore?
        init(_ store: E2EProtocolStore) { self.store = store }
    }
    /// After a 429 on `PUT /keys` (10 a day), don't try again before this.
    private var registerBlockedUntil: [Profile.ID: Date] = [:]
    private var sessionSetups: [Profile.ID: Task<Void, any Error>] = [:]
    private var identityCheckedAt: [Profile.ID: Date] = [:]
    private var encryptedPeers: Set<Profile.ID> = []
    private var lastSnapshot = E2ESnapshot()
    private var syncTask: Task<Void, Never>?
    private var syncGeneration = 0
    /// Encrypted photos being sent, by client ID: a retry re-uploads the same
    /// blob, so whichever copy the server keeps matches the local pointer.
    /// Memory only; dropped on success and sign-out.
    private var outgoingMedia: [String: (blob: Data, pointer: E2EAttachmentPointer)] = [:]
    /// Drops the decrypted copies of photos whose keys went (`ChatMediaLoader`).
    private let evictMedia: @Sendable ([Message.ID]) async -> Void
    /// When the history was last pruned (at most every `historyPruneInterval` while revealing).
    private var historyPrunedAt: Date?

    static let deviceID: UInt32 = 1
    /// How often `reveal` prunes the history while the app runs.
    static let historyPruneInterval: TimeInterval = 60
    /// How long a fetched `E2EConfig` is used before it's re-read.
    static let configLifetime: TimeInterval = 10 * 60
    /// At most one identity re-check per person in this window (thread opens).
    static let identityCheckInterval: TimeInterval = 10 * 60

    /// - Parameters:
    ///   - api: The plain client (not `E2EAPIClient`).
    ///   - currentUserID: The signed-in account, if any.
    ///   - evictMedia: Drops decrypted photos from memory once their keys are gone.
    init(
        api: any APIClient,
        secrets: any E2ESecretStorage,
        history: any E2EHistoryPersistence,
        currentUserID: @escaping @Sendable () async -> Profile.ID?,
        now: @escaping @Sendable () -> Date = { Date() },
        evictMedia: @escaping @Sendable ([Message.ID]) async -> Void = { ids in
            for id in ids { await ChatMediaLoader.shared.evict(id) }
        }
    ) {
        self.api = api
        self.secrets = secrets
        self.historyPersistence = history
        self.currentUserID = currentUserID
        self.now = now
        self.evictMedia = evictMedia
    }

    func setSnapshotHandler(_ handler: @escaping @Sendable (E2ESnapshot) async -> Void) async {
        onSnapshot = handler
        // Anything published before the handler existed.
        lastSnapshot = E2ESnapshot()
        await publish()
    }

    // MARK: Account

    /// The signed-in account's state, loading it (or, with `create`, a new
    /// identity) on first use. `nil` when signed out, or when it has no
    /// identity and `create` is false.
    private func loadAccount(create: Bool) async throws -> Account? {
        let userID = await currentUserID()
        // Re-checked after the await: never two `Account`s (and two caches)
        // for the same keys.
        if let account, account.userID == userID { return account }
        if let account { flushHistory(account) }
        account = nil
        encryptedPeers = []
        identityCheckedAt = [:]
        guard let userID else { return nil }
        let store: E2EProtocolStore
        if create {
            store = try E2EProtocolStore.loadOrCreate(storage: secrets, userID: userID)
        } else {
            guard let existing = try E2EProtocolStore.load(storage: secrets, userID: userID) else { return nil }
            store = existing
        }
        openStores[userID] = (openStores[userID] ?? []).filter { $0.store != nil } + [WeakStore(store)]
        let loaded = Account(userID: userID, store: store, history: loadHistory(userID: userID))
        account = loaded
        // Expired text and photo keys leave the file now, not with the next change.
        _ = pruneHistory(of: loaded)
        flushHistory(loaded)
        return loaded
    }

    /// Drops expired entries and photo keys past their deadline. Returns the
    /// IDs of messages whose entry or photo key went.
    private func pruneHistory(of account: Account) -> [Message.ID] {
        let date = now()
        historyPrunedAt = date
        let before = account.history
        account.history.prune(now: date)
        guard account.history != before else { return [] }
        account.historyDirty = true
        return before.messages.compactMap { id, entry in
            guard let after = account.history.messages[id] else { return id }
            return entry.attachment != nil && after.attachment == nil ? id : nil
        }.sorted()
    }

    /// Prunes the history during a session (expired messages, photo keys past
    /// their deadline), not only when it's loaded: on foreground, and from
    /// `reveal` at most once a minute. Their decrypted photos leave memory
    /// too. Returns the IDs of messages whose entry or photo key went.
    @discardableResult
    func pruneHistory() async -> [Message.ID] {
        guard let account = try? await loadAccount(create: false) else { return [] }
        let dropped = pruneHistory(of: account)
        flushHistory(account)
        if !dropped.isEmpty { await evictMedia(dropped) }
        return dropped
    }

    /// The account's history. Never lets an unreadable history be silently
    /// overwritten: after a failed read (and one retry) the file is moved
    /// aside and a new one is started.
    private func loadHistory(userID: Profile.ID) -> E2EHistory {
        for _ in 0..<2 {
            do {
                return try historyPersistence.load(userID: userID) ?? E2EHistory()
            } catch {
                continue
            }
        }
        try? historyPersistence.setAside(userID: userID)
        return E2EHistory()
    }

    private func requireAccount() async throws -> Account {
        guard let account = try await loadAccount(create: true) else { throw E2EError.notSignedIn }
        return account
    }

    private func isCurrent(_ candidate: Account) -> Bool { account === candidate }

    private func flushHistory(_ account: Account) {
        // An erased account's history must not be written back.
        guard account.historyDirty, !account.store.isRevoked else { return }
        do {
            try historyPersistence.save(account.history, userID: account.userID)
            account.historyDirty = false
        } catch {
            // Kept in memory and retried with the next change.
        }
    }

    /// The session ended without the user signing out (it expired or was
    /// revoked): drop in-memory state. Keys and history stay on the device
    /// for the next sign-in to this account. An explicit sign-out also calls
    /// `erase(userID:)`.
    func signedOut() async {
        if let account { flushHistory(account) }
        account = nil
        syncTask?.cancel()
        syncTask = nil
        config = nil
        configFetchedAt = nil
        configUserID = nil
        encryptedPeers = []
        identityCheckedAt = [:]
        sessionSetups = [:]
        outgoingMedia = [:]
        await publish()
    }

    /// The account was deleted: remove its keys, sessions and history, and
    /// never write them again in this run.
    func wipe(userID: Profile.ID) async {
        wipedUsers.insert(userID)
        await erase(userID: userID)
    }

    /// The user signed out: remove the account's keys, sessions and decrypted
    /// history from this device (docs/security.md, "The iOS client"). Signing
    /// in again here later starts a new identity (chat partners see the
    /// key-change notice) and earlier messages show the "not available on
    /// this phone" placeholder. Operations still running for the account
    /// can't write anything back (`E2EProtocolStore.revoke`). If another
    /// account is already signed in, its in-memory state is left alone.
    func erase(userID: Profile.ID) async {
        for opened in openStores.removeValue(forKey: userID) ?? [] { opened.store?.revoke() }
        let wasCurrent = account?.userID == userID
        if wasCurrent {
            account = nil
            syncTask?.cancel()
            syncTask = nil
        }
        try? E2EProtocolStore.wipe(storage: secrets, userID: userID)
        try? historyPersistence.delete(userID: userID)
        if configUserID == userID {
            config = nil
            configFetchedAt = nil
            configUserID = nil
        }
        if wasCurrent || account == nil {
            encryptedPeers = []
            identityCheckedAt = [:]
            sessionSetups = [:]
            outgoingMedia = [:]
        }
        await publish()
    }

    // MARK: Config

    /// `GET /e2e/config`, cached for `configLifetime`. Falls back to the
    /// cached value when the request fails, unless `fallBackToCache` is
    /// false: then a failed refresh throws (before a plaintext photo upload,
    /// a stale mode must not decide).
    func currentConfig(refresh: Bool = false, fallBackToCache: Bool = true) async throws -> E2EConfig {
        let userID = await currentUserID()
        let cached = configUserID == userID ? config : nil
        if !refresh, let cached, let at = configFetchedAt, now().timeIntervalSince(at) < Self.configLifetime {
            return cached
        }
        let fresh: E2EConfig
        do {
            fresh = try await api.e2eConfig()
        } catch APIError.notFound where cached == nil || (!fallBackToCache && cached?.mode == .off) {
            // A server from before end-to-end encryption: plaintext.
            fresh = .off
        } catch {
            if fallBackToCache, let cached { return cached }
            throw error
        }
        // Only keep it if the same account is still signed in.
        guard await currentUserID() == userID else { return fresh }
        config = fresh
        configFetchedAt = now()
        configUserID = userID
        await publish()
        return fresh
    }

    /// Re-read the config on the next use (after a 403: the trust ramp may have changed).
    func invalidateConfig() {
        configFetchedAt = nil
    }

    // MARK: Keys

    /// Registers, replenishes and rotates this device's keys. Runs on sign-in,
    /// launch and foreground; best effort (the next run retries). Does nothing
    /// while the server's mode is `off`.
    func syncKeys() async {
        await runSync(onlyReplenish: false)
    }

    /// `keys.low`: top up one-time prekeys.
    func replenishKeys() async {
        await runSync(onlyReplenish: true)
    }

    /// Single flight. Only the run that started a task clears it, so a run
    /// that outlived a sign-out never drops a newer account's task.
    private func runSync(onlyReplenish: Bool) async {
        if let syncTask {
            await syncTask.value
            return
        }
        syncGeneration += 1
        let generation = syncGeneration
        let task = Task { await self.performSync(onlyReplenish: onlyReplenish) }
        syncTask = task
        await task.value
        if syncGeneration == generation { syncTask = nil }
    }

    private func performSync(onlyReplenish: Bool) async {
        do {
            let config = try await currentConfig(refresh: !onlyReplenish)
            guard config.mode != .off else { return }
            let account = try await requireAccount()
            let status: KeyStatus
            do {
                status = try await api.keyStatus()
            } catch APIError.e2e(let code, _) where code == E2EErrorCode.disabled {
                return
            }
            guard isCurrent(account), !Task.isCancelled else { return }
            // An upload that reached the server even though its response didn't reach us.
            try reconcileUploads(account, status: status)
            if needsRegistration(status, account: account, config: config) {
                try await register(account, config: config)
                return
            }
            // A saved registration that's no longer needed (and that the
            // server doesn't show): drop it and its keys.
            if let stale = try account.store.pendingRegistration() { try discard(stale, from: account.store) }
            try await replenish(account, config: config, status: status)
            guard isCurrent(account), !Task.isCancelled else { return }
            if !onlyReplenish {
                try await rotateIfDue(account, status: status)
            }
            guard isCurrent(account), !Task.isCancelled else { return }
            try prune(account)
        } catch {
            // Best effort; never logs key material.
        }
    }

    private func needsRegistration(_ status: KeyStatus, account: Account, config: E2EConfig) -> Bool {
        let store = account.store
        guard status.registered,
              status.identityKey == store.identityKeyBase64,
              status.registrationID == store.state.registrationID,
              let signedID = status.signedPreKeyID, (try? store.loadSignedPreKey(id: signedID, context: NullContext())) != nil,
              let lastResortID = status.pqLastResortPreKeyID, (try? store.loadKyberPreKey(id: lastResortID, context: NullContext())) != nil
        else { return true }
        // One-time keys the server handed out but nobody used pile up; a
        // re-registration (same identity) replaces them all on the server so
        // the old ones can be dropped here later.
        let epoch = store.state.epoch
        let ecLocal = store.state.oneTimePreKeys.values.filter { $0 == epoch }.count
        let pqLocal = store.state.oneTimeKyberPreKeys.values.filter { $0 == epoch }.count
        return ecLocal > E2EKeyPolicy.maxLocalBatches * max(config.maxPreKeys, 1)
            || pqLocal > E2EKeyPolicy.maxLocalBatches * max(config.maxPqPreKeys, 1)
    }

    /// `PUT /keys`: the full key state, with a fresh batch of one-time keys
    /// in a new epoch. The upload is saved before it's sent and re-sent as
    /// is after a failure, so retries don't pile up new keys; it's committed
    /// once the server has it (here, or by `reconcileUploads` if only the
    /// response was lost).
    private func register(_ account: Account, config: E2EConfig) async throws {
        if let until = registerBlockedUntil[account.userID], until > now() { return }
        let store = account.store
        let upload: E2EPendingRegistration
        if let pending = try store.pendingRegistration(),
           pending.registration.identityKey == store.identityKeyBase64,
           pending.registration.registrationID == store.state.registrationID,
           pending.registration.preKeys.count <= config.maxPreKeys,
           pending.registration.pqPreKeys.count <= config.maxPqPreKeys,
           // Every private key still here: none used up by a peer since a
           // first attempt that did reach the server.
           try hasAllKeys(of: pending, in: store) {
            upload = pending
        } else {
            if let stale = try store.pendingRegistration() { try discard(stale, from: store) }
            let newEpoch = store.state.epoch + 1
            let signed = try makeSignedPreKey(store)
            let lastResort = try makeKyberPreKeys(store, count: 1, lastResort: true, epoch: newEpoch)[0]
            let preKeys = try makePreKeys(store, count: config.maxPreKeys, epoch: newEpoch)
            let pqPreKeys = try makeKyberPreKeys(store, count: config.maxPqPreKeys, lastResort: false, epoch: newEpoch)
            upload = E2EPendingRegistration(
                registration: KeyRegistration(
                    registrationID: store.state.registrationID,
                    deviceID: Self.deviceID,
                    identityKey: store.identityKeyBase64,
                    signedPreKey: signed,
                    pqLastResortPreKey: lastResort,
                    preKeys: preKeys,
                    pqPreKeys: pqPreKeys
                ),
                epoch: newEpoch
            )
            try store.setPendingRegistration(upload)
        }
        do {
            _ = try await api.registerKeys(upload.registration)
        } catch APIError.rateLimited(let retryAfter) {
            registerBlockedUntil[account.userID] = now().addingTimeInterval(retryAfter ?? 3600)
            throw APIError.rateLimited(retryAfter: retryAfter)
        } catch let error as APIError where Self.isPermanentRejection(error) {
            // The server refused this upload for good: never resend it.
            try discard(upload, from: store)
            throw error
        }
        // The keys are this account's even if its session ended meanwhile; only
        // a deleted or signed-out (erased) account's must not come back.
        guard !wipedUsers.contains(account.userID), !account.store.isRevoked else { return }
        try commit(upload, to: store)
    }

    /// A 4xx other than 429: re-sending the same body can't succeed.
    private static func isPermanentRejection(_ error: APIError) -> Bool {
        switch error {
        case .server(let status, _): (400..<500).contains(status) && status != 429
        case .e2e(let code, _): code != E2EErrorCode.disabled
        default: false
        }
    }

    private func hasAllKeys(of upload: E2EPendingRegistration, in store: E2EProtocolStore) throws -> Bool {
        let registration = upload.registration
        guard (try? store.loadSignedPreKey(id: registration.signedPreKey.keyID, context: NullContext())) != nil else { return false }
        for key in registration.preKeys where (try? store.loadPreKey(id: key.keyID, context: NullContext())) == nil { return false }
        for key in registration.pqPreKeys + [registration.pqLastResortPreKey]
        where (try? store.loadKyberPreKey(id: key.keyID, context: NullContext())) == nil { return false }
        return true
    }

    /// Forgets a saved registration the server doesn't have, with its keys.
    private func discard(_ upload: E2EPendingRegistration, from store: E2EProtocolStore) throws {
        let registration = upload.registration
        let state = store.state
        if registration.signedPreKey.keyID != state.currentSignedPreKeyID,
           state.replacedSignedPreKeys[registration.signedPreKey.keyID] == nil {
            try store.removeSignedPreKey(id: registration.signedPreKey.keyID)
        }
        if registration.pqLastResortPreKey.keyID != state.currentLastResortKyberID,
           state.replacedLastResortKyber[registration.pqLastResortPreKey.keyID] == nil {
            try store.removeKyberPreKey(id: registration.pqLastResortPreKey.keyID)
        }
        for key in registration.preKeys where state.oneTimePreKeys[key.keyID] == upload.epoch && upload.epoch > state.epoch {
            try store.removePreKey(id: key.keyID, context: NullContext())
        }
        for key in registration.pqPreKeys where state.oneTimeKyberPreKeys[key.keyID] == upload.epoch && upload.epoch > state.epoch {
            try store.removeKyberPreKey(id: key.keyID)
        }
        try store.setPendingRegistration(nil)
    }

    private func commit(_ upload: E2EPendingRegistration, to store: E2EProtocolStore) throws {
        let date = now()
        let signedID = upload.registration.signedPreKey.keyID
        let lastResortID = upload.registration.pqLastResortPreKey.keyID
        try store.updateState { state in
            if let old = state.currentSignedPreKeyID, old != signedID { state.replacedSignedPreKeys[old] = date }
            if let old = state.currentLastResortKyberID, old != lastResortID { state.replacedLastResortKyber[old] = date }
            state.currentSignedPreKeyID = signedID
            state.currentLastResortKyberID = lastResortID
            if upload.epoch > state.epoch {
                state.epochReplacedAt[state.epoch] = date
                state.epoch = upload.epoch
            }
            state.registeredIdentityKey = upload.registration.identityKey
        }
        try store.setPendingRegistration(nil)
    }

    private func commit(_ rotation: SignedPreKeyRotation, to store: E2EProtocolStore) throws {
        let date = now()
        try store.updateState { state in
            if let signed = rotation.signedPreKey {
                if let old = state.currentSignedPreKeyID, old != signed.keyID { state.replacedSignedPreKeys[old] = date }
                state.currentSignedPreKeyID = signed.keyID
            }
            if let lastResort = rotation.pqLastResortPreKey {
                if let old = state.currentLastResortKyberID, old != lastResort.keyID { state.replacedLastResortKyber[old] = date }
                state.currentLastResortKyberID = lastResort.keyID
            }
        }
        try store.setPendingRotation(nil)
    }

    /// Commits a saved registration or rotation the server already shows.
    private func reconcileUploads(_ account: Account, status: KeyStatus) throws {
        let store = account.store
        if let pending = try store.pendingRegistration(),
           status.registered,
           status.identityKey == pending.registration.identityKey,
           status.signedPreKeyID == pending.registration.signedPreKey.keyID,
           status.pqLastResortPreKeyID == pending.registration.pqLastResortPreKey.keyID {
            try commit(pending, to: store)
        }
        if let rotation = try store.pendingRotation(),
           rotation.signedPreKey.map({ $0.keyID == status.signedPreKeyID }) ?? true,
           rotation.pqLastResortPreKey.map({ $0.keyID == status.pqLastResortPreKeyID }) ?? true {
            try commit(rotation, to: store)
        }
    }

    /// `POST /keys/prekeys` when a count is under its watermark, back up to the maximum.
    private func replenish(_ account: Account, config: E2EConfig, status: KeyStatus) async throws {
        let store = account.store
        let epoch = store.state.epoch
        var upload = PreKeyReplenishment()
        if status.preKeyCount < config.preKeyLowWatermark, config.maxPreKeys > status.preKeyCount {
            upload.preKeys = try makePreKeys(store, count: config.maxPreKeys - status.preKeyCount, epoch: epoch)
        }
        if status.pqPreKeyCount < config.pqPreKeyLowWatermark, config.maxPqPreKeys > status.pqPreKeyCount {
            upload.pqPreKeys = try makeKyberPreKeys(store, count: config.maxPqPreKeys - status.pqPreKeyCount, lastResort: false, epoch: epoch)
        }
        guard upload.preKeys != nil || upload.pqPreKeys != nil else { return }
        do {
            _ = try await api.uploadPreKeys(upload)
        } catch APIError.e2e(let code, _) where code == E2EErrorCode.keysNotRegistered {
            guard isCurrent(account) else { return }
            try await register(account, config: config)
        } catch APIError.e2e(let code, _) where code == E2EErrorCode.prekeyLimit {
            // Someone else topped up meanwhile; the next sync re-reads the counts.
        }
    }

    /// `PUT /keys/signed` about weekly; the replaced keys stay usable for a
    /// while. Like registration, a failed upload is re-sent as is.
    private func rotateIfDue(_ account: Account, status: KeyStatus) async throws {
        let date = now()
        func due(_ updatedAt: Date?) -> Bool {
            guard let updatedAt else { return true }
            return date.timeIntervalSince(updatedAt) >= E2EKeyPolicy.rotationInterval
        }
        let store = account.store
        let rotation: SignedPreKeyRotation
        if let pending = try store.pendingRotation() {
            rotation = pending
        } else {
            let rotateSigned = due(status.signedPreKeyUpdatedAt)
            let rotateKyber = due(status.pqLastResortPreKeyUpdatedAt)
            guard rotateSigned || rotateKyber else { return }
            rotation = SignedPreKeyRotation(
                signedPreKey: rotateSigned ? try makeSignedPreKey(store) : nil,
                pqLastResortPreKey: rotateKyber ? try makeKyberPreKeys(store, count: 1, lastResort: true, epoch: store.state.epoch)[0] : nil
            )
            try store.setPendingRotation(rotation)
        }
        _ = try await api.rotateSignedPreKeys(rotation)
        guard !wipedUsers.contains(account.userID), !account.store.isRevoked else { return }
        try commit(rotation, to: store)
    }

    /// Drops replaced signed / last-resort keys and old one-time key batches
    /// once they've been replaced for `keepReplacedKeys`.
    private func prune(_ account: Account) throws {
        let store = account.store
        let cutoff = now().addingTimeInterval(-E2EKeyPolicy.keepReplacedKeys)
        let state = store.state
        var protectedSigned: Set<UInt32> = []
        var protectedKyber: Set<UInt32> = []
        // Keys of an upload that may still land are never dropped here.
        if let rotation = try store.pendingRotation() {
            if let id = rotation.signedPreKey?.keyID { protectedSigned.insert(id) }
            if let id = rotation.pqLastResortPreKey?.keyID { protectedKyber.insert(id) }
        }
        if let pending = try store.pendingRegistration() {
            protectedSigned.insert(pending.registration.signedPreKey.keyID)
            protectedKyber.insert(pending.registration.pqLastResortPreKey.keyID)
        }
        for (id, replacedAt) in state.replacedSignedPreKeys
        where replacedAt < cutoff && id != state.currentSignedPreKeyID && !protectedSigned.contains(id) {
            try store.removeSignedPreKey(id: id)
            try store.updateState { $0.replacedSignedPreKeys[id] = nil }
        }
        for (id, replacedAt) in state.replacedLastResortKyber
        where replacedAt < cutoff && id != state.currentLastResortKyberID && !protectedKyber.contains(id) {
            try store.removeKyberPreKey(id: id)
            try store.updateState { $0.replacedLastResortKyber[id] = nil }
        }
        let oldEpochs = Set(state.epochReplacedAt.filter { $0.value < cutoff && $0.key < state.epoch }.map(\.key))
        guard !oldEpochs.isEmpty else { return }
        for (id, epoch) in state.oneTimePreKeys where oldEpochs.contains(epoch) {
            try store.removePreKey(id: id, context: NullContext())
        }
        for (id, epoch) in state.oneTimeKyberPreKeys where oldEpochs.contains(epoch) {
            try store.removeKyberPreKey(id: id)
        }
        try store.updateState { state in
            for epoch in oldEpochs { state.epochReplacedAt[epoch] = nil }
        }
    }

    // MARK: Key generation

    private func timestamp() -> UInt64 { UInt64(max(0, now().timeIntervalSince1970) * 1000) }

    private func makeSignedPreKey(_ store: E2EProtocolStore) throws -> SignedPreKeyUpload {
        var id = store.state.nextSignedPreKeyID
        let taken = Set(store.state.replacedSignedPreKeys.keys).union(store.state.currentSignedPreKeyID.map { [$0] } ?? [])
        while taken.contains(id) { id = E2EKeyPolicy.next(after: id) }
        let privateKey = PrivateKey.generate()
        let publicKey = privateKey.publicKey.serialize()
        let signature = store.identityKeyPair.privateKey.generateSignature(message: publicKey)
        let record = try SignedPreKeyRecord(id: id, timestamp: timestamp(), privateKey: privateKey, signature: signature)
        try store.storeSignedPreKey(record, id: id, context: NullContext())
        try store.updateState { $0.nextSignedPreKeyID = E2EKeyPolicy.next(after: id) }
        return SignedPreKeyUpload(keyID: id, publicKey: publicKey.base64EncodedString(), signature: signature.base64EncodedString())
    }

    private func makePreKeys(_ store: E2EProtocolStore, count: Int, epoch: Int) throws -> [PreKeyUpload] {
        guard count > 0 else { return [] }
        var id = store.state.nextPreKeyID
        var created: [UInt32: Int] = [:]
        var uploads: [PreKeyUpload] = []
        for _ in 0..<count {
            while store.state.oneTimePreKeys[id] != nil || created[id] != nil { id = E2EKeyPolicy.next(after: id) }
            let privateKey = PrivateKey.generate()
            try store.storePreKey(try PreKeyRecord(id: id, privateKey: privateKey), id: id, context: NullContext())
            uploads.append(PreKeyUpload(keyID: id, publicKey: privateKey.publicKey.serialize().base64EncodedString()))
            created[id] = epoch
            id = E2EKeyPolicy.next(after: id)
        }
        let next = id
        try store.updateState { state in
            state.oneTimePreKeys.merge(created) { _, new in new }
            state.nextPreKeyID = next
        }
        return uploads
    }

    private func makeKyberPreKeys(_ store: E2EProtocolStore, count: Int, lastResort: Bool, epoch: Int) throws -> [SignedPreKeyUpload] {
        guard count > 0 else { return [] }
        var id = store.state.nextKyberPreKeyID
        var created: [UInt32] = []
        var uploads: [SignedPreKeyUpload] = []
        func taken(_ id: UInt32) -> Bool {
            store.state.oneTimeKyberPreKeys[id] != nil || store.state.lastResortKyberIDs.contains(id) || created.contains(id)
        }
        for _ in 0..<count {
            while taken(id) { id = E2EKeyPolicy.next(after: id) }
            let keyPair = KEMKeyPair.generate()
            let publicKey = keyPair.publicKey.serialize()
            let signature = store.identityKeyPair.privateKey.generateSignature(message: publicKey)
            let record = try KyberPreKeyRecord(id: id, timestamp: timestamp(), keyPair: keyPair, signature: signature)
            try store.storeKyberPreKey(record, id: id, context: NullContext())
            uploads.append(SignedPreKeyUpload(keyID: id, publicKey: publicKey.base64EncodedString(), signature: signature.base64EncodedString()))
            created.append(id)
            id = E2EKeyPolicy.next(after: id)
        }
        let next = id
        try store.updateState { state in
            for created in created {
                if lastResort { state.lastResortKyberIDs.insert(created) } else { state.oneTimeKyberPreKeys[created] = epoch }
            }
            state.nextKyberPreKeyID = next
        }
        return uploads
    }

    // MARK: Sending

    private func address(_ peer: Profile.ID) throws -> ProtocolAddress {
        try ProtocolAddress(name: peer, deviceId: Self.deviceID)
    }

    /// Decides how `text` goes to `peer` and, for an envelope, encrypts it
    /// (`route`, then `seal`). Text messages only; photos go through
    /// `E2EAPIClient.sendPhoto`.
    func prepareOutgoing(text: String, to peer: Profile.ID, conversationID: Conversation.ID, clientID: String) async throws -> E2EOutgoing {
        switch try await route(text: text, to: peer, conversationID: conversationID) {
        case .plaintext:
            return .plaintext
        case .encrypt:
            return .envelope(try await seal(E2EPayload(text: text), to: peer, conversationID: conversationID, clientID: clientID))
        }
    }

    /// Decides how a message to `peer` goes out, without encrypting anything:
    ///
    /// - `off`: plaintext.
    /// - `optional`: encrypt if there is a session or the recipient has keys
    ///   (setting up the session from their bundle); plaintext if the server
    ///   says `keys_unavailable` / `e2e_disabled`.
    /// - `required`: encrypt or an error, never plaintext.
    ///
    /// Runs the text rules on `text` (if any) and refuses while `peer`'s key
    /// change is pending. Never falls back to plaintext because of a key
    /// change or a broken bundle: that would let a server quietly downgrade a
    /// chat.
    func route(text: String?, to peer: Profile.ID, conversationID: Conversation.ID) async throws -> E2ERoute {
        let config = try await currentConfig()
        guard config.mode != .off else { return .plaintext }
        let account = try await requireAccount()
        if let text, !text.isEmpty {
            try E2EContentRules.check(
                text,
                conversationID: conversationID,
                rules: config.contentRules,
                recentSends: account.history.recentSends,
                now: now()
            )
        }
        let store = account.store
        if try store.pendingIdentity(of: peer) != nil {
            await publish()
            throw E2EError.identityChanged(peer: peer)
        }
        let address = try address(peer)
        if !(try store.hasActiveSession(with: address)) {
            do {
                try await setUpSession(with: peer, account: account)
            } catch APIError.e2e(let code, _) where code == E2EErrorCode.keysUnavailable {
                if config.mode == .required { throw E2EError.recipientHasNoKeys }
                return .plaintext
            } catch APIError.e2e(let code, _) where code == E2EErrorCode.disabled {
                // The server switched E2E off after the config was read.
                let fresh = try? await currentConfig(refresh: true)
                if fresh?.mode == .required { throw E2EError.encryptionFailed }
                return .plaintext
            }
            guard isCurrent(account) else { throw E2EError.notSignedIn }
            // A key change found while fetching the bundle.
            if try store.pendingIdentity(of: peer) != nil { throw E2EError.identityChanged(peer: peer) }
        }
        return .encrypt
    }

    /// Encrypts `payload` for `peer` with the session `route` set up, and
    /// keeps the sent text and photo pointer by `clientID` (the sender can't
    /// decrypt its own envelope).
    ///
    /// - Parameters:
    ///   - expiresAfterSeconds: The message's timer, if any: a photo key is
    ///     then dropped once the server must have deleted the photo, even if
    ///     this device never learns when it was read.
    ///   - isViewOnce: A view-once photo (the key is dropped after the
    ///     server's cap for unopened ones).
    func seal(
        _ payload: E2EPayload,
        to peer: Profile.ID,
        conversationID: Conversation.ID,
        clientID: String,
        expiresAfterSeconds: Int? = nil,
        isViewOnce: Bool = false
    ) async throws -> MessageEnvelope {
        let config = try await currentConfig()
        let account = try await requireAccount()
        let store = account.store
        if try store.pendingIdentity(of: peer) != nil {
            await publish()
            throw E2EError.identityChanged(peer: peer)
        }
        let address = try address(peer)
        let plaintext = try JSONEncoder().encode(payload)
        let ciphertext: CiphertextMessage
        do {
            ciphertext = try signalEncrypt(
                message: plaintext,
                for: address,
                localAddress: store.localAddress,
                sessionStore: store,
                identityStore: store,
                now: now(),
                context: NullContext()
            )
        } catch SignalError.untrustedIdentity {
            await publish()
            throw E2EError.identityChanged(peer: peer)
        } catch {
            throw E2EError.encryptionFailed
        }
        let kind: MessageEnvelope.Kind
        switch ciphertext.messageType {
        case .preKey: kind = .prekey
        case .whisper: kind = .signal
        default: throw E2EError.encryptionFailed
        }
        let body = ciphertext.serialize()
        guard body.count <= config.envelopeMaxBytes else { throw E2EError.messageTooLong }

        // Kept before the request goes out: the server's websocket echo can
        // arrive before the response.
        let date = now()
        var keyUntil: Date?
        if let seconds = expiresAfterSeconds {
            // The server deletes an expiring message at most 14 days after
            // it was sent plus its timer, read or not.
            keyUntil = date.addingTimeInterval(E2EHistory.serverPhotoCap + TimeInterval(seconds))
        } else if isViewOnce {
            keyUntil = date.addingTimeInterval(E2EHistory.serverPhotoCap + E2EHistory.attachmentKeyMargin)
        }
        account.history.sent[clientID] = E2EHistory.Entry(
            conversationID: conversationID,
            text: payload.text,
            storedAt: date,
            attachment: payload.attachment,
            attachmentKeyUntil: keyUntil
        )
        account.historyDirty = true
        flushHistory(account)
        encryptedPeers.insert(peer)
        await publish()
        return MessageEnvelope(type: kind, body: body.base64EncodedString())
    }

    /// The encrypted blob and pointer for the photo sent as `clientID`:
    /// the same ones on every retry of that send, a fresh key otherwise.
    func encryptedPhoto(_ jpeg: Data, clientID: String) throws -> (blob: Data, pointer: E2EAttachmentPointer) {
        if let cached = outgoingMedia[clientID] { return cached }
        let size = E2EMediaCrypto.pixelSize(of: jpeg)
        let encrypted = try E2EMediaCrypto.encrypt(jpeg: jpeg, width: size?.width, height: size?.height)
        outgoingMedia[clientID] = encrypted
        return encrypted
    }

    /// The photo sent as `clientID` reached the server: forget its blob.
    func didSendPhoto(clientID: String) {
        outgoingMedia[clientID] = nil
    }

    /// The server accepted `message` (plaintext or envelope) whose text was
    /// `text`: remember it for the duplicate rule and, for an envelope, show
    /// the plaintext.
    func didSend(_ message: Message, text: String?) async -> Message {
        guard let account = try? await loadAccount(create: false), account.userID == message.senderID else { return message }
        if let text, !text.isEmpty {
            account.history.recentSends.append(E2EHistory.Send(
                conversationID: message.conversationID,
                normalized: E2EContentRules.normalizeForDuplicate(text),
                sentAt: now()
            ))
            account.historyDirty = true
        }
        var dropped: [Message.ID] = []
        let revealed = reveal(message, in: account, dropped: &dropped)
        flushHistory(account)
        if !dropped.isEmpty { await evictMedia(dropped) }
        return revealed
    }

    /// Single flight per person: concurrent first messages share one bundle
    /// fetch (each fetch uses up one of their one-time prekeys).
    private func setUpSession(with peer: Profile.ID, account: Account) async throws {
        if let running = sessionSetups[peer] {
            try await running.value
            return
        }
        let task = Task { try await self.fetchBundleAndStartSession(with: peer, account: account) }
        sessionSetups[peer] = task
        defer { sessionSetups[peer] = nil }
        try await task.value
    }

    /// PQXDH: verifies the bundle (libsignal checks both prekey signatures)
    /// and creates the session.
    private func fetchBundleAndStartSession(with peer: Profile.ID, account: Account) async throws {
        let bundle = try await api.preKeyBundle(for: peer)
        guard isCurrent(account) else { throw E2EError.notSignedIn }
        guard let device = bundle.devices.first(where: { $0.deviceID == Self.deviceID }) else { throw E2EError.encryptionFailed }
        let store = account.store
        do {
            let identity = try IdentityKey(bytes: try Self.decode(bundle.identityKey))
            if let trusted = try store.trustedIdentity(of: peer), trusted != identity {
                try store.recordPendingIdentity(identity, for: peer, now: now())
                await publish()
                throw E2EError.identityChanged(peer: peer)
            }
            let signedPreKey = try PublicKey(try Self.decode(device.signedPreKey.publicKey))
            let signedSignature = try Self.decode(device.signedPreKey.signature)
            let kyberKey = try KEMPublicKey(try Self.decode(device.pqPreKey.publicKey))
            let kyberSignature = try Self.decode(device.pqPreKey.signature)
            let preKeyBundle: PreKeyBundle
            if let preKey = device.preKey {
                preKeyBundle = try PreKeyBundle(
                    registrationId: device.registrationID,
                    deviceId: device.deviceID,
                    prekeyId: preKey.keyID,
                    prekey: try PublicKey(try Self.decode(preKey.publicKey)),
                    signedPrekeyId: device.signedPreKey.keyID,
                    signedPrekey: signedPreKey,
                    signedPrekeySignature: signedSignature,
                    identity: identity,
                    kyberPrekeyId: device.pqPreKey.keyID,
                    kyberPrekey: kyberKey,
                    kyberPrekeySignature: kyberSignature
                )
            } else {
                preKeyBundle = try PreKeyBundle(
                    registrationId: device.registrationID,
                    deviceId: device.deviceID,
                    signedPrekeyId: device.signedPreKey.keyID,
                    signedPrekey: signedPreKey,
                    signedPrekeySignature: signedSignature,
                    identity: identity,
                    kyberPrekeyId: device.pqPreKey.keyID,
                    kyberPrekey: kyberKey,
                    kyberPrekeySignature: kyberSignature
                )
            }
            try processPreKeyBundle(
                preKeyBundle,
                for: try address(peer),
                ourAddress: store.localAddress,
                sessionStore: store,
                identityStore: store,
                now: now(),
                context: NullContext()
            )
        } catch let error as E2EError {
            throw error
        } catch SignalError.untrustedIdentity {
            await publish()
            throw E2EError.identityChanged(peer: peer)
        } catch {
            // A bad signature or malformed key: never use this bundle.
            throw E2EError.encryptionFailed
        }
    }

    private static func decode(_ base64: String) throws -> Data {
        guard let data = Data(base64Encoded: base64) else { throw E2EError.encryptionFailed }
        return data
    }

    // MARK: Receiving

    /// Fills in `text` (and `encryption`) for every message with an envelope:
    /// from the local history if it was decrypted or sent here before,
    /// otherwise by decrypting it now (once).
    func reveal(_ messages: [Message]) async -> [Message] {
        guard messages.contains(where: { $0.envelope != nil }) else { return messages }
        guard let account = try? await loadAccount(create: false) else {
            return messages.map { message in
                guard message.envelope != nil else { return message }
                var copy = message
                copy.encryption = .unavailable
                return copy
            }
        }
        // Keys that expired while the app was running go before anything is shown.
        var dropped: [Message.ID] = []
        if historyPrunedAt.map({ now().timeIntervalSince($0) >= Self.historyPruneInterval }) ?? true {
            dropped = pruneHistory(of: account)
        }
        let revealed = messages.map { reveal($0, in: account, dropped: &dropped) }
        flushHistory(account)
        if !dropped.isEmpty { await evictMedia(dropped) }
        await publish()
        // A message under an unknown key: check it against the published key
        // (in the background, at most once a minute per person).
        for peer in Set(revealed.filter { $0.encryption == .awaitingKeyConfirmation }.map(\.senderID)) {
            Task { await self.checkIdentity(of: peer, maxAge: 60) }
        }
        return revealed
    }

    func reveal(_ message: Message) async -> Message {
        await reveal([message])[0]
    }

    /// Decrypts message and conversation events from the websocket.
    func reveal(_ event: RealtimeEvent) async -> RealtimeEvent {
        switch event {
        case .messageCreated(let message):
            return .messageCreated(await reveal(message))
        case .messageUpdated(let message):
            return .messageUpdated(await reveal(message))
        case .conversationUpdated(var conversation):
            if let last = conversation.lastMessage { conversation.lastMessage = await reveal(last) }
            return .conversationUpdated(conversation)
        default:
            return event
        }
    }

    func reveal(_ conversations: [Conversation]) async -> [Conversation] {
        let lasts = await reveal(conversations.compactMap(\.lastMessage))
        var byID: [Message.ID: Message] = [:]
        for message in lasts { byID[message.id] = message }
        return conversations.map { conversation in
            var copy = conversation
            if let id = conversation.lastMessage?.id { copy.lastMessage = byID[id] ?? conversation.lastMessage }
            return copy
        }
    }

    /// Synchronous on purpose: the history lookup, the decrypt and storing
    /// the plaintext happen without a suspension point, so the same message
    /// arriving twice at once (REST and websocket) is decrypted only once.
    /// Appends to `dropped` the messages whose photo key went here.
    private func reveal(_ message: Message, in account: Account, dropped: inout [Message.ID]) -> Message {
        guard let envelope = message.envelope else { return message }
        var revealed = message
        if var entry = account.history.messages[message.id] {
            let before = entry
            // The server's `expiresAt` wins over one stamped here (`didMarkRead`);
            // a copy without one (fetched before the read) never clears it.
            if let expiresAt = message.expiresAt { entry.expiresAt = expiresAt }
            // Expired since the last prune: the server has deleted the photo.
            let date = now()
            if let expiresAt = entry.expiresAt, expiresAt <= date {
                entry.dropAttachment()
            } else {
                entry.pruneAttachment(now: date)
            }
            if before.attachment != nil && entry.attachment == nil { dropped.append(message.id) }
            if entry != before {
                account.history.messages[message.id] = entry
                account.historyDirty = true
            }
            Self.apply(entry, to: &revealed)
            return revealed
        }

        if message.senderID == account.userID {
            // The sender can't decrypt its own envelope: only the local copy works.
            if let clientID = message.clientID, var entry = account.history.sent[clientID] {
                entry.expiresAt = message.expiresAt
                account.history.messages[message.id] = entry
                account.history.sent[clientID] = nil
                account.historyDirty = true
                Self.apply(entry, to: &revealed)
            } else {
                revealed.encryption = .unavailable
            }
            return revealed
        }

        let store = account.store
        guard let body = Data(base64Encoded: envelope.body),
              let sender = try? address(message.senderID)
        else {
            revealed.encryption = .unavailable
            return revealed
        }
        do {
            let plaintext: Data
            switch envelope.type {
            case .prekey:
                plaintext = try signalDecryptPreKey(
                    message: try PreKeySignalMessage(bytes: body),
                    from: sender,
                    localAddress: store.localAddress,
                    sessionStore: store,
                    identityStore: store,
                    preKeyStore: store,
                    signedPreKeyStore: store,
                    kyberPreKeyStore: store,
                    context: NullContext()
                )
            case .signal:
                plaintext = try signalDecrypt(
                    message: try SignalMessage(bytes: body),
                    from: sender,
                    to: store.localAddress,
                    sessionStore: store,
                    identityStore: store,
                    context: NullContext()
                )
            }
            let payload = try? JSONDecoder().decode(E2EPayload.self, from: plaintext)
            let date = now()
            let timer = payload?.timer
            var keyUntil: Date?
            if let timer {
                // Like the sender's: the server deletes an expiring photo at
                // most 14 days after it was sent plus its timer, read or not,
                // even if this device never learns its `expiresAt`.
                keyUntil = date.addingTimeInterval(E2EHistory.serverPhotoCap + TimeInterval(timer) + E2EHistory.attachmentKeyMargin)
            } else if message.attachment?.isViewOnce == true {
                // An unopened view-once photo is deleted by the server after
                // its cap; this device may never load the thread again.
                keyUntil = date.addingTimeInterval(E2EHistory.serverPhotoCap + E2EHistory.attachmentKeyMargin)
            }
            let entry = E2EHistory.Entry(
                conversationID: message.conversationID,
                text: payload?.text,
                storedAt: date,
                expiresAt: message.expiresAt,
                attachment: payload?.attachment,
                attachmentKeyUntil: keyUntil,
                expiresAfterSeconds: timer
            )
            account.history.messages[message.id] = entry
            account.historyDirty = true
            encryptedPeers.insert(message.senderID)
            Self.apply(entry, to: &revealed)
        } catch SignalError.untrustedIdentity {
            // Recorded as pending by the store; decrypted once the user accepts.
            revealed.encryption = .awaitingKeyConfirmation
        } catch {
            // Already decrypted before this install, keys gone, or garbage.
            revealed.encryption = .unavailable
        }
        return revealed
    }

    /// Fills in what the history knows about a message: its text, and the
    /// photo key if it still has one.
    private static func apply(_ entry: E2EHistory.Entry, to message: inout Message) {
        message.text = entry.text
        message.e2eAttachment = nil
        message.e2eAttachmentRemoval = nil
        if let pointer = entry.attachment {
            if pointer.isSupported {
                message.e2eAttachment = pointer
                message.encryption = .decrypted
            } else {
                // A photo from a newer version of the app.
                message.encryption = .unsupported
            }
        } else if entry.hadAttachment == true {
            message.e2eAttachmentRemoval = entry.viewOnceOpenedAt != nil ? .opened : .gone
            message.encryption = .decrypted
        } else {
            // No pointer: an encrypted photo's tile then says it isn't
            // available on this phone (never "needs a newer version").
            message.encryption = entry.text == nil && message.attachment == nil ? .unsupported : .decrypted
        }
    }

    /// The user closed a view-once photo: drop its key and remember it was
    /// opened here, so the bubble shows "Opened".
    func forgetAttachmentKey(messageID: Message.ID) async {
        guard let account = try? await loadAccount(create: false),
              var entry = account.history.messages[messageID]
        else { return }
        entry.dropAttachment(openedAt: now())
        account.history.messages[messageID] = entry
        account.historyDirty = true
        flushHistory(account)
        await evictMedia([messageID])
    }

    /// The server no longer has these photos (`url: null` in `GET …/messages`:
    /// spent or expired): drop their keys.
    func attachmentsGone(messageIDs: [Message.ID]) async {
        guard !messageIDs.isEmpty, let account = try? await loadAccount(create: false) else { return }
        for id in messageIDs {
            guard var entry = account.history.messages[id], entry.attachment != nil else { continue }
            entry.dropAttachment()
            account.history.messages[id] = entry
            account.historyDirty = true
        }
        flushHistory(account)
        await evictMedia(messageIDs)
    }

    /// The conversation was deleted (for this user): forget its plaintext
    /// and its decrypted photos.
    func forgetConversation(_ conversationID: Conversation.ID) async {
        guard let account = try? await loadAccount(create: false) else { return }
        let forgotten = account.history.messages.filter { $0.value.conversationID == conversationID }.keys.sorted()
        account.history.messages = account.history.messages.filter { $0.value.conversationID != conversationID }
        account.history.sent = account.history.sent.filter { $0.value.conversationID != conversationID }
        account.historyDirty = true
        flushHistory(account)
        if !forgotten.isEmpty { await evictMedia(forgotten) }
    }

    /// The user read `conversationID` (`POST …/read`): the server starts the
    /// timers of the messages they received now. Received entries whose
    /// timer came in the envelope (`E2EPayload.expiresAfterSeconds`) get
    /// their `expiresAt` here, so they're pruned on time even if this device
    /// doesn't see the server's `expiresAt` again. Only entries stored before
    /// `requestedAt` (from `markReadRequested()`, taken before the request):
    /// a message that arrived while the request was in flight may be unread
    /// on the server, and stamping it would delete its only decrypted copy
    /// while the server still holds it.
    /// The engine's clock, read just before `POST …/read` (see `didMarkRead`).
    func markReadRequested() -> Date { now() }

    func didMarkRead(conversationID: Conversation.ID, requestedAt: Date) async {
        guard let account = try? await loadAccount(create: false) else { return }
        let date = now()
        for (id, entry) in account.history.messages
        where entry.conversationID == conversationID && entry.expiresAt == nil && entry.storedAt <= requestedAt {
            // Only received entries carry the timer.
            guard let seconds = entry.expiresAfterSeconds else { continue }
            account.history.messages[id]?.expiresAt = date.addingTimeInterval(TimeInterval(seconds))
            account.historyDirty = true
        }
        flushHistory(account)
    }

    // MARK: Identity changes

    /// `identity.changed`, a thread opening, or a held message: compares
    /// `peer`'s published identity key with the trusted one. A different key
    /// is held for the user (replacing any pending one, so the pending key is
    /// always the one the server publishes); a matching one clears a pending
    /// change that the server doesn't back (a stale or forged message).
    /// Only for people this device already trusts a key for. Skipped if the
    /// last check was less than `maxAge` ago.
    func checkIdentity(of peer: Profile.ID, maxAge: TimeInterval) async {
        var mode = config?.mode
        if mode == nil { mode = try? await currentConfig().mode }
        guard let mode, mode != .off else { return }
        guard let account = try? await loadAccount(create: false),
              (try? account.store.trustedIdentity(of: peer)) != nil
        else { return }
        let date = now()
        if let last = identityCheckedAt[peer], date.timeIntervalSince(last) < maxAge { return }
        identityCheckedAt[peer] = date
        guard let response = try? await api.identityKey(for: peer),
              let data = Data(base64Encoded: response.identityKey),
              let current = try? IdentityKey(bytes: data),
              isCurrent(account),
              // Re-read after the await: the user may have accepted meanwhile.
              let trusted = try? account.store.trustedIdentity(of: peer)
        else { return }
        if current != trusted {
            try? account.store.recordPendingIdentity(current, for: peer, now: date)
        } else if let pending = try? account.store.pendingIdentity(of: peer),
                  // Not a newer hold recorded while this request was out.
                  pending.detectedAt <= date {
            // The server still publishes the trusted key: the pending one is
            // stale or forged. Dismiss it so it can't come back.
            if let data = Data(base64Encoded: pending.identityKey), let key = try? IdentityKey(bytes: data) {
                try? account.store.dismissIdentity(key, of: peer)
            }
            try? account.store.clearPendingIdentity(of: peer)
        }
        await publish()
    }

    /// The user accepted `peer`'s new key: trust it, drop the old session
    /// (the next message starts a new one) and let held messages decrypt.
    func acceptIdentityChange(of peer: Profile.ID) async throws {
        guard let account = try await loadAccount(create: false),
              let pending = try account.store.pendingIdentity(of: peer)
        else { return }
        let identity = try IdentityKey(bytes: try Self.decode(pending.identityKey))
        try account.store.setTrustedIdentity(identity, of: peer)
        try account.store.deleteSession(for: try address(peer))
        try account.store.clearPendingIdentity(of: peer)
        identityCheckedAt[peer] = nil
        encryptedPeers.remove(peer)
        await publish()
    }

    /// Thread opened: report whether there's a session, and re-check the key
    /// (always while a change is pending, so a hold the server doesn't back
    /// clears itself).
    func threadOpened(with peer: Profile.ID) async {
        var hasPending = false
        if let account = try? await loadAccount(create: false) {
            if let address = try? address(peer), (try? account.store.hasActiveSession(with: address)) == true {
                encryptedPeers.insert(peer)
            }
            hasPending = (try? account.store.pendingIdentity(of: peer)) != nil
        }
        await publish()
        await checkIdentity(of: peer, maxAge: hasPending ? 0 : Self.identityCheckInterval)
    }

    // MARK: Status

    func snapshot() async -> E2ESnapshot {
        var snapshot = E2ESnapshot(mode: config?.mode ?? .off, encryptedPeers: encryptedPeers)
        if let account, let pending = try? account.store.allPendingIdentities() {
            snapshot.keyChanges = pending.mapValues(\.detectedAt)
        }
        return snapshot
    }

    private func publish() async {
        guard let onSnapshot else { return }
        let next = await snapshot()
        guard next != lastSnapshot else { return }
        lastSnapshot = next
        await onSnapshot(next)
    }
}
