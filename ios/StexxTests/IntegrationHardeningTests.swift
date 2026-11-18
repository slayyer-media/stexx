import Foundation
import Testing
@testable import Stexx

// MARK: - Realtime reconnect policy

struct ReconnectPolicyTests {
    @Test("The first 401 refreshes; more 401s back off without refreshing, then give up")
    func unauthorizedStreak() {
        var policy = ReconnectPolicy(maxUnauthorizedStreak: 3)
        #expect(policy.ended(.unauthorized, connectedFor: nil) == .refreshAndReconnect)
        #expect(policy.ended(.unauthorized, connectedFor: nil) == .backoff(attempt: 1))
        #expect(policy.ended(.unauthorized, connectedFor: nil) == .backoff(attempt: 2))
        #expect(policy.ended(.unauthorized, connectedFor: nil) == .giveUp)
    }

    @Test("A successful connection resets the 401 streak")
    func connectionResetsStreak() {
        var policy = ReconnectPolicy(maxUnauthorizedStreak: 3)
        #expect(policy.ended(.unauthorized, connectedFor: nil) == .refreshAndReconnect)
        // The refreshed token worked; much later the token expires again.
        #expect(policy.ended(.unauthorized, connectedFor: .seconds(3600)) == .refreshAndReconnect)
    }

    @Test("Short-lived connections keep growing the backoff; a stable one resets it")
    func shortConnectionsBackOff() {
        var policy = ReconnectPolicy(stableAfter: .seconds(30))
        // Accept, answer one ping, then a policy close: every ~1 s before.
        #expect(policy.ended(.closed, connectedFor: .milliseconds(200)) == .backoff(attempt: 1))
        #expect(policy.ended(.closed, connectedFor: .milliseconds(200)) == .backoff(attempt: 2))
        #expect(policy.ended(.closed, connectedFor: .milliseconds(200)) == .backoff(attempt: 3))
        #expect(policy.ended(.closed, connectedFor: .seconds(120)) == .backoff(attempt: 1))
    }

    @Test("A transient refresh failure backs off and lets the next 401 refresh again")
    func refreshFailureBacksOff() {
        var policy = ReconnectPolicy()
        #expect(policy.ended(.unauthorized, connectedFor: nil) == .refreshAndReconnect)
        #expect(policy.refreshFailed() == .backoff(attempt: 1))
        #expect(policy.ended(.unauthorized, connectedFor: nil) == .refreshAndReconnect)
        #expect(policy.refreshFailed() == .backoff(attempt: 2))
    }
}

@MainActor
struct RealtimeClientLifecycleTests {
    @Test("A run that ended on its own can be started again")
    func restartsAfterEnding() async throws {
        let store = InMemorySessionStore()
        let client = RealtimeClient(
            url: URL(string: "ws://127.0.0.1:9/v1/ws")!,
            sessions: SessionCoordinator(store: store),
            refresh: { _ in throw URLError(.notConnectedToInternet) }
        )
        // No session: the loop ends right away.
        client.start()
        #expect(client.isRunning)
        for _ in 0..<100 where client.isRunning {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!client.isRunning)
        #expect(client.state == .stopped)

        // Not a no-op any more.
        try store.save(Session(userID: "u1", accessToken: "a", refreshToken: "r", expiresAt: nil))
        client.start()
        #expect(client.isRunning)
        client.stop()
        #expect(!client.isRunning)
    }
}

// MARK: - Session coordinator

/// Lets a stubbed `/auth/refresh` wait until the test releases it.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

struct SessionCoordinatorTests {
    private let userA = Session(userID: "a", accessToken: "a-old", refreshToken: "a-r1", expiresAt: nil)
    private let userB = Session(userID: "b", accessToken: "b-1", refreshToken: "b-r1", expiresAt: nil)

