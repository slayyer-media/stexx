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

/// One message the reporter chose to share. Chats are end-to-end encrypted,
/// so the app sends the plaintext itself. A photo message is flagged with
/// `hasPhoto`; the app also re-uploads the photo it can show (decrypted for
/// an encrypted one) as a fresh, sanitized private upload and passes its
/// `photoID`, so moderators see exactly the photos the reporter ticked.
struct ReportEvidence: Codable, Hashable, Sendable {
    /// The server accepts at most this many items per report.
    static let maxItems = 20
    static let maxTextLength = 4000
    static let maxIDLength = 64
    /// At most this many photos per report: each is a pending upload, and the
    /// server allows 10 of those at once.
    static let maxPhotos = 10

    var messageID: String?
    var sentAt: Date?
    /// `true` when the person being reported sent this message.
    var fromReported: Bool
    var text: String?
    var hasPhoto: Bool?
    /// One of the reporter's own pending uploads (`POST /me/attachments`)
    /// holding this message's photo. Implies `hasPhoto`.
    var photoID: Photo.ID? = nil

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

extension ReportEvidence {
    /// Adds `photoID`s to the photo items of `evidence`: for each, `load`
    /// returns the photo this device can show as a sanitized JPEG (decrypted
    /// for an encrypted one), and `upload` stores it as a private upload.
    ///
    /// At most `maxPhotos`, the reported person's photos first. A photo that
    /// can't be loaded or uploaded keeps `hasPhoto: true` without a
    /// `photoID`; the report still goes out.
    ///
    /// - Parameters:
    ///   - uploaded: Photos an earlier attempt of this report already
    ///     uploaded, by evidence `messageID` (`uploadedPhotoIDs(in:)`): reused,
    ///     never uploaded again (each upload holds one of the server's
    ///     pending upload slots).
    ///   - upload: A 409 (`attachment_limit`: every pending slot is taken)
    ///     stops further uploads; those items go with `hasPhoto` only.
    static func attachingPhotos(
        to evidence: [ReportEvidence],
        messages: [Message],
        reusing uploaded: [String: Photo.ID] = [:],
        load: @Sendable (Message) async -> Data?,
        upload: @Sendable (Data) async throws -> Photo.ID
    ) async -> [ReportEvidence] {
        var result = evidence
        let byID = Dictionary(messages.map { (String($0.id.prefix(maxIDLength)), $0) }, uniquingKeysWith: { first, _ in first })
        let photoIndices = result.indices
            .filter { result[$0].hasPhoto == true && result[$0].photoID == nil }
            .sorted { lhs, rhs in
                // The reported person's photos first, then newest first.
                if result[lhs].fromReported != result[rhs].fromReported { return result[lhs].fromReported }
                return lhs > rhs
            }
        var attached = 0
        var atLimit = false
        for index in photoIndices {
            guard attached < maxPhotos, !Task.isCancelled else { break }
            guard let id = result[index].messageID else { continue }
            if let known = uploaded[id] {
                result[index].photoID = known
                attached += 1
                continue
            }
            guard !atLimit, let message = byID[id], let jpeg = await load(message) else { continue }
            do {
                result[index].photoID = try await upload(jpeg)
                attached += 1
            } catch APIError.server(status: 409, message: _, code: _) {
                // `attachment_limit`: more uploads would fail too.
                atLimit = true
            } catch {
                continue
            }
        }
        return result
    }

    /// The uploaded photos of `evidence`, by `messageID`, for a retry.
    static func uploadedPhotoIDs(in evidence: [ReportEvidence]) -> [String: Photo.ID] {
        var ids: [String: Photo.ID] = [:]
        for item in evidence {
            if let messageID = item.messageID, let photoID = item.photoID { ids[messageID] = photoID }
        }
        return ids
    }
}
