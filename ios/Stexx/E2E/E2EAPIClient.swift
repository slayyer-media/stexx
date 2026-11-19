import Foundation

/// Wraps the live client with end-to-end encryption, so screens keep
/// working with plaintext `Message.text`:
///
/// - `send` encrypts text into an `envelope` when `E2EEngine` says so, and
///   retries once when the server's mode changed under it (`e2e_disabled`
///   after encrypting, `encryption_required` after plaintext).
/// - `sendPhoto` decides the route first, then either uploads the JPEG as a
///   plaintext attachment (no keys / E2E off) or encrypts it, uploads the
///   opaque blob and seals its key (and the message's timer) into the
///   envelope. A plaintext upload only follows a freshly read config. Once a
///   chat is encrypted, a failure never falls back to a plaintext upload.
/// - `conversations`, `openConversation` and `messages` decrypt envelopes
///   (or read the local copy) before returning; `markRead` starts the local
///   expiry of received expiring messages.
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
        // Only this listing hands out every live photo's URL (realtime events
        // withhold view-once ones from the recipient), so `null` here means
        // the photo is gone for good: drop its key.
        let gone = Set(page.items.filter { $0.attachment?.isEncrypted == true && $0.attachment?.url == nil }.map(\.id))
        if !gone.isEmpty {
            await engine.attachmentsGone(messageIDs: Array(gone))
            for index in page.items.indices where gone.contains(page.items[index].id) && page.items[index].e2eAttachment != nil {
                page.items[index].e2eAttachment = nil
                page.items[index].e2eAttachmentRemoval = .gone
            }
        }
        return page
    }

    func send(_ draft: MessageDraft, in conversationID: Conversation.ID) async throws -> Message {
        if draft.attachmentPhotoID != nil, draft.envelope == nil {
            // Photos go through `sendPhoto`, which encrypts the photo with
            // its caption. A photo uploaded elsewhere is only sent as is
            // (plaintext, with a plaintext caption) where the chat isn't
            // encrypted: never a plaintext photo next to encrypted text.
            let peer = try await participant(of: conversationID)
            let caption = draft.text.flatMap { $0.isEmpty ? nil : $0 }
            guard try await engine.route(text: caption, to: peer, conversationID: conversationID) == .plaintext else {
                throw E2EError.encryptionFailed
            }
            return await engine.didSend(try await base.send(draft, in: conversationID), text: caption)
        }
        // A draft that already carries an envelope or has no text passes through.
        guard let text = draft.text, draft.envelope == nil else {
            return try await base.send(draft, in: conversationID)
        }
        let peer = try await participant(of: conversationID)
        return try await sendText(text, draft: draft, to: peer, in: conversationID, isRetry: false)
    }

    func sendPhoto(jpegData: Data, draft: MessageDraft, in conversationID: Conversation.ID) async throws -> Message {
        let peer = try await participant(of: conversationID)
        return try await sendPhoto(jpegData, draft: draft, to: peer, in: conversationID, isRetry: false)
    }

    /// Routes first (nothing is uploaded until it's clear how the photo goes
    /// out), then sends the photo either way.
    private func sendPhoto(_ jpeg: Data, draft: MessageDraft, to peer: Profile.ID, in conversationID: Conversation.ID, isRetry: Bool) async throws -> Message {
        let caption = draft.text.flatMap { $0.isEmpty ? nil : $0 }
        do {
            var route = try await engine.route(text: caption, to: peer, conversationID: conversationID)
            if route == .plaintext {
                // The cached config may be stale (the server may require
                // encryption by now): re-read it and route again before a
                // plaintext photo leaves the phone. No fresh config, no upload.
                _ = try await engine.currentConfig(refresh: true, fallBackToCache: false)
                route = try await engine.route(text: caption, to: peer, conversationID: conversationID)
            }
            switch route {
            case .plaintext:
                // `off`, or `optional` and they can't receive encrypted messages yet.
                let upload = try await base.uploadAttachment(jpegData: jpeg)
                var wire = draft
                wire.envelope = nil
                wire.attachmentPhotoID = upload.id
                let sent = try await base.send(wire, in: conversationID)
                // Drops a blob kept from an earlier, encrypted attempt.
                await engine.didSendPhoto(clientID: draft.clientID)
                return await engine.didSend(sent, text: caption)
            case .encrypt:
                let encrypted = try await encryptedPhoto(jpeg, clientID: draft.clientID)
                let upload = try await base.uploadEncryptedAttachment(encrypted.blob)
                let envelope = try await engine.seal(
                    E2EPayload(text: caption, attachment: encrypted.pointer, expiresAfterSeconds: draft.expiresAfterSeconds),
                    to: peer,
                    conversationID: conversationID,
                    clientID: draft.clientID,
                    expiresAfterSeconds: draft.expiresAfterSeconds,
                    isViewOnce: draft.isViewOnce ?? false
                )
                var wire = draft
                wire.text = nil
                wire.envelope = envelope
                wire.attachmentPhotoID = upload.id
                let sent = try await base.send(wire, in: conversationID)
                await engine.didSendPhoto(clientID: draft.clientID)
                return await engine.didSend(sent, text: caption)
            }
        } catch APIError.e2e(let code, let message) where !isRetry
            && (code == E2EErrorCode.encryptionRequired || code == E2EErrorCode.disabled) {
            // The server's mode changed since the config was read. Retried
            // only on a fresh config: a stale one could upload the plaintext
            // photo again.
            do {
                _ = try await engine.currentConfig(refresh: true, fallBackToCache: false)
            } catch {
                throw APIError.e2e(code: code, message: message)
            }
            return try await sendPhoto(jpeg, draft: draft, to: peer, in: conversationID, isRetry: true)
        } catch let error as APIError {
            if case .server(403, _) = error { await engine.invalidateConfig() }
            throw error
        }
    }

    private func encryptedPhoto(_ jpeg: Data, clientID: String) async throws -> (blob: Data, pointer: E2EAttachmentPointer) {
        do {
            return try await engine.encryptedPhoto(jpeg, clientID: clientID)
        } catch {
            throw E2EError.encryptionFailed
        }
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

    /// Reading starts the timers of received expiring messages: their local
    /// copies (and photo keys) then expire on time.
    func markRead(conversationID: Conversation.ID) async throws {
        let requestedAt = await engine.markReadRequested()
        try await base.markRead(conversationID: conversationID)
        await engine.didMarkRead(conversationID: conversationID, requestedAt: requestedAt)
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
    func passkeyRegistrationOptions(displayName: String) async throws -> PasskeyCreationOptions {
        try await base.passkeyRegistrationOptions(displayName: displayName)
    }
    func finishPasskeyRegistration(_ credential: PasskeyRegistrationCredential) async throws -> Session {
        try await base.finishPasskeyRegistration(credential)
    }
    func passkeyLoginOptions() async throws -> PasskeyRequestOptions { try await base.passkeyLoginOptions() }
    func finishPasskeyLogin(_ credential: PasskeyAssertionCredential) async throws -> Session {
        try await base.finishPasskeyLogin(credential)
    }
    func requestEmailLink(_ request: EmailLinkRequest) async throws { try await base.requestEmailLink(request) }
    func verifyEmailLink(token: String) async throws -> Session { try await base.verifyEmailLink(token: token) }
    func verifyEmailCode(email: String, code: String) async throws -> Session {
        try await base.verifyEmailCode(email: email, code: code)
    }
    func refreshSession(refreshToken: String) async throws -> Session { try await base.refreshSession(refreshToken: refreshToken) }
    func logout(_ session: Session) async throws { try await base.logout(session) }
    func fetchMe() async throws -> Profile { try await base.fetchMe() }
    func updateMe(_ update: ProfileUpdate) async throws -> Profile { try await base.updateMe(update) }
    func uploadPhoto(jpegData: Data) async throws -> Photo { try await base.uploadPhoto(jpegData: jpegData) }
    func deletePhoto(id: Photo.ID) async throws { try await base.deletePhoto(id: id) }
    func uploadAttachment(jpegData: Data) async throws -> Photo { try await base.uploadAttachment(jpegData: jpegData) }
    func uploadEncryptedAttachment(_ blob: Data) async throws -> Photo { try await base.uploadEncryptedAttachment(blob) }
    func reorderPhotos(_ photoIDs: [Photo.ID]) async throws -> [Photo] { try await base.reorderPhotos(photoIDs) }
    func updatePrivacy(_ settings: PrivacySettings) async throws -> PrivacySettings { try await base.updatePrivacy(settings) }
    func updateLocation(_ location: FuzzedLocation) async throws { try await base.updateLocation(location) }
    func exportData() async throws -> Data { try await base.exportData() }
    func nearby(_ query: NearbyQuery) async throws -> Page<Profile> { try await base.nearby(query) }
    func profile(id: Profile.ID) async throws -> Profile { try await base.profile(id: id) }
    func setFavorite(_ isFavorite: Bool, profileID: Profile.ID) async throws { try await base.setFavorite(isFavorite, profileID: profileID) }
    func sendTap(to profileID: Profile.ID) async throws { try await base.sendTap(to: profileID) }
    func viewers() async throws -> [Profile] { try await base.viewers() }
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
