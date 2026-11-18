import Foundation

/// Live client for the Stexx REST API (`docs/api.md`). Thin by design: JSON
/// over HTTPS with a bearer token. Token refresh, retries and the realtime
/// WebSocket are still TODO.
struct HTTPAPIClient: APIClient {
    let configuration: APIConfiguration
    var session: URLSession = .shared
    /// Supplies the current access token, if any.
    let accessToken: @Sendable () async -> String?

    init(
        configuration: APIConfiguration,
        session: URLSession = .shared,
        accessToken: @escaping @Sendable () async -> String?
    ) {
        self.configuration = configuration
        self.session = session
        self.accessToken = accessToken
    }

    // MARK: Auth & account

    func register(_ request: RegistrationRequest) async throws -> Session {
        try await call("POST", "auth/register", body: request, authenticated: false)
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
        var request = try await makeRequest("POST", "me/photos")
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.httpBody = jpegData
        return try JSONDecoder.stexx().decode(Photo.self, from: try await perform(request))
    }

    func updatePrivacy(_ settings: PrivacySettings) async throws -> PrivacySettings {
        try await call("PUT", "me/privacy", body: settings)
    }

    func updateLocation(_ location: FuzzedLocation) async throws {
        try await callVoid("PUT", "me/location", body: location)
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

    // MARK: - Plumbing

    private func call<Response: Decodable>(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: (any Encodable)? = nil,
        authenticated: Bool = true
    ) async throws -> Response {
        let data = try await perform(makeRequest(method, path, query: query, body: body, authenticated: authenticated))
        do {
            return try JSONDecoder.stexx().decode(Response.self, from: data)
        } catch {
            throw APIError.invalidResponse
        }
    }

    private func callVoid(
        _ method: String,
        _ path: String,
        body: (any Encodable)? = nil
    ) async throws {
        _ = try await perform(makeRequest(method, path, body: body))
    }

    private func makeRequest(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: (any Encodable)? = nil,
        authenticated: Bool = true
    ) async throws -> URLRequest {
        var url = configuration.baseURL
            .appending(path: configuration.apiVersion)
            .appending(path: path)
        if !query.isEmpty {
            url.append(queryItems: query)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder.stexx().encode(body)
        }
        if authenticated, let token = await accessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
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
            throw APIError.requiresPlus
        case 404:
            throw APIError.notFound
        case 429:
            throw APIError.rateLimited
        default:
            let message = (try? JSONDecoder.stexx().decode(ErrorBody.self, from: data))?.message
            throw APIError.server(status: http.statusCode, message: message)
        }
    }

    private struct ErrorBody: Decodable {
        let code: String?
        let message: String?
    }
}
