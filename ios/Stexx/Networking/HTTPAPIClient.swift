import Foundation

/// Live client for the Stexx REST API (`docs/api.md`): JSON over HTTP(S)
/// with a bearer token.
///
/// - On 401 it refreshes the session once via `/auth/refresh` (single flight
///   across concurrent requests, see `SessionCoordinator`), stores the
///   rotated session and retries the original request once. If the refresh
///   token is rejected the session is cleared and `hooks.sessionExpired` runs.
/// - 402 maps to `APIError.requiresPlus` and runs `hooks.requiresPlus`.
/// - 429 maps to `APIError.rateLimited(retryAfter:)` from `Retry-After`.
/// - Sign-up, sign-in, sending messages, photo uploads and account deletion
///   carry device attestation headers from `attestation` (see
///   `AttestationService`). A 403 `attestation_key_unknown` drops the key
///   and retries once with a freshly attested one.
struct HTTPAPIClient: APIClient {
    let configuration: APIConfiguration
    let session: URLSession
    let sessions: SessionCoordinator
    let hooks: APIClientHooks
    let attestation: (any RequestAttesting)?

    init(
        configuration: APIConfiguration,
        session: URLSession = .stexxAPI,
        sessions: SessionCoordinator,
        hooks: APIClientHooks = APIClientHooks(),
        attestation: (any RequestAttesting)? = nil
    ) {
        self.configuration = configuration
        self.session = session
        self.sessions = sessions
        self.hooks = hooks
        self.attestation = attestation
    }

    // MARK: Auth & account

    func register(_ request: RegistrationRequest) async throws -> Session {
        try await call("POST", "auth/register", body: request, auth: .none)
    }

    func requestEmailLink(email: String) async throws {
        struct Body: Encodable { let email: String }
        try await callVoid("POST", "auth/email/link", body: Body(email: email), auth: .none)
    }

    func verifyEmailLink(token: String) async throws -> Session {
        struct Body: Encodable { let token: String }
        return try await call("POST", "auth/email/verify", body: Body(token: token), auth: .none)
    }

    func refreshSession(refreshToken: String) async throws -> Session {
        struct Body: Encodable { let refreshToken: String }
        return try await call("POST", "auth/refresh", body: Body(refreshToken: refreshToken), auth: .none)
    }

    /// Revokes `session`'s token family. Runs after the local session is
    /// already cleared, so it never touches the store: if the access token
    /// has expired (likely after the app sat idle) it rotates with the
    /// session's own refresh token and revokes the new pair instead.
    func logout(_ session: Session) async throws {
        do {
            try await callVoid("POST", "auth/logout", auth: .explicit(session.accessToken))
        } catch APIError.unauthorized {
            guard let refreshToken = session.refreshToken else { throw APIError.unauthorized }
            let fresh = try await refreshSession(refreshToken: refreshToken)
            try await callVoid("POST", "auth/logout", auth: .explicit(fresh.accessToken))
        }
    }

    func deleteAccount() async throws {
        try await callVoid("DELETE", "me")
    }

    // MARK: Me

    func fetchMe() async throws -> Profile {
        try await call("GET", "me")
    }

    func updateMe(_ update: ProfileUpdate) async throws -> Profile {
        try await call("PATCH", "me", body: update)
    }

    func uploadPhoto(jpegData: Data) async throws -> Photo {
        let data = try await exchange("POST", "me/photos", body: .raw(jpegData, contentType: "image/jpeg"))
        return try decode(Photo.self, from: data)
    }

    func uploadAttachment(jpegData: Data) async throws -> Photo {
        let data = try await exchange("POST", "me/attachments", body: .raw(jpegData, contentType: "image/jpeg"))
        return try decode(Photo.self, from: data)
    }

    func deletePhoto(id: Photo.ID) async throws {
        try await callVoid("DELETE", "me/photos/\(id)")
    }

    func reorderPhotos(_ photoIDs: [Photo.ID]) async throws -> [Photo] {
        struct Body: Encodable { let photoIDs: [Photo.ID] }
        return try await call("PUT", "me/photos/order", body: Body(photoIDs: photoIDs))
    }

    func updatePrivacy(_ settings: PrivacySettings) async throws -> PrivacySettings {
        try await call("PUT", "me/privacy", body: settings)
    }

