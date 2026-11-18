import Foundation
import SwiftUI

/// Everything the app needs from the Stexx backend. The UI only talks to
/// this protocol, so the mock and the real HTTP client are interchangeable.
/// See `docs/api.md` for the wire format.
protocol APIClient: Sendable {
    // MARK: Auth & account
    func register(_ request: RegistrationRequest) async throws -> Session
    func deleteAccount() async throws

    // MARK: Me
    func fetchMe() async throws -> Profile
    func updateMe(_ update: ProfileUpdate) async throws -> Profile
    /// Uploads a JPEG that has already had its metadata stripped.
    func uploadPhoto(jpegData: Data) async throws -> Photo
    func updatePrivacy(_ settings: PrivacySettings) async throws -> PrivacySettings
    func updateLocation(_ location: FuzzedLocation) async throws

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
}

enum APIError: LocalizedError, Equatable, Sendable {
    case unauthorized
    case notFound
    case requiresPlus
    case rateLimited
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

    /// Mock unless the build explicitly opts into the live backend.
    func makeClient(sessionStore: any SessionStore = KeychainSessionStore()) -> any APIClient {
        if useMock {
            return MockAPIClient.shared
        }
        return HTTPAPIClient(configuration: self) {
            sessionStore.load()?.accessToken
        }
    }
}

extension JSONDecoder {
    static func stexx() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
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
