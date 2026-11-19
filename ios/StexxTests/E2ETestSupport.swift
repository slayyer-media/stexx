import Foundation
@testable import Stexx

/// A tiny in-memory Stexx server for end-to-end encryption tests: key
/// registration, bundles (consuming one-time keys like the real one), the
/// E2E_MODE rules on sends, and one conversation between two people.
actor FakeE2EServer {
    var mode: E2EConfig.Mode = .optional
    var contentRules = E2EConfig.ContentRules.unrestricted
    var maxPreKeys = 100
    var maxPqPreKeys = 25

    private(set) var registrations: [Profile.ID: KeyRegistration] = [:]
    private(set) var preKeys: [Profile.ID: [PreKeyUpload]] = [:]
    private(set) var pqPreKeys: [Profile.ID: [SignedPreKeyUpload]] = [:]
    private(set) var signedUpdatedAt: [Profile.ID: Date] = [:]
    private(set) var lastResortUpdatedAt: [Profile.ID: Date] = [:]
    private(set) var messages: [Message] = []
    private(set) var calls: [String] = []
    /// Overrides what `GET /keys/status` reports for someone (counts, dates).
    var statusOverride: [Profile.ID: KeyStatus] = [:]
    /// How the next `PUT /keys` fails: before storing anything, or after
    /// storing (the response is lost).
    enum Failure { case beforeApply, afterApply, reject }
    var nextRegisterFailure: Failure?
    /// Every `PUT /keys` body received, including failed ones.
    private(set) var registerAttempts: [KeyRegistration] = []
    private var nextID = 1

    /// Pending chat uploads (`POST /me/attachments`), by ID.
    private(set) var uploads: [Photo.ID: (data: Data, encrypted: Bool)] = [:]
    /// Every upload body received, in order.
    private(set) var uploadLog: [(data: Data, encrypted: Bool)] = []
    /// Files of sent photos, by URL.
    private(set) var media: [URL: Data] = [:]
    /// Makes the next send fail as if the network dropped it (nothing stored).
    var failNextSend = false
    /// Makes the next view-once open fail as if the phone were offline.
    var failNextOpen = false
    /// `GET /e2e/config` fails as if the network dropped it.
    var failConfig = false
    /// Applied right after the next plaintext upload (the server's mode
    /// changing, and its config becoming unreachable, mid-send).
    var afterNextPlaintextUpload: (mode: E2EConfig.Mode, failConfig: Bool)?

    static let conversationID = "c-ab"

    func set(mode: E2EConfig.Mode) { self.mode = mode }
    func set(contentRules: E2EConfig.ContentRules) { self.contentRules = contentRules }
    func set(status: KeyStatus?, for user: Profile.ID) { statusOverride[user] = status }
    func failNextRegister(_ failure: Failure) { nextRegisterFailure = failure }
    func failNextSendOnce() { failNextSend = true }
    func failNextOpenOnce() { failNextOpen = true }
    func set(failConfig: Bool) { self.failConfig = failConfig }
    func afterNextPlaintextUpload(mode: E2EConfig.Mode, failConfig: Bool) { afterNextPlaintextUpload = (mode, failConfig) }
    func count(_ call: String) -> Int { calls.filter { $0 == call }.count }

    var config: E2EConfig {
        E2EConfig(
            mode: mode,
            maxPreKeys: maxPreKeys,
            maxPqPreKeys: maxPqPreKeys,
            preKeyLowWatermark: maxPreKeys / 5,
            pqPreKeyLowWatermark: maxPqPreKeys / 5,
            contentRules: contentRules
        )
    }

    private func disabled() -> APIError { .e2e(code: E2EErrorCode.disabled, message: "off") }

    func e2eConfig(as user: Profile.ID) throws -> E2EConfig {
        calls.append("config")
        if failConfig { throw URLError(.notConnectedToInternet) }
        return config
    }

    func registerKeys(_ registration: KeyRegistration, as user: Profile.ID) throws -> KeyStatus {
        calls.append("register")
        guard mode != .off else { throw disabled() }
        registerAttempts.append(registration)
        let failure = nextRegisterFailure
        nextRegisterFailure = nil
        if failure == .beforeApply { throw URLError(.timedOut) }
        if failure == .reject { throw APIError.server(status: 400, message: "preKeys: at most 50 per upload.") }
        defer { if failure == .afterApply { lostResponse = true } }
        registrations[user] = registration
        preKeys[user] = registration.preKeys
        pqPreKeys[user] = registration.pqPreKeys
        signedUpdatedAt[user] = .now
        lastResortUpdatedAt[user] = .now
        if failure == .afterApply { throw URLError(.networkConnectionLost) }
        return status(of: user)
    }
    private var lostResponse = false

    func keyStatus(as user: Profile.ID) throws -> KeyStatus {
        calls.append("status")
        guard mode != .off else { throw disabled() }
        return statusOverride[user] ?? status(of: user)
    }

    private func status(of user: Profile.ID) -> KeyStatus {
        guard let registration = registrations[user] else {
            return KeyStatus(registered: false, preKeyCount: 0, pqPreKeyCount: 0)
        }
        return KeyStatus(
            registered: true,
            deviceID: 1,
            registrationID: registration.registrationID,
            identityKey: registration.identityKey,
            preKeyCount: preKeys[user]?.count ?? 0,
            pqPreKeyCount: pqPreKeys[user]?.count ?? 0,
            signedPreKeyID: registration.signedPreKey.keyID,
            signedPreKeyUpdatedAt: signedUpdatedAt[user],
            pqLastResortPreKeyID: registration.pqLastResortPreKey.keyID,
            pqLastResortPreKeyUpdatedAt: lastResortUpdatedAt[user]
        )
    }

    func uploadPreKeys(_ upload: PreKeyReplenishment, as user: Profile.ID) throws -> KeyStatus {
        calls.append("prekeys")
        guard mode != .off else { throw disabled() }
        guard registrations[user] != nil else { throw APIError.e2e(code: E2EErrorCode.keysNotRegistered, message: nil) }
        preKeys[user, default: []].append(contentsOf: upload.preKeys ?? [])
        pqPreKeys[user, default: []].append(contentsOf: upload.pqPreKeys ?? [])
        statusOverride[user] = nil
        return status(of: user)
    }

    func rotate(_ rotation: SignedPreKeyRotation, as user: Profile.ID) throws -> KeyStatus {
        calls.append("rotate")
        guard mode != .off, var registration = registrations[user] else { throw disabled() }
        if let signed = rotation.signedPreKey {
            registration.signedPreKey = signed
            signedUpdatedAt[user] = .now
        }
        if let kyber = rotation.pqLastResortPreKey {
            registration.pqLastResortPreKey = kyber
            lastResortUpdatedAt[user] = .now
        }
        registrations[user] = registration
        statusOverride[user] = nil
        return status(of: user)
    }

    func bundle(for target: Profile.ID, as user: Profile.ID) throws -> PreKeyBundleResponse {
        calls.append("bundle")
        guard mode != .off else { throw disabled() }
        guard let registration = registrations[target] else {
            throw APIError.e2e(code: E2EErrorCode.keysUnavailable, message: "no keys")
        }
        let preKey = preKeys[target]?.isEmpty == false ? preKeys[target]!.removeFirst() : nil
        let pqPreKey = pqPreKeys[target]?.isEmpty == false ? pqPreKeys[target]!.removeFirst() : registration.pqLastResortPreKey
        return PreKeyBundleResponse(
            userID: target,
            identityKey: registration.identityKey,
            devices: [.init(
                deviceID: 1,
                registrationID: registration.registrationID,
                signedPreKey: registration.signedPreKey,
                preKey: preKey,
                pqPreKey: pqPreKey
            )]
        )
    }

    func identity(of target: Profile.ID) throws -> IdentityKeyResponse {
        calls.append("identity")
        guard let registration = registrations[target] else {
            throw APIError.e2e(code: E2EErrorCode.keysUnavailable, message: nil)
        }
        return IdentityKeyResponse(userID: target, identityKey: registration.identityKey, identityKeyChangedAt: nil)
    }

    func uploadAttachment(_ jpeg: Data, as user: Profile.ID) -> Photo {
        calls.append("upload.plaintext")
        if let change = afterNextPlaintextUpload {
            afterNextPlaintextUpload = nil
            mode = change.mode
            failConfig = change.failConfig
        }
        return storeUpload(jpeg, encrypted: false)
    }

    func uploadEncryptedAttachment(_ blob: Data, as user: Profile.ID) throws -> Photo {
        calls.append("upload.encrypted")
        // Like the server: 400 `e2e_disabled` with E2E off.
        guard mode != .off else { throw disabled() }
        return storeUpload(blob, encrypted: true)
    }

    private func storeUpload(_ data: Data, encrypted: Bool) -> Photo {
        let id = "ph\(nextID)"
        nextID += 1
        uploads[id] = (data, encrypted)
        uploadLog.append((data, encrypted))
        return Photo(id: id, url: URL(string: "https://media.test/\(id).\(encrypted ? "bin" : "jpg")"))
    }

    /// Like the server's view-once purge: the file is gone, the message stays with `url: null`.
    func spendAttachment(of messageID: Message.ID) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }), let url = messages[index].attachment?.url else { return }
        media[url] = nil
        messages[index].attachment?.url = nil
    }

    /// Replaces a stored file (a server swapping blobs).
    func replaceMedia(at url: URL, with data: Data) { media[url] = data }

    /// Sets a message's `expiresAt` (its recipient read it).
    func setExpiresAt(_ date: Date?, of messageID: Message.ID) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        messages[index].expiresAt = date
    }

    func send(_ draft: MessageDraft, as user: Profile.ID) throws -> Message {
        calls.append(draft.envelope == nil ? "send.plaintext" : "send.envelope")
        if let existing = messages.first(where: { $0.clientID == draft.clientID && $0.senderID == user }) { return existing }
        if failNextSend {
            failNextSend = false
            throw URLError(.networkConnectionLost)
        }
        if draft.envelope != nil && mode == .off { throw disabled() }
        if draft.text != nil && mode == .required {
            throw APIError.e2e(code: E2EErrorCode.encryptionRequired, message: "required")
        }
        precondition(draft.text == nil || draft.envelope == nil, "text and envelope are exclusive")
        var attachment: Message.Attachment?
        if let photoID = draft.attachmentPhotoID {
            guard let upload = uploads[photoID] else { throw APIError.notFound }
            if upload.encrypted && draft.envelope == nil {
                throw APIError.server(status: 400, message: "An encrypted photo must be sent inside an encrypted message.")
            }
            if !upload.encrypted && mode == .required {
                throw APIError.e2e(code: E2EErrorCode.encryptionRequired, message: "required")
            }
            uploads[photoID] = nil
            let url = URL(string: "https://media.test/\(photoID).\(upload.encrypted ? "bin" : "jpg")")!
            media[url] = upload.data
            attachment = Message.Attachment(kind: .photo, url: url, isViewOnce: draft.isViewOnce ?? false, isEncrypted: upload.encrypted)
        }
        let message = Message(
            id: "m\(nextID)",
            conversationID: Self.conversationID,
            senderID: user,
            text: draft.text,
            envelope: draft.envelope,
            attachment: attachment,
            sentAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(nextID)),
            status: .sent,
            expiresAt: nil,
            clientID: draft.clientID
        )
        nextID += 1
        messages.append(message)
        return message
    }

    /// `GET …/messages` as `user` sees it: like the server, the sender of a
    /// view-once photo never gets its URL.
    func page(for user: Profile.ID) -> Page<Message> {
        Page(items: messages.map { view($0, for: user) }, nextCursor: nil)
    }

    private func view(_ message: Message, for user: Profile.ID) -> Message {
        var copy = message
        if message.senderID == user, message.attachment?.isViewOnce == true { copy.attachment?.url = nil }
        return copy
    }

    /// `POST …/messages/{id}/open`: recipient only (else 404), idempotent;
    /// a photo already gone isn't marked opened late.
    func open(_ messageID: Message.ID, as user: Profile.ID) throws -> Message {
        calls.append("open")
        if failNextOpen {
            failNextOpen = false
            throw URLError(.notConnectedToInternet)
        }
        guard let index = messages.firstIndex(where: { $0.id == messageID }),
              messages[index].senderID != user,
              messages[index].attachment?.isViewOnce == true
        else { throw APIError.notFound }
        if messages[index].attachment?.openedAt == nil, messages[index].attachment?.url != nil {
            messages[index].attachment?.openedAt = Date(timeIntervalSince1970: 1_800_000_000)
        }
        return view(messages[index], for: user)
    }
}

