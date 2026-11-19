import Foundation

/// In-memory backend used until the real server exists, and for previews and
/// tests. Behaves like the API contract in `docs/api.md`, including small
/// artificial latency so loading states are visible.
actor MockAPIClient: APIClient {
    #if DEBUG
    /// `-StexxScreenshotPlus YES` starts the mock with Stexx+ (screenshots).
    static let shared = MockAPIClient(
        plusActive: ScreenshotRoute.startsWithPlus,
        meLatency: ScreenshotRoute.mockMeDelay,
        failsPrivacySaves: ScreenshotRoute.mockFailsPrivacySaves
    )
    #else
    static let shared = MockAPIClient()
    #endif

    private var me: Profile
    /// Private chat uploads (`uploadAttachment`), consumed by `send`.
    private var attachments: [Photo.ID: URL] = [:]
    private var profiles: [Profile.ID: Profile]
    private var conversationStore: [Conversation.ID: Conversation]
    private var messageStore: [Conversation.ID: [Message]]
    private var blocked: Set<Profile.ID> = []
    /// The most recent report received, so tests can inspect what was sent.
    private(set) var lastReport: ReportRequest?
    private var privacy = PrivacySettings()
    private let latency: Duration
    /// Extra wait on `GET /me` (screenshots of the loading state).
    private let meLatency: Duration
    /// `PUT /me/privacy` fails like a dropped connection (screenshots of the
    /// rollback).
    private let failsPrivacySaves: Bool
    private var nextID = 1
    private var plusExpiresAt: Date?
    private var travelLocation: FuzzedLocation?
    /// Passkey sign-up in progress: challenge → nickname (like `auth_challenges`).
    private var pendingPasskeySignUps: [String: String] = [:]
    private var pendingPasskeyLogins: Set<String> = []
    /// Injected failures and delays, by method name (see `inject(_:for:)`).
    private var injectedOutcomes: [String: InjectedOutcome] = [:]
    /// Auto-renew status reported with an active subscription.
    private var plusWillRenew: Bool? = true
    private var boostEndsAt: Date?
    /// Email sign-in links "sent" (token → address), like `email_link_tokens`.
    private var emailLinks: [String: String] = [:]
    /// The request nonce each link was asked for with (token → nonce).
    private var emailLinkNonces: [String: String] = [:]
    /// Addresses with a live code (address → pending nickname, if a sign-up).
    private var emailCodes: [String: String?] = [:]
    /// Send times per address, for the server's 3-per-15-minutes limit.
    private var emailSends: [String: [Date]] = [:]
    /// The token in the newest fake email (tests open it as a link).
    private(set) var lastEmailLinkToken: String?

    /// Every fake sign-in email carries this code (Debug builds: type it on
    /// the "check your email" screen).
    static let emailCode = "12345678"
    /// See `verifyEmailLink`.
    static let someoneElsesLinkPrefix = "someone-else"

    init(latency: Duration = .milliseconds(250), plusActive: Bool = false, meLatency: Duration = .zero, failsPrivacySaves: Bool = false) {
        self.meLatency = meLatency
        self.failsPrivacySaves = failsPrivacySaves
        let profilesByID = Dictionary(uniqueKeysWithValues: MockData.profiles.map { ($0.id, $0) })
        var seededConversations: [Conversation.ID: Conversation] = [:]
        var seededMessages: [Conversation.ID: [Message]] = [:]
        let now = Date.now

        for (participantID, thread) in MockData.seedThreads {
            guard let participant = profilesByID[participantID] else { continue }
            let conversationID = "c-\(participantID)"
            let threadMessages = thread.enumerated().map { index, entry in
                Message(
                    id: "\(conversationID)-m\(index)",
                    conversationID: conversationID,
                    senderID: entry.0 ? MockData.myID : participantID,
                    text: entry.1,
                    attachment: nil,
                    sentAt: now.addingTimeInterval(-entry.2 * 60),
                    status: entry.0 ? .read : .delivered,
                    expiresAt: nil,
                    clientID: nil
                )
            }
            // Messages they sent after my last reply count as unread.
            let unread = thread.reversed().prefix { !$0.0 }.count
            seededMessages[conversationID] = threadMessages
            seededConversations[conversationID] = Conversation(
                id: conversationID,
                participant: participant,
                lastMessage: threadMessages.last,
                unreadCount: unread,
                updatedAt: threadMessages.last?.sentAt ?? now
            )
        }

        self.latency = latency
        self.me = MockData.me
        self.profiles = profilesByID
        self.conversationStore = seededConversations
        self.messageStore = seededMessages
        self.plusExpiresAt = plusActive ? now.addingTimeInterval(30 * 24 * 3600) : nil
    }

    // MARK: Auth & account

    func register(_ request: RegistrationRequest) async throws -> Session {
        try await pause()
        me.displayName = request.displayName
        return MockData.session
    }

    /// Like the server: one email with a link and a code; 3 per address in
    /// 15 minutes, then 429 with the wait.
    func requestEmailLink(_ request: EmailLinkRequest) async throws {
        try await pause()
        let address = request.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard address.contains("@") else { throw APIError.server(status: 400, message: "email: must be a valid email address") }
        guard (request.displayName == nil) == (request.confirmedAdult == nil), request.confirmedAdult != false else {
            throw APIError.server(status: 400, message: "displayName and confirmedAdult must be sent together")
        }
        let now = Date.now
        let window: TimeInterval = 15 * 60
        let recent = (emailSends[address] ?? []).filter { now.timeIntervalSince($0) < window }
        if recent.count >= 3, let oldest = recent.first {
            emailSends[address] = recent
            throw APIError.rateLimited(retryAfter: window - now.timeIntervalSince(oldest))
        }
        emailSends[address] = recent + [now]
        let token = Self.randomBase64URL(32)
        emailLinks[token] = address
        emailLinkNonces[token] = request.requestNonce
        lastEmailLinkToken = token
        emailCodes.updateValue(request.displayName, forKey: address)
    }

    /// Like the server: only in the app install that asked for the email.
    func verifyEmailCode(email: String, code: String, requestNonce: String) async throws -> Session {
        try await pause()
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let askedHere = emailLinks.contains { $0.value == address && emailLinkNonces[$0.key] == requestNonce }
        guard code == Self.emailCode, askedHere, let pending = emailCodes.removeValue(forKey: address) else {
            throw EmailSignInError.invalidCode
        }
        emailLinks = emailLinks.filter { $0.value != address }
        emailLinkNonces = emailLinkNonces.filter { emailLinks[$0.key] != nil }
        if let pending { me.displayName = pending }
        return MockData.session
    }

    // MARK: Passkeys (simulated: pairs with `SimulatedPasskeyAuthenticator`)

    func passkeyRegistrationOptions(displayName: String) async throws -> PasskeyCreationOptions {
        try await pause()
        let challenge = Self.randomBase64URL(32)
        pendingPasskeySignUps[challenge] = displayName
        return PasskeyCreationOptions(
            challenge: challenge,
            rp: .init(id: PasskeyAvailability.defaultRelyingPartyID, name: "Stexx"),
            // Like the server: a neutral label, never the nickname.
            user: .init(id: Self.randomBase64URL(32), name: "Stexx account", displayName: "Stexx account"),
            timeout: 300_000,
            attestation: "none",
            excludeCredentials: [],
            authenticatorSelection: .init(residentKey: "required", userVerification: "required")
        )
    }

    func finishPasskeyRegistration(_ credential: PasskeyRegistrationCredential) async throws -> Session {
        try await pause()
        guard credential.confirmedAdult else {
            throw APIError.server(status: 400, message: "You must confirm that you are 18 or older.")
        }
        guard let challenge = Self.challenge(in: credential.response.clientDataJSON, type: "webauthn.create"),
              let displayName = pendingPasskeySignUps.removeValue(forKey: challenge),
              Data(base64URLEncoded: credential.rawId) != nil,
              Data(base64URLEncoded: credential.response.attestationObject) != nil
        else { throw APIError.server(status: 400, message: "This sign-up expired. Please start again.") }
        me.displayName = displayName
        return MockData.session
    }

    func passkeyLoginOptions() async throws -> PasskeyRequestOptions {
        try await pause()
        let challenge = Self.randomBase64URL(32)
        pendingPasskeyLogins.insert(challenge)
        return PasskeyRequestOptions(challenge: challenge, rpId: PasskeyAvailability.defaultRelyingPartyID, timeout: 300_000, userVerification: "required", allowCredentials: [])
    }

    func finishPasskeyLogin(_ credential: PasskeyAssertionCredential) async throws -> Session {
        try await pause()
        guard let challenge = Self.challenge(in: credential.response.clientDataJSON, type: "webauthn.get"),
              pendingPasskeyLogins.remove(challenge) != nil
        else { throw APIError.unauthorized }
        return MockData.session
    }

    private static func randomBase64URL(_ count: Int) -> String {
        Data((0..<count).map { _ in UInt8.random(in: .min ... .max) }).base64URLEncodedString()
    }

    /// The challenge inside a base64url `clientDataJSON` of the given type.
    private static func challenge(in clientDataJSON: String, type: String) -> String? {
        struct ClientData: Decodable { let type: String; let challenge: String }
        guard let data = Data(base64URLEncoded: clientDataJSON),
              let parsed = try? JSONDecoder().decode(ClientData.self, from: data),
              parsed.type == type
        else { return nil }
        return parsed.challenge
    }

    /// Links from `requestEmailLink` work once; anything else is expired.
    /// A link asked for with another nonce asks first, like the server.
    /// A link token starting with `someone-else` stands for a link another
    /// install asked for (Debug: `-StexxOpenURL` shows "sign in as …?").
    func verifyEmailLink(token: String, requestNonce: String, confirmed: Bool) async throws -> Session {
        try await pause()
        if token.hasPrefix(Self.someoneElsesLinkPrefix) {
            guard confirmed else {
                throw EmailSignInError.confirmationRequired(EmailLinkAccount(isNew: false, displayName: "NightOwl"))
            }
            return MockData.session
        }
        guard let address = emailLinks[token] else { throw EmailSignInError.invalidLink }
        if !confirmed, emailLinkNonces[token] != requestNonce {
            let pending = emailCodes[address] ?? nil
            throw EmailSignInError.confirmationRequired(EmailLinkAccount(isNew: pending != nil, displayName: pending ?? me.displayName))
        }
        emailLinks.removeValue(forKey: token)
        emailLinkNonces.removeValue(forKey: token)
        if let pending = emailCodes.removeValue(forKey: address), let pending { me.displayName = pending }
        return MockData.session
    }

    func refreshSession(refreshToken: String) async throws -> Session {
        try await pause()
        return MockData.session
    }

    func logout(_ session: Session) async throws {
        try await pause()
    }

    func deleteAccount() async throws {
        try await pause()
        me = MockData.me
        conversationStore.removeAll()
        messageStore.removeAll()
        blocked.removeAll()
        plusExpiresAt = nil
        travelLocation = nil
        boostEndsAt = nil
        privacy = PrivacySettings()
    }

    // MARK: Me

    func fetchMe() async throws -> Profile {
        try await pause()
        if meLatency > .zero { try await Task.sleep(for: meLatency) }
        return ownProfile
    }

    func updateMe(_ update: ProfileUpdate) async throws -> Profile {
        try await pause()
        me.displayName = update.displayName
        me.age = update.age
        me.pronouns = update.pronouns
        me.headline = update.headline
        me.about = update.about
        me.heightCm = update.heightCm
        me.position = update.position
        me.lookingFor = update.lookingFor
        me.tags = update.tags
        return ownProfile
    }

    /// `GET`/`PATCH /me`: the profile plus travel mode and the stored privacy
    /// settings, like the server (travel paused while Stexx+ is off; never
    /// any coordinates).
    private var ownProfile: Profile {
        var profile = me
        profile.travel = travelLocation.map { _ in TravelStatus(isActive: currentPlusStatus.isActive) }
        profile.privacy = privacy
        return profile
    }

    func uploadPhoto(jpegData: Data) async throws -> Photo {
        try await pause()
        // Keep the image on disk so AsyncImage can load it like a remote URL.
        let id = makeID("photo")
        let url = URL.temporaryDirectory.appending(path: "\(id).jpg")
        try jpegData.write(to: url, options: .completeFileProtection)
        let photo = Photo(id: id, url: url)
        me.photos.append(photo)
        return photo
    }

    func uploadAttachment(jpegData: Data) async throws -> Photo {
        try await pause()
        // Private: written to disk for display but never added to the profile.
        let id = makeID("attachment")
        let url = URL.temporaryDirectory.appending(path: "\(id).jpg")
        try jpegData.write(to: url, options: .completeFileProtection)
        attachments[id] = url
        return Photo(id: id, url: url)
    }

    /// Like a server with `E2E_MODE=off`: encrypted uploads are refused, so
    /// the app never gets this far (it routes to plaintext first).
    func uploadEncryptedAttachment(_ blob: Data) async throws -> Photo {
        try await pause()
        throw Self.e2eDisabled
    }

    func deletePhoto(id: Photo.ID) async throws {
        try await pause()
        guard me.photos.contains(where: { $0.id == id }) else { throw APIError.notFound }
        me.photos.removeAll { $0.id == id }
    }

    func reorderPhotos(_ photoIDs: [Photo.ID]) async throws -> [Photo] {
        try await pause()
        let byID = Dictionary(uniqueKeysWithValues: me.photos.map { ($0.id, $0) })
        guard Set(photoIDs) == Set(byID.keys), photoIDs.count == byID.count else {
            throw APIError.server(status: 400, message: "photoIDs must list every photo once.")
        }
        me.photos = photoIDs.compactMap { byID[$0] }
        return me.photos
    }

    func updatePrivacy(_ settings: PrivacySettings) async throws -> PrivacySettings {
        try await pause()
        if failsPrivacySaves { throw URLError(.networkConnectionLost) }
        var next = settings
        // Like the server: turning incognito on needs Stexx+; a lapsed
        // subscriber echoing it back just has it switched off.
        if next.incognito, !currentPlusStatus.isActive {
            guard privacy.incognito else { throw APIError.requiresPlus }
            next.incognito = false
        }
        privacy = next
        return privacy
    }

    func updateLocation(_ location: FuzzedLocation) async throws {
        try await pause()
    }

    func exportData() async throws -> Data {
        try await pause()
        struct Archive: Encodable {
            let profile: Profile
            let privacy: PrivacySettings
            let messages: [Message]
        }
        let mine = messageStore.values.flatMap { $0 }.filter { $0.senderID == MockData.myID }
        return try JSONEncoder.stexx().encode(Archive(profile: me, privacy: privacy, messages: mine))
    }

    // MARK: Discovery

    func nearby(_ query: NearbyQuery) async throws -> Page<Profile> {
        try await pause()
        var results = profiles.values
            .filter { !blocked.contains($0.id) }
            .sorted { ($0.distanceMeters ?? .infinity) < ($1.distanceMeters ?? .infinity) }

        if query.onlineOnly { results = results.filter(\.isOnline) }
        if query.favoritesOnly { results = results.filter(\.isFavorite) }
        if !query.lookingFor.isEmpty {
            results = results.filter { !query.lookingFor.isDisjoint(with: $0.lookingFor) }
        }
        if let minAge = query.minAge { results = results.filter { ($0.age ?? .max) >= minAge } }
        if let maxAge = query.maxAge { results = results.filter { ($0.age ?? .min) <= maxAge } }
        if let maxDistance = query.maxDistanceMeters {
            results = results.filter { ($0.distanceMeters ?? .infinity) <= maxDistance }
        }
        if !query.positions.isEmpty {
            results = results.filter { profile in profile.position.map { query.positions.contains($0) } ?? false }
        }
        if !query.tags.isEmpty {
            let wanted = Set(query.tags.map { $0.lowercased() })
            results = results.filter { !wanted.isDisjoint(with: $0.tags.map { $0.lowercased() }) }
        }

        let start = query.cursor.flatMap(Int.init) ?? 0
        let end = min(results.count, start + query.limit)
        let page = start < end ? Array(results[start..<end]) : []
        return Page(items: page, nextCursor: end < results.count ? String(end) : nil)
    }

    func profile(id: Profile.ID) async throws -> Profile {
        try await pause()
        guard let profile = profiles[id], !blocked.contains(id) else { throw APIError.notFound }
        return profile
    }

    func setFavorite(_ isFavorite: Bool, profileID: Profile.ID) async throws {
        try await pause()
        profiles[profileID]?.isFavorite = isFavorite
    }

    func sendTap(to profileID: Profile.ID) async throws {
        try await pause()
    }

    func viewers() async throws -> [Profile] {
        try await pause()
        return Array(profiles.values.filter(\.isOnline).prefix(4))
    }

    // MARK: Chat

    func conversations() async throws -> [Conversation] {
        try await pause()
        #if DEBUG
        if failsConversationList {
            // What URLSession reports when the phone is offline.
            throw URLError(.notConnectedToInternet, userInfo: [NSLocalizedDescriptionKey: "The Internet connection appears to be offline."])
        }
        #endif
        return conversationStore.values
            .filter { !blocked.contains($0.participant.id) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func openConversation(with profileID: Profile.ID) async throws -> Conversation {
        try await pause()
        if let existing = conversationStore.values.first(where: { $0.participant.id == profileID }) {
            return existing
        }
        guard let participant = profiles[profileID], !blocked.contains(profileID) else { throw APIError.notFound }
        let conversation = Conversation(
            id: "c-\(profileID)",
            participant: participant,
            lastMessage: nil,
            unreadCount: 0,
            updatedAt: .now
        )
        conversationStore[conversation.id] = conversation
        messageStore[conversation.id] = []
        return conversation
    }

    func messages(in conversationID: Conversation.ID, before: Message.ID?) async throws -> Page<Message> {
        try await pause()
        #if DEBUG
        if before != nil, ScreenshotRoute.mockOlderPageDelay > 0 {
            try await Task.sleep(for: .seconds(ScreenshotRoute.mockOlderPageDelay))
        }
        #endif
        guard let all = messageStore[conversationID] else { throw APIError.notFound }
        let upper = before.flatMap { id in all.firstIndex { $0.id == id } } ?? all.count
        let lower = max(0, upper - 50)
        return Page(items: Array(all[lower..<upper]), nextCursor: lower > 0 ? all[lower].id : nil)
    }

    func send(_ draft: MessageDraft, in conversationID: Conversation.ID) async throws -> Message {
        try await pause()
        guard var conversation = conversationStore[conversationID] else { throw APIError.notFound }
        if blocked.contains(conversation.participant.id) { throw APIError.notFound }

        #if DEBUG
        if let failure = ScreenshotRoute.mockSendFailure { throw Self.screenshotSendFailure(failure) }
        #endif
        // Idempotency: resending the same draft returns the original message.
        if let existing = messageStore[conversationID]?.first(where: { $0.clientID == draft.clientID }) {
            return existing
        }
        // Like the server, an attachment is a copy of an uploaded photo.
        let attachment = draft.attachmentPhotoID.map { photoID in
            Message.Attachment(
                kind: .photo,
                url: attachments.removeValue(forKey: photoID) ?? me.photos.first { $0.id == photoID }?.url,
                isViewOnce: draft.isViewOnce ?? false
            )
        }
        // The mock backend behaves like a server with `E2E_MODE=off`.
        if draft.envelope != nil {
            throw APIError.e2e(code: E2EErrorCode.disabled, message: "End-to-end encryption isn't switched on for this server yet.")
        }
        if draft.text == nil && attachment == nil {
            throw APIError.server(status: 400, message: "A message needs text or a photo.")
        }
        let message = Message(
            id: makeID("m"),
            conversationID: conversationID,
            senderID: MockData.myID,
            text: draft.text,
            attachment: attachment,
            sentAt: .now,
            status: .sent,
            expiresAt: nil,
            clientID: draft.clientID
        )
        messageStore[conversationID, default: []].append(message)
        conversation.lastMessage = message
        conversation.updatedAt = message.sentAt
        conversationStore[conversationID] = conversation
        return message
    }

    func markRead(conversationID: Conversation.ID) async throws {
        conversationStore[conversationID]?.unreadCount = 0
    }

    /// Like the server: idempotent, 404 for an unknown or blocked thread.
    func setMuted(_ isMuted: Bool, conversationID: Conversation.ID) async throws {
        try await pause()
        guard let conversation = conversationStore[conversationID],
              !blocked.contains(conversation.participant.id)
        else { throw APIError.notFound }
        conversationStore[conversationID]?.isMuted = isMuted
    }

    /// Like the server: only the recipient of a view-once photo, idempotent,
    /// and a photo that's already gone isn't marked opened late.
    func openViewOnce(messageID: Message.ID, in conversationID: Conversation.ID) async throws -> Message {
        try await pause()
        guard let conversation = conversationStore[conversationID],
              !blocked.contains(conversation.participant.id),
              let index = messageStore[conversationID]?.firstIndex(where: { $0.id == messageID }),
              var message = messageStore[conversationID]?[index],
              message.senderID != MockData.myID,
              message.attachment?.isViewOnce == true
        else { throw APIError.notFound }
        if message.attachment?.openedAt == nil, message.attachment?.url != nil {
            message.attachment?.openedAt = .now
            messageStore[conversationID]?[index] = message
            if conversationStore[conversationID]?.lastMessage?.id == messageID {
                conversationStore[conversationID]?.lastMessage = message
            }
        }
        return message
    }

    func deleteConversation(_ conversationID: Conversation.ID) async throws {
        try await pause()
        conversationStore[conversationID] = nil
        messageStore[conversationID] = nil
    }

    // MARK: End-to-end encryption

    // The mock backend is a server with `E2E_MODE=off`: the app keeps the
    // plaintext path, so the Debug scheme, previews and UI tests need no
    // keys or Keychain. Real crypto is covered by `E2EEngineTests` with two
    // in-memory devices, and by the Local scheme against `server/`.

    func e2eConfig() async throws -> E2EConfig {
        try await pause()
        return .off
    }

    private static var e2eDisabled: APIError {
        .e2e(code: E2EErrorCode.disabled, message: "End-to-end encryption isn't switched on for this server yet.")
    }

    func registerKeys(_ registration: KeyRegistration) async throws -> KeyStatus { throw Self.e2eDisabled }
    func keyStatus() async throws -> KeyStatus { throw Self.e2eDisabled }
    func uploadPreKeys(_ replenishment: PreKeyReplenishment) async throws -> KeyStatus { throw Self.e2eDisabled }
    func rotateSignedPreKeys(_ rotation: SignedPreKeyRotation) async throws -> KeyStatus { throw Self.e2eDisabled }
    func preKeyBundle(for profileID: Profile.ID) async throws -> PreKeyBundleResponse { throw Self.e2eDisabled }
    func identityKey(for profileID: Profile.ID) async throws -> IdentityKeyResponse { throw Self.e2eDisabled }

    // MARK: Safety

    func block(profileID: Profile.ID) async throws {
        try await pause()
        blocked.insert(profileID)
    }

    func unblock(profileID: Profile.ID) async throws {
        try await pause()
        blocked.remove(profileID)
    }

    func blockedProfiles() async throws -> [Profile] {
        try await pause()
        return blocked.compactMap { profiles[$0] }.sorted { $0.displayName < $1.displayName }
    }

    func report(_ report: ReportRequest) async throws {
        try await pause()
        // Like the server: an evidence photo is one of your pending uploads
        // (consumed by the report), each used once.
        let photoIDs = report.evidence?.compactMap(\.photoID) ?? []
        guard Set(photoIDs).count == photoIDs.count else {
            throw APIError.server(status: 400, message: "Each evidence photo can only be used once.")
        }
        guard photoIDs.allSatisfy({ attachments[$0] != nil }) else { throw APIError.notFound }
        for id in photoIDs { attachments[id] = nil }
        lastReport = report
        if report.alsoBlock { blocked.insert(report.profileID) }
    }

    // MARK: Stexx+

    func subscriptionStatus() async throws -> SubscriptionStatus {
        try await pause()
        return currentPlusStatus
    }

    func submitAppleTransaction(signedTransaction: String) async throws -> SubscriptionStatus {
        try await pause()
        // The mock trusts any transaction; the real server verifies the JWS.
        plusExpiresAt = Date.now.addingTimeInterval(30 * 24 * 3600)
        return currentPlusStatus
    }

    func setTravelLocation(_ location: FuzzedLocation?) async throws {
        try await pause()
        // Like the server: turning it off is always allowed.
        guard location == nil || currentPlusStatus.isActive else { throw APIError.requiresPlus }
        travelLocation = location
    }

    func startBoost() async throws -> Boost {
        try await pause()
        guard currentPlusStatus.isActive else { throw APIError.requiresPlus }
        // Not stackable, like the server: a running boost keeps its end time.
        if let boostEndsAt, boostEndsAt > .now { return Boost(endsAt: boostEndsAt) }
        let endsAt = Date.now.addingTimeInterval(3600)
        boostEndsAt = endsAt
        return Boost(endsAt: endsAt)
    }

    #if DEBUG
    func debugGrantPlus() async throws {
        try await pause()
        plusExpiresAt = Date.now.addingTimeInterval(30 * 24 * 3600)
    }
    #endif

    private var currentPlusStatus: SubscriptionStatus {
        let boost = boostEndsAt.flatMap { $0 > .now ? $0 : nil }
        guard let plusExpiresAt, plusExpiresAt > .now else {
            return SubscriptionStatus(isActive: false, expiresAt: nil, boostEndsAt: boost)
        }
        return SubscriptionStatus(isActive: true, expiresAt: plusExpiresAt, willRenew: plusWillRenew, boostEndsAt: boost)
    }

    // MARK: Helpers

    #if DEBUG
    /// The refusals a real server sends (`docs/api.md`), for screenshots.
    private static func screenshotSendFailure(_ kind: String) -> any Error {
        switch kind {
        case "rateLimited": APIError.rateLimited(retryAfter: 120)
        case "newAccountLimit":
            APIError.server(status: 403, message: "New accounts can start 3 new chats a day. You can keep chatting with people who've replied.", code: "new_account_limit")
        case "linksNotAllowed":
            APIError.server(status: 403, message: "New accounts can't send links yet. Try again in a day or so.", code: "links_not_allowed")
        case "underReview":
            APIError.server(status: 403, message: "Your account is being reviewed by our moderators. Until then you can keep chatting with people who've written to you, but you can't start new chats.", code: "account_under_review")
        default: URLError(.notConnectedToInternet)
        }
    }
    #endif

    private func pause(_ function: String = #function) async throws {
        try await Task.sleep(for: latency)
        try await injectedOutcome(for: function)
    }

    private func makeID(_ prefix: String) -> String {
        defer { nextID += 1 }
        return "\(prefix)-\(nextID)-\(UUID().uuidString.prefix(8))"
    }

    // MARK: Taps

    /// Taps received: sender and time, newest first (one per sender, like
    /// the server's list).
    private var receivedTaps: [(from: Profile.ID, sentAt: Date)] = MockData.seedTaps.map {
        ($0.0, Date.now.addingTimeInterval(-$0.1 * 60))
    }
    private var tapsSeenAt: Date? = Date.now.addingTimeInterval(-MockData.tapsSeenMinutesAgo * 60)
    private var tapsPageSize = 30

    func taps(before cursor: String?) async throws -> TapsPage {
        try await pause()
        #if DEBUG
        if failsTaps {
            throw URLError(.notConnectedToInternet, userInfo: [NSLocalizedDescriptionKey: "The Internet connection appears to be offline."])
        }
        #endif
        let all = receivedTaps
            .filter { !blocked.contains($0.from) }
            .sorted { $0.sentAt > $1.sentAt }
            .compactMap { tap in
                profiles[tap.from].map { profile in
                    ReceivedTap(from: profile, sentAt: tap.sentAt, isNew: tapsSeenAt.map { tap.sentAt > $0 } ?? true)
                }
            }
        let start = cursor.flatMap(Int.init) ?? 0
        let end = min(all.count, start + tapsPageSize)
        let page = start < end ? Array(all[start..<end]) : []
        return TapsPage(
            items: page,
            nextCursor: end < all.count ? String(end) : nil,
            unseenCount: all.filter(\.isNew).count
        )
    }

    func markTapsSeen() async throws {
        try await pause()
        tapsSeenAt = .now
    }

    #if DEBUG
    /// Screenshots and tests: `conversations()` fails like a dropped
    /// connection while this is on.
    private var failsConversationList = false

    func setFailsConversationList(_ fails: Bool) {
        failsConversationList = fails
    }

    /// Screenshots and tests: `taps(before:)` fails like a dropped
    /// connection while this is on.
    private var failsTaps = false

    func setFailsTaps(_ fails: Bool) {
        failsTaps = fails
    }

    /// Tests: a smaller taps page, to exercise infinite scroll.
    func setTapsPageSize(_ size: Int) {
        tapsPageSize = max(1, size)
    }

    /// Screenshots and tests: nobody has tapped you.
    func removeAllTaps() {
        receivedTaps = []
    }

    /// Tests: someone taps you now (what `tap.received` reports live).
    func receiveTap(from profileID: Profile.ID, at date: Date = .now) {
        receivedTaps.removeAll { $0.from == profileID }
        receivedTaps.insert((profileID, date), at: 0)
    }
    #endif
}

// MARK: - Failure injection

/// Lets tests, previews and Debug screenshots make one mock endpoint fail (or
/// hang) without a server. Keys are the method's base name, as in
/// `"fetchMe"`, `"sendTap"` or `"setFavorite"`; every method that calls
/// `pause()` honours them.
extension MockAPIClient {
    /// What an injected endpoint does instead of answering.
    enum InjectedOutcome: Sendable {
        case fail(any Error)
        /// Waits this long before answering normally (loading states).
        case delay(Duration)
    }

    /// Makes `method` fail (or hang) until cleared with `nil`.
    func inject(_ outcome: InjectedOutcome?, for method: String) {
        injectedOutcomes[method] = outcome
    }

    fileprivate func injectedOutcome(for function: String) async throws {
        let method = String(function.prefix { $0 != "(" })
        switch injectedOutcomes[method] ?? Self.launchOutcomes[method] {
        case .fail(let error)?:
            throw error
        case .delay(let duration)?:
            try await Task.sleep(for: duration)
        case nil:
            break
        }
    }

    /// Debug builds only: `-StexxMockFail "fetchMe=offline,sendTap=429"`.
    /// Values: `offline`, `429` (Retry-After 10 min), `402`, `403` (account
    /// under review), `500`, or `hang` (answers after 10 minutes).
    static let launchOutcomes: [String: InjectedOutcome] = {
        #if DEBUG
        guard let spec = UserDefaults.standard.string(forKey: "StexxMockFail") else { return [:] }
        return parseLaunchOutcomes(spec)
        #else
        return [:]
        #endif
    }()

    static func parseLaunchOutcomes(_ spec: String) -> [String: InjectedOutcome] {
        var outcomes: [String: InjectedOutcome] = [:]
        for entry in spec.split(separator: ",") {
            let parts = entry.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty else { continue }
            let outcome: InjectedOutcome? = switch parts[1] {
            case "offline": .fail(URLError(.notConnectedToInternet))
            case "429": .fail(APIError.rateLimited(retryAfter: 600))
            case "402": .fail(APIError.requiresPlus)
            case "403": .fail(APIError.server(
                status: 403,
                message: "Your account is being reviewed by our moderators. Until then you can keep chatting with people who've written to you, but you can't start new chats."
            ))
            case "500": .fail(APIError.server(status: 500, message: nil))
            case "hang": .delay(.seconds(600))
            default: nil
            }
            if let outcome { outcomes[parts[0]] = outcome }
        }
        return outcomes
    }
}