    func updateLocation(_ location: FuzzedLocation) async throws {
        try await callVoid("PUT", "me/location", body: location)
    }

    func exportData() async throws -> Data {
        try await exchange("GET", "me/export")
    }

    // MARK: Discovery

    func nearby(_ query: NearbyQuery) async throws -> Page<Profile> {
        var items: [URLQueryItem] = [URLQueryItem(name: "limit", value: String(query.limit))]
        if query.onlineOnly { items.append(URLQueryItem(name: "onlineOnly", value: "true")) }
        if query.favoritesOnly { items.append(URLQueryItem(name: "favoritesOnly", value: "true")) }
        for value in query.lookingFor.map(\.rawValue).sorted() {
            items.append(URLQueryItem(name: "lookingFor", value: value))
        }
        if let minAge = query.minAge { items.append(URLQueryItem(name: "minAge", value: String(minAge))) }
        if let maxAge = query.maxAge { items.append(URLQueryItem(name: "maxAge", value: String(maxAge))) }
        if let maxDistance = query.maxDistanceMeters {
            items.append(URLQueryItem(name: "maxDistanceMeters", value: String(Int(maxDistance))))
        }
        for value in query.positions.map(\.rawValue).sorted() {
            items.append(URLQueryItem(name: "position", value: value))
        }
        for tag in query.tags { items.append(URLQueryItem(name: "tag", value: tag)) }
        if let cursor = query.cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await call("GET", "nearby", query: items)
    }

    func profile(id: Profile.ID) async throws -> Profile {
        try await call("GET", "profiles/\(id)")
    }

    func setFavorite(_ isFavorite: Bool, profileID: Profile.ID) async throws {
        try await callVoid(isFavorite ? "PUT" : "DELETE", "profiles/\(profileID)/favorite")
    }

    func sendTap(to profileID: Profile.ID) async throws {
        try await callVoid("POST", "profiles/\(profileID)/tap")
    }

    func viewers() async throws -> [Profile] {
        try await call("GET", "me/viewers")
    }

    // MARK: Chat

    func conversations() async throws -> [Conversation] {
        try await call("GET", "conversations")
    }

    func openConversation(with profileID: Profile.ID) async throws -> Conversation {
        struct Body: Encodable { let participantID: Profile.ID }
        return try await call("POST", "conversations", body: Body(participantID: profileID))
    }

    func messages(in conversationID: Conversation.ID, before: Message.ID?) async throws -> Page<Message> {
        var items = [URLQueryItem(name: "limit", value: "50")]
        if let before { items.append(URLQueryItem(name: "before", value: before)) }
        return try await call("GET", "conversations/\(conversationID)/messages", query: items)
    }

    func send(_ draft: MessageDraft, in conversationID: Conversation.ID) async throws -> Message {
        try await call("POST", "conversations/\(conversationID)/messages", body: draft)
    }

    func markRead(conversationID: Conversation.ID) async throws {
        try await callVoid("POST", "conversations/\(conversationID)/read")
    }

    func deleteConversation(_ conversationID: Conversation.ID) async throws {
        try await callVoid("DELETE", "conversations/\(conversationID)")
    }

    // MARK: End-to-end encryption

    func e2eConfig() async throws -> E2EConfig {
        try await call("GET", "e2e/config")
    }

    func registerKeys(_ registration: KeyRegistration) async throws -> KeyStatus {
        try await call("PUT", "keys", body: registration)
    }

    func keyStatus() async throws -> KeyStatus {
        try await call("GET", "keys/status")
    }

    func uploadPreKeys(_ replenishment: PreKeyReplenishment) async throws -> KeyStatus {
        try await call("POST", "keys/prekeys", body: replenishment)
    }

    func rotateSignedPreKeys(_ rotation: SignedPreKeyRotation) async throws -> KeyStatus {
        try await call("PUT", "keys/signed", body: rotation)
    }

    func preKeyBundle(for profileID: Profile.ID) async throws -> PreKeyBundleResponse {
        try await call("GET", "keys/bundle/\(profileID)")
    }

    func identityKey(for profileID: Profile.ID) async throws -> IdentityKeyResponse {
        try await call("GET", "keys/identity/\(profileID)")
    }

    // MARK: Safety