/// `APIClient` as one user of `FakeE2EServer`.
struct FakeE2EClient: APIClient {
    let server: FakeE2EServer
    let userID: Profile.ID
    let peerID: Profile.ID

    private static var unused: APIError { .invalidResponse }

    static func profile(_ id: Profile.ID) -> Profile {
        Profile(id: id, displayName: id.capitalized, lookingFor: [], tags: [], photos: [], isOnline: true, isFavorite: false)
    }

    func conversations() async throws -> [Conversation] {
        [Conversation(id: FakeE2EServer.conversationID, participant: Self.profile(peerID), lastMessage: await server.messages.last, unreadCount: 0, updatedAt: .now)]
    }
    func openConversation(with profileID: Profile.ID) async throws -> Conversation { try await conversations()[0] }
    func messages(in conversationID: Conversation.ID, before: Message.ID?) async throws -> Page<Message> { await server.page(for: userID) }
    func openViewOnce(messageID: Message.ID, in conversationID: Conversation.ID) async throws -> Message {
        try await server.open(messageID, as: userID)
    }
    func send(_ draft: MessageDraft, in conversationID: Conversation.ID) async throws -> Message { try await server.send(draft, as: userID) }
    func e2eConfig() async throws -> E2EConfig { try await server.e2eConfig(as: userID) }
    func registerKeys(_ registration: KeyRegistration) async throws -> KeyStatus { try await server.registerKeys(registration, as: userID) }
    func keyStatus() async throws -> KeyStatus { try await server.keyStatus(as: userID) }
    func uploadPreKeys(_ replenishment: PreKeyReplenishment) async throws -> KeyStatus { try await server.uploadPreKeys(replenishment, as: userID) }
    func rotateSignedPreKeys(_ rotation: SignedPreKeyRotation) async throws -> KeyStatus { try await server.rotate(rotation, as: userID) }
    func preKeyBundle(for profileID: Profile.ID) async throws -> PreKeyBundleResponse { try await server.bundle(for: profileID, as: userID) }
    func identityKey(for profileID: Profile.ID) async throws -> IdentityKeyResponse { try await server.identity(of: profileID) }
    func markRead(conversationID: Conversation.ID) async throws {}
    func deleteConversation(_ conversationID: Conversation.ID) async throws {}
    func setMuted(_ isMuted: Bool, conversationID: Conversation.ID) async throws {}
    func deleteAccount() async throws {}

