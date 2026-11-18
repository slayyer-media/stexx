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

/// What's inside an envelope: small UTF-8 JSON, with room for media keys
/// later (`docs/api.md`, "Sending encrypted messages"). Unknown fields are
/// ignored.
struct E2EPayload: Codable, Equatable, Sendable {
    var text: String?
}

/// The Signal Protocol client: keys, sessions, encrypt and decrypt, for the
/// signed-in account. One instance for the app; it follows the session
/// (`currentUserID`) and keeps each account's keys apart.
///
/// - Keys: an identity key, registration id, signed prekey, Kyber
///   last-resort key and batches of one-time EC and Kyber prekeys, private
///   parts in the Keychain (`E2EProtocolStore`). `syncKeys()` registers,
///   replenishes and rotates them against `GET /keys/status`.
/// - Sending: `prepareOutgoing` decides plaintext or envelope from
///   `E2E_MODE`, runs the text rules, sets up a session with PQXDH from a
///   prekey bundle if needed and encrypts with the Double Ratchet.
/// - Receiving: `reveal` decrypts envelopes once and keeps the plaintext in
///   the encrypted local history; later copies of the same message (REST,
///   websocket, conversation list) are read from there.
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
    private var sessionSetups: [Profile.ID: Task<Void, any Error>] = [:]
    private var identityCheckedAt: [Profile.ID: Date] = [:]
    private var encryptedPeers: Set<Profile.ID> = []
    private var lastSnapshot = E2ESnapshot()
    private var syncTask: Task<Void, Never>?

    static let deviceID: UInt32 = 1
    /// How long a fetched `E2EConfig` is used before it's re-read.
    static let configLifetime: TimeInterval = 10 * 60
    /// At most one identity re-check per person in this window (thread opens).
    static let identityCheckInterval: TimeInterval = 10 * 60

    /// - Parameters:
    ///   - api: The plain client (not `E2EAPIClient`).
    ///   - currentUserID: The signed-in account, if any.
    init(
        api: any APIClient,
        secrets: any E2ESecretStorage,
        history: any E2EHistoryPersistence,
        currentUserID: @escaping @Sendable () async -> Profile.ID?,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.api = api
        self.secrets = secrets
        self.historyPersistence = history
        self.currentUserID = currentUserID
        self.now = now
    }

    func setSnapshotHandler(_ handler: @escaping @Sendable (E2ESnapshot) async -> Void) {
        onSnapshot = handler
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
        var history = (try? historyPersistence.load(userID: userID)) ?? E2EHistory()
        history.prune(now: now())
        let loaded = Account(userID: userID, store: store, history: history)
        account = loaded
        return loaded
    }

    private func requireAccount() async throws -> Account {
        guard let account = try await loadAccount(create: true) else { throw E2EError.notSignedIn }
        return account
    }

    private func isCurrent(_ candidate: Account) -> Bool { account === candidate }

    private func flushHistory(_ account: Account) {
        guard account.historyDirty else { return }
        do {
            try historyPersistence.save(account.history, userID: account.userID)
            account.historyDirty = false
        } catch {
            // Kept in memory and retried with the next change.
        }
    }

    /// Signed out: drop in-memory state. Keys and history stay on the device
    /// for the next sign-in to this account.
    func signedOut() async {
        if let account { flushHistory(account) }
        account = nil
        config = nil
        configFetchedAt = nil
        encryptedPeers = []
        identityCheckedAt = [:]
        sessionSetups = [:]
        await publish()
    }

    /// The account was deleted: remove its keys, sessions and history.
    func wipe(userID: Profile.ID) async {
        if account?.userID == userID { account = nil }
        try? E2EProtocolStore.wipe(storage: secrets, userID: userID)
        try? historyPersistence.delete(userID: userID)
        encryptedPeers = []
        await publish()
    }

    // MARK: Config

    /// `GET /e2e/config`, cached for `configLifetime`. Falls back to the
    /// cached value when the request fails.
    func currentConfig(refresh: Bool = false) async throws -> E2EConfig {
        if !refresh, let config, let at = configFetchedAt, now().timeIntervalSince(at) < Self.configLifetime {
            return config
        }
        do {
            let fresh = try await api.e2eConfig()
            config = fresh
            configFetchedAt = now()
            await publish()
            return fresh
        } catch {
            if let config { return config }
            throw error
        }
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
        if let syncTask {
            await syncTask.value
            return
        }
        let task = Task { await self.performSync(onlyReplenish: false) }
        syncTask = task
        await task.value
        syncTask = nil
    }

    /// `keys.low`: top up one-time prekeys.
    func replenishKeys() async {
        if let syncTask {
            await syncTask.value
            return
        }
        let task = Task { await self.performSync(onlyReplenish: true) }
        syncTask = task
        await task.value
        syncTask = nil
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
            guard isCurrent(account) else { return }
            if needsRegistration(status, account: account, config: config) {
                try await register(account, config: config)
                return
            }
            try await replenish(account, config: config, status: status)
            if !onlyReplenish {
                try await rotateIfDue(account, status: status)
            }
            if isCurrent(account) { try prune(account) }
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
    /// in a new epoch.
    private func register(_ account: Account, config: E2EConfig) async throws {
        let store = account.store
        let newEpoch = store.state.epoch + 1
        let signed = try makeSignedPreKey(store)
        let lastResort = try makeKyberPreKeys(store, count: 1, lastResort: true, epoch: newEpoch)[0]
        let preKeys = try makePreKeys(store, count: config.maxPreKeys, epoch: newEpoch)
        let pqPreKeys = try makeKyberPreKeys(store, count: config.maxPqPreKeys, lastResort: false, epoch: newEpoch)
        let registration = KeyRegistration(
            registrationID: store.state.registrationID,
            deviceID: Self.deviceID,
            identityKey: store.identityKeyBase64,
            signedPreKey: signed,
            pqLastResortPreKey: lastResort,
            preKeys: preKeys,
            pqPreKeys: pqPreKeys
        )
        // Generated keys stay on failure: if the request did land, the server
        // hands them out. They're in `newEpoch`, which the next attempt reuses.
        _ = try await api.registerKeys(registration)
        guard isCurrent(account) else { return }
        let date = now()
        try store.updateState { state in
            if let old = state.currentSignedPreKeyID, old != signed.keyID { state.replacedSignedPreKeys[old] = date }
            if let old = state.currentLastResortKyberID, old != lastResort.keyID { state.replacedLastResortKyber[old] = date }
            state.currentSignedPreKeyID = signed.keyID
            state.currentLastResortKyberID = lastResort.keyID
            state.epochReplacedAt[state.epoch] = date
            state.epoch = newEpoch
            state.registeredIdentityKey = store.identityKeyBase64
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

    /// `PUT /keys/signed` about weekly; the replaced keys stay usable for a while.
    private func rotateIfDue(_ account: Account, status: KeyStatus) async throws {
        let date = now()
        func due(_ updatedAt: Date?) -> Bool {
            guard let updatedAt else { return true }
            return date.timeIntervalSince(updatedAt) >= E2EKeyPolicy.rotationInterval
        }
        let rotateSigned = due(status.signedPreKeyUpdatedAt)
        let rotateKyber = due(status.pqLastResortPreKeyUpdatedAt)
        guard rotateSigned || rotateKyber else { return }
        let store = account.store
        let signed = rotateSigned ? try makeSignedPreKey(store) : nil
        let lastResort = rotateKyber ? try makeKyberPreKeys(store, count: 1, lastResort: true, epoch: store.state.epoch)[0] : nil
        _ = try await api.rotateSignedPreKeys(SignedPreKeyRotation(signedPreKey: signed, pqLastResortPreKey: lastResort))
        guard isCurrent(account) else { return }
        try store.updateState { state in
            if let signed {
                if let old = state.currentSignedPreKeyID, old != signed.keyID { state.replacedSignedPreKeys[old] = date }
                state.currentSignedPreKeyID = signed.keyID
            }
            if let lastResort {
                if let old = state.currentLastResortKyberID, old != lastResort.keyID { state.replacedLastResortKyber[old] = date }
                state.currentLastResortKyberID = lastResort.keyID
            }
        }
    }

    /// Drops replaced signed / last-resort keys and old one-time key batches
    /// once they've been replaced for `keepReplacedKeys`.
    private func prune(_ account: Account) throws {
        let store = account.store
        let cutoff = now().addingTimeInterval(-E2EKeyPolicy.keepReplacedKeys)
        let state = store.state
        for (id, replacedAt) in state.replacedSignedPreKeys where replacedAt < cutoff && id != state.currentSignedPreKeyID {
            try store.removeSignedPreKey(id: id)
            try store.updateState { $0.replacedSignedPreKeys[id] = nil }
        }
        for (id, replacedAt) in state.replacedLastResortKyber where replacedAt < cutoff && id != state.currentLastResortKyberID {
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

    /// Decides how `text` goes to `peer` and, for an envelope, encrypts it.
    ///
    /// - `off`: plaintext.
    /// - `optional`: an envelope if there is a session or the recipient has
    ///   keys; plaintext if the server says `keys_unavailable` / `e2e_disabled`.
    /// - `required`: an envelope or an error, never plaintext.
    ///
    /// Never falls back to plaintext because of a key change or a broken
    /// bundle: that would let a server quietly downgrade a chat.
    func prepareOutgoing(text: String, to peer: Profile.ID, conversationID: Conversation.ID, clientID: String) async throws -> E2EOutgoing {
        let config = try await currentConfig()
        guard config.mode != .off else { return .plaintext }
        let account = try await requireAccount()
        try E2EContentRules.check(
            text,
            conversationID: conversationID,
            rules: config.contentRules,
            recentSends: account.history.recentSends,
            now: now()
        )
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

        let payload = try JSONEncoder().encode(E2EPayload(text: text))
        let ciphertext: CiphertextMessage
        do {
            ciphertext = try signalEncrypt(
                message: payload,
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
        account.history.sent[clientID] = E2EHistory.Entry(conversationID: conversationID, text: text, storedAt: now())
        account.historyDirty = true
        flushHistory(account)
        encryptedPeers.insert(peer)
        await publish()
        return .envelope(MessageEnvelope(type: kind, body: body.base64EncodedString()))
    }

    /// The server accepted `message` (plaintext or envelope) whose text was
    /// `text`: remember it for the duplicate rule and, for an envelope, show
    /// the plaintext.
    func didSend(_ message: Message, text: String) async -> Message {
        guard let account = try? await loadAccount(create: false), account.userID == message.senderID else { return message }
        account.history.recentSends.append(E2EHistory.Send(
            conversationID: message.conversationID,
            normalized: E2EContentRules.normalizeForDuplicate(text),
            sentAt: now()
        ))
        account.historyDirty = true
        let revealed = reveal(message, in: account)
        flushHistory(account)
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
        let revealed = messages.map { reveal($0, in: account) }
        flushHistory(account)
        await publish()
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
    private func reveal(_ message: Message, in account: Account) -> Message {
        guard let envelope = message.envelope else { return message }
        var revealed = message
        if var entry = account.history.messages[message.id] {
            if entry.expiresAt != message.expiresAt {
                entry.expiresAt = message.expiresAt
                account.history.messages[message.id] = entry
                account.historyDirty = true
            }
            revealed.text = entry.text
            revealed.encryption = entry.text == nil && message.attachment == nil ? .unsupported : .decrypted
            return revealed
        }

        if message.senderID == account.userID {
            // The sender can't decrypt its own envelope: only the local copy works.
            if let clientID = message.clientID, var entry = account.history.sent[clientID] {
                entry.expiresAt = message.expiresAt
                account.history.messages[message.id] = entry
                account.history.sent[clientID] = nil
                account.historyDirty = true
                revealed.text = entry.text
                revealed.encryption = .decrypted
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
            let text = (try? JSONDecoder().decode(E2EPayload.self, from: plaintext))?.text
            account.history.messages[message.id] = E2EHistory.Entry(
                conversationID: message.conversationID,
                text: text,
                storedAt: now(),
                expiresAt: message.expiresAt
            )
            account.historyDirty = true
            encryptedPeers.insert(message.senderID)
            revealed.text = text
            revealed.encryption = text == nil && message.attachment == nil ? .unsupported : .decrypted
        } catch SignalError.untrustedIdentity {
            // Recorded as pending by the store; decrypted once the user accepts.
            revealed.encryption = .awaitingKeyConfirmation
        } catch {
            // Already decrypted before this install, keys gone, or garbage.
            revealed.encryption = .unavailable
        }
        return revealed
    }

    /// The conversation was deleted (for this user): forget its plaintext.
    func forgetConversation(_ conversationID: Conversation.ID) async {
        guard let account = try? await loadAccount(create: false) else { return }
        account.history.messages = account.history.messages.filter { $0.value.conversationID != conversationID }
        account.history.sent = account.history.sent.filter { $0.value.conversationID != conversationID }
        account.historyDirty = true
        flushHistory(account)
    }

    // MARK: Identity changes

    /// `identity.changed`, or a thread opening: compares `peer`'s current
    /// identity key with the trusted one and holds a change for the user.
    /// Only for people this device already trusts a key for.
    func checkIdentity(of peer: Profile.ID, force: Bool) async {
        var mode = config?.mode
        if mode == nil { mode = try? await currentConfig().mode }
        guard let mode, mode != .off else { return }
        guard let account = try? await loadAccount(create: false),
              let trusted = try? account.store.trustedIdentity(of: peer)
        else { return }
        let date = now()
        if !force, let last = identityCheckedAt[peer], date.timeIntervalSince(last) < Self.identityCheckInterval { return }
        identityCheckedAt[peer] = date
        guard let response = try? await api.identityKey(for: peer),
              let data = Data(base64Encoded: response.identityKey),
              let current = try? IdentityKey(bytes: data),
              isCurrent(account)
        else { return }
        if current != trusted {
            try? account.store.recordPendingIdentity(current, for: peer, now: date)
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

    /// Thread opened: report whether there's a session, and re-check the key.
    func threadOpened(with peer: Profile.ID) async {
        if let account = try? await loadAccount(create: false),
           let address = try? address(peer),
           (try? account.store.hasActiveSession(with: address)) == true {
            encryptedPeers.insert(peer)
        }
        await publish()
        await checkIdentity(of: peer, force: false)
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
        let next = await snapshot()
        guard next != lastSnapshot else { return }
        lastSnapshot = next
        await onSnapshot?(next)
    }
}
