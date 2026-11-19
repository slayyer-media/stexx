import Foundation

/// Wraps the live client with end-to-end encryption, so screens keep
/// working with plaintext `Message.text`:
///
/// - `send` encrypts text into an `envelope` when `E2EEngine` says so, and
///   retries once when the server's mode changed under it (`e2e_disabled`
///   after encrypting, `encryption_required` after plaintext).
/// - `conversations`, `openConversation` and `messages` decrypt envelopes
///   (or read the local copy) before returning.
/// - Deleting a conversation forgets its plaintext; deleting the account
///   wipes this device's keys and history.
///
/// Everything else passes through. Realtime events are decrypted separately
/// (`E2EStatus.process`), since they don't go through `APIClient`.
struct E2EAPIClient: APIClient {
    let base: any APIClient
    let engine: E2EEngine
    let currentUserID: @Sendable () async -> Profile.ID?
    private let directory = ConversationDirectory()

    init(base: any APIClient, engine: E2EEngine, currentUserID: @escaping @Sendable () async -> Profile.ID?) {
        self.base = base
        self.engine = engine
        self.currentUserID = currentUserID
    }

    /// Who each conversation is with (to address envelopes).
    private actor ConversationDirectory {
        private var participants: [Conversation.ID: Profile.ID] = [:]

        func record(_ conversations: [Conversation]) {
            for conversation in conversations { participants[conversation.id] = conversation.participant.id }
        }

        func participant(of id: Conversation.ID) -> Profile.ID? { participants[id] }
    }

    private func participant(of conversationID: Conversation.ID) async throws -> Profile.ID {
        if let known = await directory.participant(of: conversationID) { return known }
        await directory.record(try await base.conversations())
        guard let found = await directory.participant(of: conversationID) else { throw APIError.notFound }
        return found
    }

    // MARK: Chat (encrypting)

    func conversations() async throws -> [Conversation] {
        let list = try await base.conversations()
        await directory.record(list)
        return await engine.reveal(list)
    }

    func openConversation(with profileID: Profile.ID) async throws -> Conversation {
        let conversation = try await base.openConversation(with: profileID)
        await directory.record([conversation])
        return await engine.reveal([conversation])[0]
    }

    func messages(in conversationID: Conversation.ID, before: Message.ID?) async throws -> Page<Message> {
        var page = try await base.messages(in: conversationID, before: before)
        page.items = await engine.reveal(page.items)
        return page
    }

    func send(_ draft: MessageDraft, in conversationID: Conversation.ID) async throws -> Message {
        // Photo-only messages aren't end-to-end encrypted yet (phase 3).
        guard let text = draft.text, draft.envelope == nil else {
            return try await base.send(draft, in: conversationID)
        }
        let peer = try await participant(of: conversationID)
        return try await sendText(text, draft: draft, to: peer, in: conversationID, isRetry: false)
    }

    private func sendText(_ text: String, draft: MessageDraft, to peer: Profile.ID, in conversationID: Conversation.ID, isRetry: Bool) async throws -> Message {
        let outgoing = try await engine.prepareOutgoing(text: text, to: peer, conversationID: conversationID, clientID: draft.clientID)
        var wire = draft
        if case .envelope(let envelope) = outgoing {
            wire.text = nil
            wire.envelope = envelope
        }
        do {
            let sent = try await base.send(wire, in: conversationID)
            return await engine.didSend(sent, text: text)
        } catch APIError.e2e(let code, _) where !isRetry
            && (code == E2EErrorCode.encryptionRequired || code == E2EErrorCode.disabled) {
            // The server's mode changed since the config was read.
            _ = try? await engine.currentConfig(refresh: true)
            return try await sendText(text, draft: draft, to: peer, in: conversationID, isRetry: true)
        } catch let error as APIError {
            // A 403 (trust ramp, review): `contentRules` may have changed.
            if case .server(403, _) = error { await engine.invalidateConfig() }
            throw error
        }
    }

    // MARK: Account

    func deleteConversation(_ conversationID: Conversation.ID) async throws {
        try await base.deleteConversation(conversationID)
        await engine.forgetConversation(conversationID)
    }