    func register(_ request: RegistrationRequest) async throws -> Session { throw Self.unused }
    func passkeyRegistrationOptions(displayName: String) async throws -> PasskeyCreationOptions { throw Self.unused }
    func finishPasskeyRegistration(_ credential: PasskeyRegistrationCredential) async throws -> Session { throw Self.unused }
    func passkeyLoginOptions() async throws -> PasskeyRequestOptions { throw Self.unused }
    func finishPasskeyLogin(_ credential: PasskeyAssertionCredential) async throws -> Session { throw Self.unused }
    func requestEmailLink(_ request: EmailLinkRequest) async throws { throw Self.unused }
    func verifyEmailLink(token: String, requestNonce: String, confirmed: Bool) async throws -> Session { throw Self.unused }
    func verifyEmailCode(email: String, code: String, requestNonce: String) async throws -> Session { throw Self.unused }
    func refreshSession(refreshToken: String) async throws -> Session { throw Self.unused }
    func logout(_ session: Session) async throws { throw Self.unused }
    func fetchMe() async throws -> Profile { throw Self.unused }
    func updateMe(_ update: ProfileUpdate) async throws -> Profile { throw Self.unused }
    func uploadPhoto(jpegData: Data) async throws -> Photo { throw Self.unused }
    func deletePhoto(id: Photo.ID) async throws { throw Self.unused }
    func uploadAttachment(jpegData: Data) async throws -> Photo { await server.uploadAttachment(jpegData, as: userID) }
    func uploadEncryptedAttachment(_ blob: Data) async throws -> Photo { try await server.uploadEncryptedAttachment(blob, as: userID) }
    func reorderPhotos(_ photoIDs: [Photo.ID]) async throws -> [Photo] { throw Self.unused }
    func updatePrivacy(_ settings: PrivacySettings) async throws -> PrivacySettings { throw Self.unused }
    func updateLocation(_ location: FuzzedLocation) async throws { throw Self.unused }
    func exportData() async throws -> Data { throw Self.unused }
    func nearby(_ query: NearbyQuery) async throws -> Page<Profile> { throw Self.unused }
    func profile(id: Profile.ID) async throws -> Profile { throw Self.unused }
    func setFavorite(_ isFavorite: Bool, profileID: Profile.ID) async throws { throw Self.unused }
    func sendTap(to profileID: Profile.ID) async throws { throw Self.unused }
    func viewers() async throws -> [Profile] { throw Self.unused }
    func block(profileID: Profile.ID) async throws { throw Self.unused }
    func unblock(profileID: Profile.ID) async throws { throw Self.unused }
    func blockedProfiles() async throws -> [Profile] { throw Self.unused }
    func report(_ report: ReportRequest) async throws { throw Self.unused }
    func subscriptionStatus() async throws -> SubscriptionStatus { throw Self.unused }
    func submitAppleTransaction(signedTransaction: String) async throws -> SubscriptionStatus { throw Self.unused }
    func setTravelLocation(_ location: FuzzedLocation?) async throws { throw Self.unused }
    func startBoost() async throws -> Boost { throw Self.unused }
    #if DEBUG
    func debugGrantPlus() async throws { throw Self.unused }
    #endif
    func taps(before cursor: String?) async throws -> TapsPage { throw Self.unused }
    func markTapsSeen() async throws { throw Self.unused }
}