    func block(profileID: Profile.ID) async throws {
        try await callVoid("PUT", "blocks/\(profileID)")
    }

    func unblock(profileID: Profile.ID) async throws {
        try await callVoid("DELETE", "blocks/\(profileID)")
    }

    func blockedProfiles() async throws -> [Profile] {
        try await call("GET", "blocks")
    }

    func report(_ report: ReportRequest) async throws {
        try await callVoid("POST", "reports", body: report)
    }

    // MARK: Stexx+

    func subscriptionStatus() async throws -> SubscriptionStatus {
        try await call("GET", "subscriptions/status")
    }

    func submitAppleTransaction(signedTransaction: String) async throws -> SubscriptionStatus {
        try await call(
            "POST",
            "subscriptions/apple",
            body: AppleTransactionSubmission(signedTransaction: signedTransaction)
        )
    }

    func setTravelLocation(_ location: FuzzedLocation?) async throws {
        /// Encodes the location, or a JSON `null` to turn travel mode off.
        struct Body: Encodable {
            let location: FuzzedLocation?
            func encode(to encoder: any Encoder) throws {
                var container = encoder.singleValueContainer()
                if let location { try container.encode(location) } else { try container.encodeNil() }
            }
        }
        try await callVoid("PUT", "me/travel", body: Body(location: location))
    }

    func startBoost() async throws -> Boost {
        try await call("POST", "boosts")
    }

    #if DEBUG
    func debugGrantPlus() async throws {
        try await callVoid("POST", "dev/plus", body: [String: String]())
    }
    #endif

    // MARK: - Plumbing

    enum Auth: Sendable {
        /// Current session's access token; refresh and retry once on 401.
        case session
        /// This exact token; no refresh through the store (used for logout).
        case explicit(String)
        case none
    }

    enum Body: Sendable {
        case json(Data)
        case raw(Data, contentType: String)
    }

    private func call<Response: Decodable>(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: (any Encodable)? = nil,
        auth: Auth = .session
    ) async throws -> Response {
        let data = try await exchange(method, path, query: query, body: body.map { try .json(JSONEncoder.stexx().encode($0)) }, auth: auth)
        return try decode(Response.self, from: data)
    }

    private func callVoid(
        _ method: String,
        _ path: String,
        body: (any Encodable)? = nil,
        auth: Auth = .session
    ) async throws {
        _ = try await exchange(method, path, body: body.map { try .json(JSONEncoder.stexx().encode($0)) }, auth: auth)
    }

    private func decode<Response: Decodable>(_ type: Response.Type, from data: Data) throws -> Response {
        do {
            return try JSONDecoder.stexx().decode(Response.self, from: data)
        } catch {
            throw APIError.invalidResponse
        }
    }

    /// Sends a request; on 401 with the session token, refreshes once and
    /// retries once with the new token.
    private func exchange(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: Body? = nil,
        auth: Auth = .session
    ) async throws -> Data {
        switch auth {
        case .none:
            return try await send(method, path, query: query, body: body, token: nil)
        case .explicit(let token):
            return try await send(method, path, query: query, body: body, token: token)
        case .session:
            let current = await sessions.currentSession
            do {
                return try await send(method, path, query: query, body: body, token: current?.accessToken)
            } catch APIError.unauthorized {
                let client = self
                let fresh = try await sessions.refreshedSession(rejecting: current) { refreshToken in
                    try await client.refreshSession(refreshToken: refreshToken)
                }
                return try await send(method, path, query: query, body: body, token: fresh.accessToken)
            }
        }
    }

    /// Builds, attests (for protected routes) and performs one request. If
    /// the server has forgotten our App Attest key, re-attests once.
    private func send(
        _ method: String,
        _ path: String,
        query: [URLQueryItem],
        body: Body?,
        token: String?
    ) async throws -> Data {
        let request = makeRequest(method, path, query: query, body: body, token: token)
        guard let attestation, let kind = Self.attestedRoute(method, path) else {
            return try await perform(request)
        }
        do {
            return try await perform(attested(request, by: attestation, kind: kind))
        } catch AttestationKeyRejected.rejected {
            await attestation.resetKey()
            do {
                return try await perform(attested(request, by: attestation, kind: kind))
            } catch AttestationKeyRejected.rejected {
                throw APIError.server(status: 403, message: String(localized: "We couldn't verify this device. Please try again."))
            }
        }
    }