    @Test("A refresh that finishes after sign-out doesn't resurrect the session")
    func refreshAfterSignOut() async throws {
        let store = InMemorySessionStore(session: userA)
        let log = CallLog()
        let coordinator = SessionCoordinator(store: store, hooks: APIClientHooks(
            sessionRefreshed: { _ in await log.record("refreshed") },
            sessionExpired: { await log.record("expired") }
        ))
        let gate = Gate()
        let rejected = userA
        let refresh = Task {
            try await coordinator.refreshedSession(rejecting: rejected) { _ in
                await gate.wait()
                return Session(userID: "a", accessToken: "a-new", refreshToken: "a-r2", expiresAt: nil)
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        store.clear() // Sign out while /auth/refresh is in flight.
        await gate.open()

        await #expect(throws: APIError.unauthorized) { try await refresh.value }
        #expect(store.load() == nil)
        #expect(await log.entries.isEmpty)
    }

    @Test("A refresh that finishes after another account signed in leaves that account alone")
    func refreshAfterAccountSwitch() async throws {
        let store = InMemorySessionStore(session: userA)
        let coordinator = SessionCoordinator(store: store)
        let gate = Gate()
        let rejected = userA
        let refresh = Task {
            try await coordinator.refreshedSession(rejecting: rejected) { _ in
                await gate.wait()
                return Session(userID: "a", accessToken: "a-new", refreshToken: "a-r2", expiresAt: nil)
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        try store.save(userB)
        await gate.open()

        await #expect(throws: APIError.unauthorized) { try await refresh.value }
        #expect(store.load() == userB)
    }

    @Test("A request made for one account is never retried with another's token")
    func noCrossAccountRetry() async throws {
        let store = InMemorySessionStore(session: userB)
        let log = CallLog()
        let coordinator = SessionCoordinator(store: store, hooks: APIClientHooks(sessionExpired: { await log.record("expired") }))

        await #expect(throws: APIError.unauthorized) {
            try await coordinator.refreshedSession(rejecting: userA) { _ in
                await log.record("refresh")
                return userA
            }
        }
        #expect(store.load() == userB)
        #expect(await log.entries.isEmpty)
    }

    @Test("A rejected refresh token for a session that's already gone doesn't sign anyone out")
    func rejectedAfterSwitch() async throws {
        let store = InMemorySessionStore(session: userA)
        let log = CallLog()
        let coordinator = SessionCoordinator(store: store, hooks: APIClientHooks(sessionExpired: { await log.record("expired") }))
        let gate = Gate()
        let rejected = userA
        let refresh = Task {
            try await coordinator.refreshedSession(rejecting: rejected) { _ in
                await gate.wait()
                throw APIError.unauthorized
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        try store.save(userB)
        await gate.open()

        await #expect(throws: APIError.unauthorized) { try await refresh.value }
        #expect(store.load() == userB)
        #expect(await log.entries.isEmpty)
    }

    @Test("An empty store signs the app out instead of failing forever")
    func emptyStoreExpires() async throws {
        let log = CallLog()
        let coordinator = SessionCoordinator(
            store: InMemorySessionStore(),
            hooks: APIClientHooks(sessionExpired: { await log.record("expired") })
        )
        await #expect(throws: APIError.unauthorized) {
            try await coordinator.refreshedSession(rejecting: nil) { _ in
                Issue.record("Nothing to refresh with")
                throw APIError.unauthorized
            }
        }
        #expect(await log.entries == ["expired"])
    }
}

/// A Keychain that refuses every write.
final class FailingSessionStore: SessionStore, @unchecked Sendable {
    struct Failure: Error {}
    func load() -> Session? { nil }
    func save(_ session: Session) throws { throw Failure() }
    func clear() {}
}

@MainActor
struct CachedSessionStoreTests {
    @Test("A failed Keychain write still leaves a usable session for this launch")
    func failedPersistence() async throws {
        let store = CachedSessionStore(backing: FailingSessionStore())
        let suite = "stexx.tests.\(UUID().uuidString)"
        let appState = AppState(defaults: UserDefaults(suiteName: suite)!, sessionStore: store)
        appState.confirmAge()
        appState.signIn(MockData.session)

        #expect(appState.isSignedIn)
        #expect(store.load() == MockData.session)
        #expect(await SessionCoordinator(store: store).accessToken() == MockData.session.accessToken)

        let rotated = Session(userID: MockData.session.userID, accessToken: "new", refreshToken: "r2", expiresAt: nil)
        #expect(store.replace(userID: MockData.session.userID, refreshToken: MockData.session.refreshToken ?? "", with: rotated))
        #expect(store.load() == rotated)

        appState.signOut()
        #expect(store.load() == nil)
    }
}

// MARK: - HTTP client

struct HTTPAPIClientHardeningTests {
    private func makeClient(baseURL: URL, store: any SessionStore = InMemorySessionStore()) -> HTTPAPIClient {
        HTTPAPIClient(
            configuration: APIConfiguration(baseURL: baseURL, useMock: false),
            session: StubURLProtocol.session(),
            sessions: SessionCoordinator(store: store)
        )
    }

    @Test("Logout with an expired access token rotates with the session's own refresh token, then revokes")
    func logoutRefreshesExpiredToken() async throws {
        let log = CallLog()
        let baseURL = StubURLProtocol.register { request in
            let auth = request.value(forHTTPHeaderField: "Authorization") ?? "-"
            await log.record("\(request.url?.path() ?? "") \(auth)")
            switch (request.url?.path(), auth) {
            case ("/v1/auth/refresh", _):
                return (200, [:], Fixtures.json(Fixtures.session("fresh", refresh: "r2")))
            case ("/v1/auth/logout", "Bearer fresh"):
                return (204, [:], Data())
            default:
                return (401, [:], Fixtures.error("unauthorized"))
            }
        }
        // The local session is already gone when logout runs.
        let store = InMemorySessionStore()
        let client = makeClient(baseURL: baseURL, store: store)
        let session = Session(userID: "u1", accessToken: "expired", refreshToken: "r1", expiresAt: nil)

        try await client.logout(session)
        #expect(await log.entries == [
            "/v1/auth/logout Bearer expired",
            "/v1/auth/refresh -",
            "/v1/auth/logout Bearer fresh",
        ])
        #expect(store.load() == nil)
    }

    @Test("Revocation retries network failures and treats invalid tokens as done")
    func revocationRetries() async throws {
        let log = CallLog()
        let baseURL = StubURLProtocol.register { request in
            await log.record(request.url?.path() ?? "")
            if await log.count("/v1/auth/logout") < 3 { throw URLError(.notConnectedToInternet) }
            return (204, [:], Data())
        }
        let client = makeClient(baseURL: baseURL)
        let session = Session(userID: "u1", accessToken: "a", refreshToken: "r1", expiresAt: nil)

        let revoked = await SessionRevocation.revoke(session, using: client, attempts: 4, delay: { _ in .milliseconds(1) })
        #expect(revoked)
        #expect(await log.count("/v1/auth/logout") == 3)

        let deadURL = StubURLProtocol.register { _ in (401, [:], Fixtures.error("unauthorized")) }
        #expect(await SessionRevocation.revoke(session, using: makeClient(baseURL: deadURL), delay: { _ in .zero }))
    }

    @Test("'+' in query values is percent-encoded so tags like C++ survive")
    func plusIsEncoded() async throws {
        let log = CallLog()
        let baseURL = StubURLProtocol.register { request in
            await log.record(request.url?.query(percentEncoded: true) ?? "")
            return (200, [:], Fixtures.json(["items": [], "nextCursor": NSNull()]))
        }
        let client = makeClient(baseURL: baseURL)
        _ = try await client.nearby(NearbyQuery(tags: ["C++", "a&b c"]))

        let query = try #require(await log.entries.first)
        #expect(query.contains("tag=C%2B%2B"))
        #expect(!query.contains("+"))
        let items = URLComponents(string: "https://x.test/?\(query)")?.queryItems ?? []
        #expect(items.filter { $0.name == "tag" }.compactMap(\.value) == ["C++", "a&b c"])
    }

    @Test("The API session never caches responses")
    func noResponseCache() {
        #expect(URLSession.stexxAPI.configuration.urlCache == nil)
        #expect(PrivateMedia.session.configuration.urlCache == nil)
        #expect(PrivateMedia.session.configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
    }
}

// MARK: - Chat

@MainActor
struct ChatStoreHardeningTests {
    nonisolated private static func conversationJSON(_ id: String) -> [String: Any] {
        ["id": id, "participant": Fixtures.profile, "lastMessage": NSNull(), "unreadCount": 0,
         "updatedAt": "2026-11-17T20:30:00Z", "isMuted": false]
    }

    private func makeStore(_ handler: @escaping StubURLProtocol.Handler, defaults: UserDefaults? = nil) -> ChatStore {
        let api = HTTPAPIClient(
            configuration: APIConfiguration(baseURL: StubURLProtocol.register(handler), useMock: false),
            session: StubURLProtocol.session(),
            sessions: SessionCoordinator(store: InMemorySessionStore(session: Session(userID: "u1", accessToken: "t", refreshToken: "r", expiresAt: nil)))
        )
        return ChatStore(api: api, defaults: defaults ?? UserDefaults(suiteName: "stexx.tests.\(UUID().uuidString)")!)
    }

    @Test("A load that returns after sign-out doesn't leak into the next account")
    func loadAfterReset() async throws {
        let store = makeStore { _ in
            try await Task.sleep(for: .milliseconds(200))
            return (200, [:], Fixtures.json([Self.conversationJSON("c-old")]))
        }
        let load = Task { await store.load() }
        try await Task.sleep(for: .milliseconds(50))
        store.reset()
        await load.value

        #expect(store.conversations.isEmpty)
        #expect(!store.hasLoaded)
        #expect(!store.isLoading)
    }

    @Test("The newest load wins over a slower older one")
    func newestLoadWins() async throws {
        let calls = CallLog()
        let store = makeStore { _ in
            await calls.record("get")
            if await calls.count("get") == 1 {
                try await Task.sleep(for: .milliseconds(200))
                return (200, [:], Fixtures.json([Self.conversationJSON("c-stale")]))
            }
            return (200, [:], Fixtures.json([Self.conversationJSON("c-fresh")]))
        }
        let first = Task { await store.load() }
        try await Task.sleep(for: .milliseconds(50))
        await store.load()
        #expect(!store.isLoading)
        await first.value

        #expect(store.conversations.map(\.id) == ["c-fresh"])
        #expect(!store.isLoading)
    }

    @Test("Chat photos go through the private attachment upload, never the profile")
    func privateAttachmentUpload() async throws {
        let log = CallLog()
        let defaults = UserDefaults(suiteName: "stexx.tests.\(UUID().uuidString)")!
        let sent = Message(id: "m1", conversationID: "c1", senderID: "u1", text: nil,
                           attachment: Message.Attachment(kind: .photo, url: nil), sentAt: .now,
                           status: .sent, expiresAt: nil, clientID: "client-1")
        let store = makeStore({ request in
            let path = request.url?.path() ?? ""
            await log.record("\(request.httpMethod ?? "") \(path)")
            switch (request.httpMethod, path) {
            case ("POST", "/v1/me/attachments"):
                return (201, [:], Fixtures.json(["id": "ph1", "url": "https://media.test/ph1.jpg", "isExplicit": false]))
            case ("POST", "/v1/conversations/c1/messages"):
                let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
                let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                #expect(json?["attachmentPhotoID"] as? String == "ph1")
                // Not expiring: explicitly not view-once.
                #expect(json?["isViewOnce"] as? Bool == false)
                return (201, [:], try JSONEncoder.stexx().encode(sent))
            default:
                return (404, [:], Fixtures.error("not_found"))
            }
        }, defaults: defaults)
        let conversation = Conversation(id: "c1", participant: MockData.profiles[0], lastMessage: nil, unreadCount: 0, updatedAt: .now)

        let message = try await store.sendPhoto(jpegData: Data([0xFF, 0xD8]), clientID: "client-1", expiresAfterSeconds: nil, in: conversation)
        #expect(message.id == "m1")
        #expect(await log.count("POST /v1/me/photos") == 0)
        #expect(await log.count("DELETE /v1/me/photos/ph1") == 0)
        #expect(await log.count("POST /v1/me/attachments") == 1)
    }

    @Test("With the mock, a chat photo never touches the profile")
    func mockAttachmentStaysOffProfile() async throws {
        let api = MockAPIClient(latency: .zero)
        let store = ChatStore(api: api, defaults: UserDefaults(suiteName: "stexx.tests.\(UUID().uuidString)")!)
        let conversation = try await api.openConversation(with: "p03")
        let before = try await api.fetchMe().photos

        let message = try await store.sendPhoto(jpegData: Data([0xFF, 0xD8, 0xFF]), clientID: "photo-x", expiresAfterSeconds: 60, in: conversation)
        #expect(message.attachment?.kind == .photo)
        #expect(try await api.fetchMe().photos == before)
    }

    @Test("isViewOnce is omitted unless set")
    func draftEncoding() throws {
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder.stexx().encode(MessageDraft(clientID: "c", text: "hi"))) as? [String: Any]
        #expect(plain?["isViewOnce"] == nil)
        let keep = try JSONSerialization.jsonObject(with: JSONEncoder.stexx().encode(MessageDraft(clientID: "c", attachmentPhotoID: "p", isViewOnce: false))) as? [String: Any]
        #expect(keep?["isViewOnce"] as? Bool == false)
    }

    private func message(_ id: String, at seconds: TimeInterval, from sender: Profile.ID = "p1", status: Message.Status = .delivered, clientID: String? = nil) -> Message {
        Message(id: id, conversationID: "c1", senderID: sender, text: id, attachment: nil,
                sentAt: Date(timeIntervalSince1970: 1_800_000_000 + seconds), status: status, expiresAt: nil, clientID: clientID)
    }

    @Test("Reconciling keeps live events and unsent messages, drops what the server no longer has")
    func reconcile() {
        let snapshot = [message("m1", at: 0), message("m2", at: 10), message("m3", at: 20, from: "me", status: .sent, clientID: "k3")]
        let local = [
            message("m0", at: -10),                                              // expired on the server
            message("m2", at: 10),                                               // in the snapshot
            message("local-k3", at: 19, from: "me", status: .sending, clientID: "k3"), // now confirmed
            message("m4", at: 25),                                               // arrived during the fetch
            message("local-k5", at: 5, from: "me", status: .failed, clientID: "k5"),   // unsent, keep
        ]
        let merged = ChatStore.reconcile(snapshot: snapshot, with: local, myID: "me")
        #expect(merged.map(\.id) == ["m1", "local-k5", "m2", "m3", "m4"])
    }

    @Test("Resync tells open threads to refetch")
    func resyncBroadcasts() async throws {
        let store = ChatStore(api: MockAPIClient(latency: .zero), defaults: UserDefaults(suiteName: "stexx.tests.\(UUID().uuidString)")!)
        let updates = store.threadUpdates(for: "c-p01")
        store.resync()
        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next() == .resync)
    }

