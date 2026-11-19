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

    func requestEmailLink(email: String) async throws {
        try await pause()
    }

    func verifyEmailLink(token: String) async throws -> Session {
        try await pause()
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
        guard let all = messageStore[conversationID] else { throw APIError.notFound }
        let upper = before.flatMap { id in all.firstIndex { $0.id == id } } ?? all.count
        let lower = max(0, upper - 50)
        return Page(items: Array(all[lower..<upper]), nextCursor: lower > 0 ? all[lower].id : nil)
    }

    func send(_ draft: MessageDraft, in conversationID: Conversation.ID) async throws -> Message {
        try await pause()
        guard var conversation = conversationStore[conversationID] else { throw APIError.notFound }
        if blocked.contains(conversation.participant.id) { throw APIError.notFound }

        // Idempotency: resending the same draft returns the original message.
        if let existing = messageStore[conversationID]?.first(where: { $0.clientID == draft.clientID }) {
            return existing
        }
        // Like the server, an attachment is a copy of an uploaded photo.
        let attachment = draft.attachmentPhotoID.map { photoID in
            Message.Attachment(kind: .photo, url: attachments.removeValue(forKey: photoID) ?? me.photos.first { $0.id == photoID }?.url)
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
        return Boost(endsAt: Date.now.addingTimeInterval(3600))
    }

    #if DEBUG
    func debugGrantPlus() async throws {
        try await pause()
        plusExpiresAt = Date.now.addingTimeInterval(30 * 24 * 3600)
    }
    #endif

    private var currentPlusStatus: SubscriptionStatus {
        guard let plusExpiresAt, plusExpiresAt > .now else { return .inactive }
        return SubscriptionStatus(isActive: true, expiresAt: plusExpiresAt)
    }

    // MARK: Helpers

    private func pause() async throws {
        try await Task.sleep(for: latency)
    }

    private func makeID(_ prefix: String) -> String {
        defer { nextID += 1 }
        return "\(prefix)-\(nextID)-\(UUID().uuidString.prefix(8))"
    }
}