    private func attested(_ request: URLRequest, by attestation: any RequestAttesting, kind: AttestedRoute) async -> URLRequest {
        var request = request
        let headers = await attestation.headers(
            method: request.httpMethod ?? "GET",
            path: request.url?.path(percentEncoded: true) ?? "",
            body: request.httpBody,
            includeDeviceToken: kind == .account
        )
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    enum AttestedRoute: Equatable {
        /// Sign-up, sign-in, account deletion: also sends a DeviceCheck token.
        case account
        /// Messages and photo uploads.
        case content
    }

    /// Routes the server protects with device attestation (mirrors the
    /// `attest(...)` middleware in `server/src/routes`).
    static func attestedRoute(_ method: String, _ path: String) -> AttestedRoute? {
        switch (method, path) {
        case ("POST", "auth/register"), ("POST", "auth/email/link"), ("POST", "auth/email/verify"),
             ("POST", "auth/passkey/register/finish"), ("POST", "auth/passkey/login/finish"), ("DELETE", "me"):
            return .account
        case ("POST", "me/photos"), ("POST", "me/attachments"):
            return .content
        case ("POST", _) where path.hasPrefix("conversations/") && path.hasSuffix("/messages"):
            return .content
        // E2E key registration and bundle fetches (`attest("message")`).
        case ("PUT", "keys"):
            return .content
        case ("GET", _) where path.hasPrefix("keys/bundle/"):
            return .content
        default:
            return nil
        }
    }

    private enum AttestationKeyRejected: Error { case rejected }

    private func makeRequest(
        _ method: String,
        _ path: String,
        query: [URLQueryItem],
        body: Body?,
        token: String?
    ) -> URLRequest {
        let url = Self.url(
            configuration.baseURL.appending(path: configuration.apiVersion).appending(path: path),
            query: query
        )

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch body {
        case .json(let data):
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = data
        case .raw(let data, let contentType):
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            request.httpBody = data
        case nil:
            break
        }
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Appends `query` to `url`, percent-encoding `+` too: Foundation
    /// leaves it literal, and form-style parsers (the server's) read a
    /// literal `+` as a space, so a `C++` tag would arrive as `C  `.
    static func url(_ url: URL, query: [URLQueryItem]) -> URL {
        guard !query.isEmpty else { return url }
        var url = url
        url.append(queryItems: query)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let encoded = components.percentEncodedQuery, encoded.contains("+")
        else { return url }
        components.percentEncodedQuery = encoded.replacingOccurrences(of: "+", with: "%2B")
        return components.url ?? url
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401:
            throw APIError.unauthorized
        case 402:
            await hooks.requiresPlus()
            throw APIError.requiresPlus
        case 404:
            // `keys_unavailable` / `e2e_disabled` decide between encrypting
            // and plaintext; every other 404 is a plain "not found".
            if let body = try? JSONDecoder.stexx().decode(ErrorBody.self, from: data),
               let code = body.code, E2EErrorCode.all.contains(code) {
                throw APIError.e2e(code: code, message: body.message)
            }
            throw APIError.notFound
        case 429:
            throw APIError.rateLimited(retryAfter: Self.retryAfter(http.value(forHTTPHeaderField: "Retry-After")))
        default:
            let body = try? JSONDecoder.stexx().decode(ErrorBody.self, from: data)
            if http.statusCode == 403, body?.code == "attestation_key_unknown" { throw AttestationKeyRejected.rejected }
            if let code = body?.code, E2EErrorCode.all.contains(code) {
                throw APIError.e2e(code: code, message: body?.message)
            }
            // 403 anti-spam codes (new_account_limit, links_not_allowed, duplicate_message, device_account_limit,
            // disposable_email, ...) carry a message written for people; it is shown as is.
            throw APIError.server(status: http.statusCode, message: body?.message)
        }
    }

    /// `Retry-After` is either delta-seconds or an HTTP date.
    static func retryAfter(_ header: String?, now: Date = .now) -> TimeInterval? {
        guard let header = header?.trimmingCharacters(in: .whitespaces), !header.isEmpty else { return nil }
        if let seconds = TimeInterval(header) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: header) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }

    private struct ErrorBody: Decodable {
        let code: String?
        let message: String?
    }
}
