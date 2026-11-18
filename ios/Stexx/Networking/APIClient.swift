import Foundation
import SwiftUI

/// Everything the app needs from the Stexx backend. The UI only talks to
/// this protocol, so the mock and the real HTTP client are interchangeable.
/// See `docs/api.md` for the wire format.
protocol APIClient: Sendable {
    // MARK: Auth & account
    func register(_ request: RegistrationRequest) async throws -> Session
    /// Sends a one-time sign-in link. Succeeds whether or not the address exists.
    func requestEmailLink(email: String) async throws
    /// Exchanges the token from a sign-in link for a session.
    func verifyEmailLink(token: String) async throws -> Session
    /// Rotates the refresh token. `HTTPAPIClient` calls this itself on 401.
    func refreshSession(refreshToken: String) async throws -> Session
    /// Revokes `session` on the server. Never reads or writes the stored
    /// session; if its access token expired, the live client rotates it
    /// with `session.refreshToken` and revokes the result.
    func logout(_ session: Session) async throws
    func deleteAccount() async throws

    // MARK: Me
    func fetchMe() async throws -> Profile
    func updateMe(_ update: ProfileUpdate) async throws -> Profile
    /// Uploads a JPEG that has already had its metadata stripped.
    func uploadPhoto(jpegData: Data) async throws -> Photo
    func deletePhoto(id: Photo.ID) async throws
    /// Private upload for a chat photo (`POST /me/attachments`). Never on
    /// the profile and not counted in its 6 photos; pass the returned ID as
    /// `attachmentPhotoID`. The server deletes it if it is never sent.
    func uploadAttachment(jpegData: Data) async throws -> Photo
    /// Sets the profile photo order; returns the photos in their new order.
    func reorderPhotos(_ photoIDs: [Photo.ID]) async throws -> [Photo]
    func updatePrivacy(_ settings: PrivacySettings) async throws -> PrivacySettings
    func updateLocation(_ location: FuzzedLocation) async throws
    /// GDPR data export, returned as the raw JSON archive.
    func exportData() async throws -> Data

    // MARK: Discovery
    func nearby(_ query: NearbyQuery) async throws -> Page<Profile>
    func profile(id: Profile.ID) async throws -> Profile
    func setFavorite(_ isFavorite: Bool, profileID: Profile.ID) async throws
    func sendTap(to profileID: Profile.ID) async throws
    /// Stexx+: who viewed your profile recently.
    func viewers() async throws -> [Profile]

    // MARK: Chat
    func conversations() async throws -> [Conversation]
    func openConversation(with profileID: Profile.ID) async throws -> Conversation
    func messages(in conversationID: Conversation.ID, before: Message.ID?) async throws -> Page<Message>
    func send(_ draft: MessageDraft, in conversationID: Conversation.ID) async throws -> Message
    func markRead(conversationID: Conversation.ID) async throws
    func deleteConversation(_ conversationID: Conversation.ID) async throws

    // MARK: Safety (always free)
    func block(profileID: Profile.ID) async throws
    func unblock(profileID: Profile.ID) async throws
    func blockedProfiles() async throws -> [Profile]
    func report(_ report: ReportRequest) async throws

    // MARK: Stexx+
    func subscriptionStatus() async throws -> SubscriptionStatus
    /// Sends a StoreKit 2 transaction JWS for server-side verification.
    func submitAppleTransaction(signedTransaction: String) async throws -> SubscriptionStatus
    /// Travel mode: browse from `location` (already fuzzed); `nil` turns it off.
    func setTravelLocation(_ location: FuzzedLocation?) async throws
    /// Starts a one-hour boost.
    func startBoost() async throws -> Boost

    #if DEBUG
    /// Grants Stexx+ without a purchase (mock state, or the dev server's
    /// `POST /v1/dev/plus`). Debug builds only.
    func debugGrantPlus() async throws
    #endif
}