/// One person's app: engine + E2E-wrapped client, with in-memory secrets
/// and history so tests can "reinstall" by swapping either.
struct FakeDevice {
    let userID: Profile.ID
    let engine: E2EEngine
    let client: E2EAPIClient
    let secrets: InMemorySecretStorage
    let history: any E2EHistoryPersistence
    /// Message IDs whose decrypted photos the engine evicted.
    let evicted = CallLog()

    init(
        _ userID: Profile.ID,
        peer: Profile.ID,
        server: FakeE2EServer,
        secrets: InMemorySecretStorage = InMemorySecretStorage(),
        history: any E2EHistoryPersistence = InMemoryHistoryPersistence(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.userID = userID
        self.secrets = secrets
        self.history = history
        let api = FakeE2EClient(server: server, userID: userID, peerID: peer)
        let id: @Sendable () async -> Profile.ID? = { userID }
        let evicted = evicted
        engine = E2EEngine(api: api, secrets: secrets, history: history, currentUserID: id, now: now) { ids in
            for id in ids { await evicted.record(id) }
        }
        client = E2EAPIClient(base: api, engine: engine, currentUserID: id)
    }

    func send(_ text: String, clientID: String = UUID().uuidString) async throws -> Message {
        try await client.send(MessageDraft(clientID: clientID, text: text), in: FakeE2EServer.conversationID)
    }

    func thread() async throws -> [Message] {
        try await client.messages(in: FakeE2EServer.conversationID, before: nil).items
    }

    func sendPhoto(
        _ jpeg: Data,
        caption: String? = nil,
        clientID: String = UUID().uuidString,
        expiresAfterSeconds: Int? = nil,
        isViewOnce: Bool? = false
    ) async throws -> Message {
        let draft = MessageDraft(clientID: clientID, text: caption, expiresAfterSeconds: expiresAfterSeconds, isViewOnce: isViewOnce)
        return try await client.sendPhoto(jpegData: jpeg, draft: draft, in: FakeE2EServer.conversationID)
    }
}

/// A clock tests can move.
final class E2EClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = start }

    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}
