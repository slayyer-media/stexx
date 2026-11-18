import Foundation

/// Auth session returned by the backend. Stored in the Keychain.
struct Session: Codable, Hashable, Sendable {
    let userID: Profile.ID
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
}

/// Anonymous registration. No real name, no phone number.
struct RegistrationRequest: Codable, Hashable, Sendable {
    enum Method: String, Codable, Sendable {
        /// WebAuthn passkey bound to stexx.gay (preferred).
        case passkey
        /// Magic sign-in link. The address is used for sign-in only and is
        /// never shown on a profile.
        case email
    }

    var displayName: String
    var method: Method
    var email: String?
    /// The user confirmed they are 18 or older. Birth dates are not sent.
    var confirmedAdult: Bool
}

/// Editable subset of the user's own profile.
struct ProfileUpdate: Codable, Hashable, Sendable {
    var displayName: String
    var age: Int?
    var pronouns: String?
    var headline: String?
    var about: String?
    var heightCm: Int?
    var position: Position?
    var lookingFor: [LookingFor]
    var tags: [String]

    init(_ profile: Profile) {
        displayName = profile.displayName
        age = profile.age
        pronouns = profile.pronouns
        headline = profile.headline
        about = profile.about
        heightCm = profile.heightCm
        position = profile.position
        lookingFor = profile.lookingFor
        tags = profile.tags
    }
}

/// Privacy controls. Everything here is free; Stexx+ only adds incognito.
struct PrivacySettings: Codable, Hashable, Sendable {
    /// Hide your distance from others (they still see you in the grid).
    var hideDistance = false
    var showOnlineStatus = true
    var sendReadReceipts = true
    /// New photos sent in chat expire by default.
    var expiringPhotosByDefault = true
    /// Blur explicit photos in chat until tapped.
    var blurExplicitPhotos = true
    /// Stexx+: browse without appearing in the grid or "viewed you" lists.
    var incognito = false
}

/// Reasons a member can be reported. Reports are always free.
enum ReportReason: String, Codable, CaseIterable, Identifiable, Sendable {
    case underage, harassment, spam, fakeProfile, threatsOrViolence, illegalContent, other

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .underage: "May be under 18"
        case .harassment: "Harassment or hate"
        case .spam: "Spam or scam"
        case .fakeProfile: "Fake or impersonation"
        case .threatsOrViolence: "Threats or violence"
        case .illegalContent: "Illegal content"
        case .other: "Something else"
        }
    }

    var systemImage: String {
        switch self {
        case .underage: "exclamationmark.shield"
        case .harassment: "hand.raised"
        case .spam: "envelope.badge"
        case .fakeProfile: "person.crop.circle.badge.questionmark"
        case .threatsOrViolence: "exclamationmark.triangle"
        case .illegalContent: "nosign"
        case .other: "ellipsis.circle"
        }
    }
}

struct ReportRequest: Codable, Hashable, Sendable {
    var profileID: Profile.ID
    var reason: ReportReason
    var details: String?
    var conversationID: Conversation.ID?
    var alsoBlock: Bool
    /// Messages the reporter chose to share with moderators. Only valid
    /// together with `conversationID`.
    var evidence: [ReportEvidence]?
}

/// One message the reporter chose to share. Chats are headed for end-to-end
/// encryption, so the app sends the plaintext itself. Photos are not
/// uploaded: a photo message is flagged with `hasPhoto`.
struct ReportEvidence: Codable, Hashable, Sendable {
    /// The server accepts at most this many items per report.
    static let maxItems = 20
    static let maxTextLength = 4000
    static let maxIDLength = 64

    var messageID: String?
    var sentAt: Date?
    /// `true` when the person being reported sent this message.
    var fromReported: Bool
    var text: String?
    var hasPhoto: Bool?

    /// Builds the evidence list from exactly the selected messages, oldest
    /// first. Unselected messages are never included; messages with neither
    /// text nor a photo are dropped. Keeps the newest `maxItems`.
    static func from(
        messages: [Message],
        selectedIDs: Set<Message.ID>,
        reportedID: Profile.ID
    ) -> [ReportEvidence] {
        let items: [ReportEvidence] = messages
            .filter { selectedIDs.contains($0.id) }
            .sorted { $0.sentAt < $1.sentAt }
            .compactMap { message in
                let trimmed = message.text?.trimmingCharacters(in: .whitespacesAndNewlines)
                let text = (trimmed?.isEmpty ?? true) ? nil : String(trimmed!.prefix(maxTextLength))
                let hasPhoto = message.attachment?.kind == .photo
                guard text != nil || hasPhoto else { return nil }
                return ReportEvidence(
                    messageID: String(message.id.prefix(maxIDLength)),
                    sentAt: message.sentAt,
                    fromReported: message.senderID == reportedID,
                    text: text,
                    hasPhoto: hasPhoto ? true : nil
                )
            }
        return Array(items.suffix(maxItems))
    }
}

/// A location that has already been coarsened on device.
struct FuzzedLocation: Codable, Hashable, Sendable {
    var latitude: Double
    var longitude: Double
    /// Size of the grid cell the coordinates were snapped to.
    var precisionMeters: Double
}

/// One page of a cursor-paginated list.
struct Page<Item: Codable & Sendable>: Codable, Sendable {
    var items: [Item]
    var nextCursor: String?
}

/// Grid query. Basic filters are free; the rest require Stexx+ and are
/// enforced server-side.
struct NearbyQuery: Codable, Hashable, Sendable {
    var onlineOnly = false
    var favoritesOnly = false
    var lookingFor: Set<LookingFor> = []

    // Stexx+ advanced filters
    var minAge: Int?
    var maxAge: Int?
    var maxDistanceMeters: Double?
    var positions: Set<Position> = []
    var tags: [String] = []

    var cursor: String?
    var limit = 60

    var usesAdvancedFilters: Bool {
        minAge != nil || maxAge != nil || maxDistanceMeters != nil || !positions.isEmpty || !tags.isEmpty
    }
}
