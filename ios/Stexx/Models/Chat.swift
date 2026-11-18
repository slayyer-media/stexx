import Foundation

struct Conversation: Identifiable, Hashable, Codable, Sendable {
    typealias ID = String

    let id: ID
    var participant: Profile
    var lastMessage: Message?
    var unreadCount: Int
    var updatedAt: Date
    var isMuted: Bool = false
}

struct Message: Identifiable, Hashable, Codable, Sendable {
    typealias ID = String

    let id: ID
    let conversationID: Conversation.ID
    let senderID: Profile.ID
    var text: String?
    var attachment: Attachment?
    let sentAt: Date
    var status: Status
    /// When set, the server deletes the message (and its media) at this time.
    var expiresAt: Date?
    /// Client-generated idempotency key; lets the app reconcile an optimistic
    /// local message with the server's copy.
    var clientID: String?

    enum Status: String, Codable, Sendable {
        case sending, sent, delivered, read, failed
    }

    struct Attachment: Hashable, Codable, Sendable {
        enum Kind: String, Codable, Sendable {
            case photo
        }

        var kind: Kind
        var url: URL?
        /// View-once media disappears after the recipient opens it.
        var isViewOnce: Bool = false
    }
}

/// What the client sends to create a message.
struct MessageDraft: Codable, Hashable, Sendable {
    var clientID: String
    var text: String?
    var attachmentPhotoID: Photo.ID?
    /// Seconds after reading until the message expires; `nil` keeps it.
    var expiresAfterSeconds: Int?
    /// Photo messages only. `false` sends the photo as a normal, keepable
    /// photo; `nil` (omitted on the wire) lets the server apply the sender's
    /// "expiring photos by default" setting.
    var isViewOnce: Bool? = nil
}

extension Message {
    /// An optimistic local copy shown while the draft is being sent.
    static func pending(from draft: MessageDraft, conversationID: Conversation.ID, senderID: Profile.ID) -> Message {
        Message(
            id: "local-\(draft.clientID)",
            conversationID: conversationID,
            senderID: senderID,
            text: draft.text,
            attachment: nil,
            sentAt: .now,
            status: .sending,
            expiresAt: nil,
            clientID: draft.clientID
        )
    }
}