enum APIError: LocalizedError, Equatable, Sendable {
    case unauthorized
    case notFound
    case requiresPlus
    /// 429. `retryAfter` is the server's `Retry-After`, in seconds, when sent.
    case rateLimited(retryAfter: TimeInterval?)
    case server(status: Int, message: String?)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unauthorized: String(localized: "Your session expired. Please sign in again.")
        case .notFound: String(localized: "That profile or conversation no longer exists.")
        case .requiresPlus: String(localized: "This feature is part of Stexx+.")
        case .rateLimited: String(localized: "Slow down a little and try again in a moment.")
        case .server(_, let message): message ?? String(localized: "Something went wrong on our side.")
        case .invalidResponse: String(localized: "Unexpected response from the server.")
        }
    }
}

/// Backend configuration, read from Info.plist (populated from build
/// settings in `project.yml`) so builds can point at staging or a local
/// server without code changes.
struct APIConfiguration: Sendable {
    static let defaultBaseURL = URL(string: "https://api.stexx.gay")!

    var baseURL: URL
    var apiVersion = "v1"
    var useMock: Bool

    static func fromBundle(_ bundle: Bundle = .main) -> APIConfiguration {
        let urlString = bundle.object(forInfoDictionaryKey: "StexxAPIBaseURL") as? String
        let mockFlag = bundle.object(forInfoDictionaryKey: "StexxUseMockAPI") as? String
        return APIConfiguration(
            baseURL: urlString.flatMap { URL(string: $0) } ?? defaultBaseURL,
            useMock: mockFlag?.uppercased() != "NO"
        )
    }

    /// `ws://…/v1/ws` for an `http` base URL, `wss://…/v1/ws` for `https`.
    var realtimeURL: URL {
        var components = URLComponents(
            url: baseURL.appending(path: apiVersion).appending(path: "ws"),
            resolvingAgainstBaseURL: false
        )
        components?.scheme = baseURL.scheme?.lowercased() == "http" ? "ws" : "wss"
        return components?.url ?? baseURL
    }

    /// Mock unless the build explicitly opts into the live backend.
    func makeClient(
        sessionStore: any SessionStore = KeychainSessionStore(),
        hooks: APIClientHooks = APIClientHooks()
    ) -> any APIClient {
        if useMock {
            return MockAPIClient.shared
        }
        return HTTPAPIClient(
            configuration: self,
            sessions: SessionCoordinator(store: sessionStore, hooks: hooks),
            hooks: hooks
        )
    }
}

extension URLSession {
    /// The API's session: no response cache at all (API responses are
    /// `no-store` anyway, and nothing from the API should land in
    /// `Library/Caches`).
    static let stexxAPI: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()
}

/// Lets the live client tell the app about things that happen below the UI:
/// rotated or expired sessions, and 402 `requires_plus` from any endpoint.
struct APIClientHooks: Sendable {
    /// The session was refreshed and saved (new access + refresh token).
    var sessionRefreshed: @Sendable (Session) async -> Void = { _ in }
    /// The refresh token was rejected; the session has been cleared.
    var sessionExpired: @Sendable () async -> Void = {}
    /// The server answered 402: the user doesn't (or no longer) have Stexx+.
    var requiresPlus: @Sendable () async -> Void = {}
}

/// ISO 8601 dates as the server sends them (`2026-11-17T20:30:00Z`), with or
/// without fractional seconds and with `Z` or a numeric offset.
enum StexxDate {
    private static let plain = Date.ISO8601FormatStyle()
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    static func parse(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        if let date = try? plain.parse(trimmed) { return date }
        if let date = try? fractional.parse(trimmed) { return date }
        // Offsets like +02:00 and other ISO 8601 variants.
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: trimmed) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: trimmed)
    }
}

extension JSONDecoder {
    static func stexx() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = StexxDate.parse(string) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected an ISO 8601 date, got \(string)"
                )
            }
            return date
        }
        return decoder
    }
}

extension JSONEncoder {
    static func stexx() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

// MARK: - Environment

private struct APIClientKey: EnvironmentKey {
    static let defaultValue: any APIClient = MockAPIClient.shared
}

extension EnvironmentValues {
    var apiClient: any APIClient {
        get { self[APIClientKey.self] }
        set { self[APIClientKey.self] = newValue }
    }
}