    nonisolated private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

// MARK: - Profile photos

@MainActor
struct ProfilePhotoSyncTests {
    @Test("A photo added and removed in the same edit is deleted, and the reorder is a valid permutation")
    func orphanedUpload() async throws {
        let api = MockAPIClient(latency: .zero)
        let a = try await api.uploadPhoto(jpegData: Data([0xFF]))
        let b = try await api.uploadPhoto(jpegData: Data([0xFF]))
        let sync = ProfilePhotoSync(photos: [a, b])

        let x = try await api.uploadPhoto(jpegData: Data([0xFF]))
        sync.didUpload(x)
        // Removed x again, swapped a and b.
        let result = try await sync.apply([b, a], using: api)
        #expect(result.map(\.id) == [b.id, a.id])
        #expect(try await api.fetchMe().photos.map(\.id) == [b.id, a.id])
        #expect(sync.unsavedUploads.isEmpty)
    }

    @Test("Retrying after a partial failure doesn't re-delete photos already gone")
    func retryAfterPartialFailure() async throws {
        let api = MockAPIClient(latency: .zero)
        let a = try await api.uploadPhoto(jpegData: Data([0xFF]))
        let b = try await api.uploadPhoto(jpegData: Data([0xFF]))
        let c = try await api.uploadPhoto(jpegData: Data([0xFF]))
        let sync = ProfilePhotoSync(photos: [a, b, c])
        // An earlier attempt deleted a before failing.
        try await api.deletePhoto(id: a.id)

        let result = try await sync.apply([c], using: api)
        #expect(result.map(\.id) == [c.id])
        #expect(try await api.fetchMe().photos.map(\.id) == [c.id])
        // And again: nothing left to do, still fine.
        #expect(try await sync.apply([c], using: api).map(\.id) == [c.id])
    }

