import Foundation

/// One entry in the received taps inbox (`GET /me/taps`): someone tapped
/// you. The server sends at most one entry per sender, their latest tap.
struct ReceivedTap: Identifiable, Hashable, Codable, Sendable {
    var from: Profile
    var sentAt: Date
    /// Sent after you last opened your taps (`POST /me/taps/seen`).
    var isNew: Bool

    /// One entry per sender, so the sender's ID identifies it.
    var id: Profile.ID { from.id }
}

/// A page of `GET /me/taps`. `unseenCount` counts the new entries across
/// the whole retention window, not only this page.
struct TapsPage: Codable, Sendable {
    var items: [ReceivedTap]
    var nextCursor: String?
    var unseenCount: Int
}

extension ReceivedTap {
    /// A live `tap.received`: new until the taps screen is opened.
    init(_ event: RealtimeEvent.Tap, receivedAt: Date = .now) {
        self.init(from: event.from, sentAt: event.sentAt ?? receivedAt, isNew: true)
    }
}