    func deleteAccount() async throws {
        let userID = await currentUserID()
        try await base.deleteAccount()
        if let userID { await engine.wipe(userID: userID) }
    }

    // MARK: Pass-through

    func register(_ request: RegistrationRequest) async throws -> Session { try await base.register(request) }
    func requestEmailLink(email: String) async throws { try await base.requestEmailLink(email: email) }
    func verifyEmailLink(token: String) async throws -> Session { try await base.verifyEmailLink(token: token) }
    func refreshSession(refreshToken: String) async throws -> Session { try await base.refreshSession(refreshToken: refreshToken) }
    func logout(_ session: Session) async throws { try await base.logout(session) }
    func fetchMe() async throws -> Profile { try await base.fetchMe() }
    func updateMe(_ update: ProfileUpdate) async throws -> Profile { try await base.updateMe(update) }
    func uploadPhoto(jpegData: Data) async throws -> Photo { try await base.uploadPhoto(jpegData: jpegData) }
    func deletePhoto(id: Photo.ID) async throws { try await base.deletePhoto(id: id) }
    func uploadAttachment(jpegData: Data) async throws -> Photo { try await base.uploadAttachment(jpegData: jpegData) }
    func reorderPhotos(_ photoIDs: [Photo.ID]) async throws -> [Photo] { try await base.reorderPhotos(photoIDs) }
    func updatePrivacy(_ settings: PrivacySettings) async throws -> PrivacySettings { try await base.updatePrivacy(settings) }
    func updateLocation(_ location: FuzzedLocation) async throws { try await base.updateLocation(location) }
    func exportData() async throws -> Data { try await base.exportData() }
    func nearby(_ query: NearbyQuery) async throws -> Page<Profile> { try await base.nearby(query) }
    func profile(id: Profile.ID) async throws -> Profile { try await base.profile(id: id) }
    func setFavorite(_ isFavorite: Bool, profileID: Profile.ID) async throws { try await base.setFavorite(isFavorite, profileID: profileID) }
    func sendTap(to profileID: Profile.ID) async throws { try await base.sendTap(to: profileID) }
    func viewers() async throws -> [Profile] { try await base.viewers() }
    func markRead(conversationID: Conversation.ID) async throws { try await base.markRead(conversationID: conversationID) }
    func e2eConfig() async throws -> E2EConfig { try await base.e2eConfig() }
    func registerKeys(_ registration: KeyRegistration) async throws -> KeyStatus { try await base.registerKeys(registration) }
    func keyStatus() async throws -> KeyStatus { try await base.keyStatus() }
    func uploadPreKeys(_ replenishment: PreKeyReplenishment) async throws -> KeyStatus { try await base.uploadPreKeys(replenishment) }
    func rotateSignedPreKeys(_ rotation: SignedPreKeyRotation) async throws -> KeyStatus { try await base.rotateSignedPreKeys(rotation) }
    func preKeyBundle(for profileID: Profile.ID) async throws -> PreKeyBundleResponse { try await base.preKeyBundle(for: profileID) }
    func identityKey(for profileID: Profile.ID) async throws -> IdentityKeyResponse { try await base.identityKey(for: profileID) }
    func block(profileID: Profile.ID) async throws { try await base.block(profileID: profileID) }
    func unblock(profileID: Profile.ID) async throws { try await base.unblock(profileID: profileID) }
    func blockedProfiles() async throws -> [Profile] { try await base.blockedProfiles() }
    func report(_ report: ReportRequest) async throws { try await base.report(report) }
    func subscriptionStatus() async throws -> SubscriptionStatus { try await base.subscriptionStatus() }
    func submitAppleTransaction(signedTransaction: String) async throws -> SubscriptionStatus {
        try await base.submitAppleTransaction(signedTransaction: signedTransaction)
    }
    func setTravelLocation(_ location: FuzzedLocation?) async throws { try await base.setTravelLocation(location) }
    func startBoost() async throws -> Boost { try await base.startBoost() }

    #if DEBUG
    func debugGrantPlus() async throws { try await base.debugGrantPlus() }
    #endif
}