    @Test("Leaving without saving removes this edit's uploads only")
    func discardUploads() async throws {
        let api = MockAPIClient(latency: .zero)
        let a = try await api.uploadPhoto(jpegData: Data([0xFF]))
        let sync = ProfilePhotoSync(photos: [a])
        let x = try await api.uploadPhoto(jpegData: Data([0xFF]))
        sync.didUpload(x)

        await sync.discardUnsavedUploads(using: api)
        #expect(try await api.fetchMe().photos.map(\.id) == [a.id])
    }
}

// MARK: - Location

@MainActor
struct LocationResetTests {
    @Test("An upload in flight during sign-out doesn't suppress the next account's upload")
    func resetDuringUpload() async throws {
        let manager = FakeLocationManager(status: .authorizedWhenInUse)
        let gate = Gate()
        let log = CallLog()
        let service = LocationService(manager: manager) { location in
            await log.record("upload")
            if await log.count("upload") == 1 { await gate.wait() }
        }
        service.start()
        let reading = LocationReading(latitude: 52.52, longitude: 13.405)
        let stale = Task { await service.handle(reading) }
        try await Task.sleep(for: .milliseconds(50))

        service.reset()   // Sign out…
        service.start()   // …and someone else signs in at the same spot.
        await gate.open()
        await stale.value
        #expect(service.lastUploadedCell == nil)

        await service.handle(reading)
        #expect(await log.count("upload") == 2)
        #expect(service.lastUploadedCell != nil)
    }
}
