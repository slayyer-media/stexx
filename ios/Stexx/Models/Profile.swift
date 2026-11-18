import Foundation

/// A public profile as seen by other members. Server-provided; never
/// contains a real name, phone number, or precise location.
struct Profile: Identifiable, Hashable, Codable, Sendable {
    typealias ID = String

    let id: ID
    var displayName: String
    var age: Int?
    var pronouns: String?
    var headline: String?
    var about: String?
    var heightCm: Int?
    var position: Position?
    var lookingFor: [LookingFor]
    var tags: [String]
    var photos: [Photo]
    /// Approximate distance in meters, already bucketed by the server.
    /// `nil` when the member hides their distance.
    var distanceMeters: Double?
    var isOnline: Bool
    var lastActiveAt: Date?
    /// Whether the current user has favorited this profile.
    var isFavorite: Bool

    var primaryPhotoURL: URL? { photos.first?.url }

    /// "Kai, 27" or just "Kai" when age is hidden.
    var nameAndAge: String {
        if let age { "\(displayName), \(age)" } else { displayName }
    }

    /// The photos other people see, in order. The server hides photos it
    /// labelled explicit from everyone but their owner.
    var publicPhotos: [Photo] { photos.filter { !$0.isExplicit } }
}

struct Photo: Identifiable, Hashable, Codable, Sendable {
    typealias ID = String

    let id: ID
    var url: URL?
    /// Labelled explicit by the server's photo check: shown to its owner
    /// (badged "Hidden") and sendable in chat, never on the public profile.
    var isExplicit: Bool = false
}

enum Position: String, Codable, CaseIterable, Identifiable, Sendable {
    case top, versTop, versatile, versBottom, bottom, side

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .top: "Top"
        case .versTop: "Vers top"
        case .versatile: "Versatile"
        case .versBottom: "Vers bottom"
        case .bottom: "Bottom"
        case .side: "Side"
        }
    }
}

enum LookingFor: String, Codable, CaseIterable, Identifiable, Sendable {
    case chat, dates, friends, relationship, networking, rightNow

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .chat: "Chat"
        case .dates: "Dates"
        case .friends: "Friends"
        case .relationship: "Relationship"
        case .networking: "Networking"
        case .rightNow: "Right now"
        }
    }

    var systemImage: String {
        switch self {
        case .chat: "bubble.left"
        case .dates: "wineglass"
        case .friends: "person.2"
        case .relationship: "heart"
        case .networking: "point.3.connected.trianglepath.dotted"
        case .rightNow: "flame"
        }
    }
}
