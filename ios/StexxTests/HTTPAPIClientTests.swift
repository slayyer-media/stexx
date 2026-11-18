import Foundation
import Testing
@testable import Stexx

/// Serves canned responses for requests to a test-specific host, so suites
/// can run in parallel without sharing state.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) async throws -> (Int, [String: String], Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]

    /// Registers `handler` for a fresh host and returns its base URL.
    static func register(_ handler: @escaping Handler) -> URL {
        let host = "stub-\(UUID().uuidString.prefix(8).lowercased()).test"
        lock.withLock { handlers[host] = handler }
        return URL(string: "https://\(host)")!
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private var loadingTask: Task<Void, Never>?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = request
        let handler = Self.lock.withLock { Self.handlers[request.url?.host() ?? ""] }
        loadingTask = Task {
            do {
                guard let handler, let url = request.url else { throw URLError(.cannotFindHost) }
                let (status, headers, data) = try await handler(request)
                let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {
        loadingTask?.cancel()
    }
}

/// Thread-safe call log for stubs and hooks.
actor CallLog {
    private(set) var entries: [String] = []
    func record(_ entry: String) { entries.append(entry) }
    func count(_ entry: String) -> Int { entries.filter { $0 == entry }.count }
}

enum Fixtures {
    static func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    static func session(_ access: String, refresh: String) -> [String: Any] {
        ["userID": "u1", "accessToken": access, "refreshToken": refresh, "expiresAt": "2026-11-18T10:00:00Z"]
    }

    static var profile: [String: Any] { [
        "id": "u1", "displayName": "Tester", "age": NSNull(), "pronouns": NSNull(), "headline": NSNull(),
        "about": NSNull(), "heightCm": NSNull(), "position": NSNull(), "lookingFor": [], "tags": [],
        "photos": [], "distanceMeters": NSNull(), "isOnline": true,
        "lastActiveAt": "2026-11-17T20:30:00.123Z", "isFavorite": false,
    ] }

    static func error(_ code: String) -> Data {
        json(["code": code, "message": "nope"])
    }
}

struct HTTPAPIClientTests {
    private func makeClient(
        baseURL: URL,
        store: any SessionStore,
        hooks: APIClientHooks = APIClientHooks()
    ) -> HTTPAPIClient {
        HTTPAPIClient(
            configuration: APIConfiguration(baseURL: baseURL, useMock: false),
            session: StubURLProtocol.session(),
            sessions: SessionCoordinator(store: store, hooks: hooks),
            hooks: hooks
        )
    }

    @Test("Concurrent 401s refresh once, persist the rotated session and retry")
    func singleFlightRefresh() async throws {
        let log = CallLog()
        let baseURL = StubURLProtocol.register { request in
            let auth = request.value(forHTTPHeaderField: "Authorization")
            switch request.url?.path() {
            case "/v1/auth/refresh":
                await log.record("refresh")
                #expect(auth == nil)
                // Slow enough that every request piles up behind it.
                try await Task.sleep(for: .milliseconds(150))
                return (200, [:], Fixtures.json(Fixtures.session("new", refresh: "r2")))
            case "/v1/me":
                await log.record("me \(auth ?? "-")")
                return auth == "Bearer new"
                    ? (200, [:], Fixtures.json(Fixtures.profile))
                    : (401, [:], Fixtures.error("unauthorized"))
            default:
                return (404, [:], Fixtures.error("not_found"))
            }
        }
        let store = InMemorySessionStore(session: Session(userID: "u1", accessToken: "old", refreshToken: "r1", expiresAt: nil))
        let hookLog = CallLog()
        let hooks = APIClientHooks(
            sessionRefreshed: { session in await hookLog.record("refreshed \(session.accessToken)") },
            sessionExpired: { await hookLog.record("expired") }
        )
        let client = makeClient(baseURL: baseURL, store: store, hooks: hooks)

        try await withThrowingTaskGroup(of: Profile.self) { group in
            for _ in 0..<6 {
                group.addTask { try await client.fetchMe() }
            }
            for try await profile in group {
                #expect(profile.id == "u1")
                // Fractional seconds decode too.
                #expect(profile.lastActiveAt != nil)
            }
        }

        #expect(await log.count("refresh") == 1)
        #expect(await log.count("me Bearer new") == 6)
        #expect(store.load()?.accessToken == "new")
        #expect(store.load()?.refreshToken == "r2")
        #expect(await hookLog.entries == ["refreshed new"])
    }

    @Test("A rejected refresh token clears the session and signs out")
    func refreshRejected() async throws {
        let log = CallLog()
        let baseURL = StubURLProtocol.register { request in
            if request.url?.path() == "/v1/auth/refresh" {
                await log.record("refresh")
                return (401, [:], Fixtures.error("unauthorized"))
            }
            return (401, [:], Fixtures.error("unauthorized"))
        }
        let store = InMemorySessionStore(session: Session(userID: "u1", accessToken: "old", refreshToken: "r1", expiresAt: nil))
        let hookLog = CallLog()
        let client = makeClient(baseURL: baseURL, store: store, hooks: APIClientHooks(sessionExpired: { await hookLog.record("expired") }))

        await #expect(throws: APIError.unauthorized) {
            try await client.conversations()
        }
        #expect(store.load() == nil)
        #expect(await log.count("refresh") == 1)
        #expect(await hookLog.entries == ["expired"])
    }

    @Test("The retried request is sent only once even if it fails again")
    func retriesOnlyOnce() async throws {
        let log = CallLog()
        let baseURL = StubURLProtocol.register { request in
            if request.url?.path() == "/v1/auth/refresh" {
                return (200, [:], Fixtures.json(Fixtures.session("new", refresh: "r2")))
            }
            await log.record("blocks")
            return (401, [:], Fixtures.error("unauthorized"))
        }
        let store = InMemorySessionStore(session: Session(userID: "u1", accessToken: "old", refreshToken: "r1", expiresAt: nil))
        let client = makeClient(baseURL: baseURL, store: store)

        await #expect(throws: APIError.unauthorized) {
            try await client.blockedProfiles()
        }
        #expect(await log.count("blocks") == 2)
    }

    @Test("Network errors during refresh don't sign the user out")
    func refreshNetworkError() async throws {
        let baseURL = StubURLProtocol.register { request in
            if request.url?.path() == "/v1/auth/refresh" { throw URLError(.notConnectedToInternet) }
            return (401, [:], Fixtures.error("unauthorized"))
        }
        let session = Session(userID: "u1", accessToken: "old", refreshToken: "r1", expiresAt: nil)
        let store = InMemorySessionStore(session: session)
        let client = makeClient(baseURL: baseURL, store: store)

        await #expect(throws: URLError.self) {
            try await client.fetchMe()
        }
        #expect(store.load() == session)
    }

    @Test("Logout uses the given session, never the stored one")
    func logoutUsesGivenSession() async throws {
        let log = CallLog()
        let baseURL = StubURLProtocol.register { request in
            await log.record("\(request.url?.path() ?? "") \(request.value(forHTTPHeaderField: "Authorization") ?? "-")")
            return (401, [:], Fixtures.error("unauthorized"))
        }
        let store = InMemorySessionStore()
        let client = makeClient(baseURL: baseURL, store: store)
        let session = Session(userID: "u1", accessToken: "gone", refreshToken: "r1", expiresAt: nil)

        // Access and refresh token both rejected: nothing left to revoke.
        await #expect(throws: APIError.unauthorized) {
            try await client.logout(session)
        }
        #expect(await log.entries == ["/v1/auth/logout Bearer gone", "/v1/auth/refresh -"])
        #expect(store.load() == nil)
    }

    @Test("429 surfaces rateLimited with Retry-After")
    func rateLimited() async throws {
        let baseURL = StubURLProtocol.register { _ in
            (429, ["Retry-After": "7"], Fixtures.error("rate_limited"))
        }
        let client = makeClient(baseURL: baseURL, store: InMemorySessionStore())
        await #expect(throws: APIError.rateLimited(retryAfter: 7)) {
            try await client.sendTap(to: "p1")
        }
    }

    @Test("Retry-After accepts seconds and HTTP dates")
    func retryAfterParsing() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(HTTPAPIClient.retryAfter("120", now: now) == 120)
        #expect(HTTPAPIClient.retryAfter(nil, now: now) == nil)
        #expect(HTTPAPIClient.retryAfter("soon", now: now) == nil)
        let later = now.addingTimeInterval(30)
        let header = later.formatted(
            Date.VerbatimFormatStyle(
                format: "\(weekday: .abbreviated), \(day: .twoDigits) \(month: .abbreviated) \(year: .defaultDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits) GMT",
                locale: Locale(identifier: "en_US_POSIX"),
                timeZone: TimeZone(identifier: "GMT")!,
                calendar: Calendar(identifier: .gregorian)
            )
        )
        #expect(HTTPAPIClient.retryAfter(header, now: now) == 30)
    }

    @Test("Travel mode off sends a JSON null body")
    func travelOffSendsNull() async throws {
        let log = CallLog()
        let baseURL = StubURLProtocol.register { request in
            let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
            await log.record(String(decoding: body, as: UTF8.self))
            return (204, [:], Data())
        }
        let client = makeClient(baseURL: baseURL, store: InMemorySessionStore())
        try await client.setTravelLocation(nil)
        #expect(await log.entries == ["null"])
    }

    private static func read(_ stream: InputStream) -> Data {
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

@MainActor
struct PlusGatingTests {
    @Test("402 requires_plus drops Plus, turns incognito off and opens the paywall")
    func requiresPlusOpensPaywall() async throws {
        let baseURL = StubURLProtocol.register { _ in
            (402, [:], Fixtures.error("requires_plus"))
        }
        let suite = "stexx.tests.\(UUID().uuidString)"
        let appState = AppState(defaults: UserDefaults(suiteName: suite)!, sessionStore: InMemorySessionStore())
        appState.applySubscription(SubscriptionStatus(isActive: true, expiresAt: .distantFuture))
        appState.privacy.incognito = true

        let hooks = APIClientHooks(requiresPlus: { await appState.handleRequiresPlus() })
        let client = HTTPAPIClient(
            configuration: APIConfiguration(baseURL: baseURL, useMock: false),
            session: StubURLProtocol.session(),
            sessions: SessionCoordinator(store: InMemorySessionStore(), hooks: hooks),
            hooks: hooks
        )

        await #expect(throws: APIError.requiresPlus) {
            try await client.viewers()
        }
        #expect(!appState.hasPlus)
        #expect(appState.plusExpiresAt == nil)
        #expect(!appState.privacy.incognito)
        #expect(appState.isPaywallPresented)
    }

    @Test("Entitlement comes from the server status")
    func subscriptionStatusDrivesHasPlus() async throws {
        let api = MockAPIClient(latency: .zero)
        let suite = "stexx.tests.\(UUID().uuidString)"
        let appState = AppState(defaults: UserDefaults(suiteName: suite)!, sessionStore: InMemorySessionStore())
        appState.confirmAge()
        appState.signIn(MockData.session)
        let purchases = PurchaseService(api: api, appState: appState)

        await purchases.refreshEntitlement()
        #expect(!appState.hasPlus)

        _ = try await api.submitAppleTransaction(signedTransaction: "jws")
        await purchases.refreshEntitlement()
        #expect(appState.hasPlus)
        #expect(appState.plusExpiresAt != nil)
    }

    @Test("Expired sessions sign out but keep onboarding")
    func sessionExpiry() {
        let suite = "stexx.tests.\(UUID().uuidString)"
        let appState = AppState(defaults: UserDefaults(suiteName: suite)!, sessionStore: InMemorySessionStore())
        appState.confirmAge()
        appState.signIn(MockData.session)
        appState.hasPlus = true
        var revoked: [Session] = []
        appState.revokeSession = { revoked.append($0) }

        appState.sessionDidExpire()
        #expect(!appState.isSignedIn)
        #expect(appState.isAgeConfirmed)
        #expect(!appState.hasPlus)
        // The server already rejected it; nothing to revoke.
        #expect(revoked.isEmpty)
    }

    @Test("Signing out revokes the session on the server")
    func signOutRevokes() {
        let suite = "stexx.tests.\(UUID().uuidString)"
        let appState = AppState(defaults: UserDefaults(suiteName: suite)!, sessionStore: InMemorySessionStore())
        appState.confirmAge()
        appState.signIn(MockData.session)
        var revoked: [Session] = []
        appState.revokeSession = { revoked.append($0) }

        appState.signOut()
        #expect(revoked == [MockData.session])
        #expect(!appState.isSignedIn)
    }
}
