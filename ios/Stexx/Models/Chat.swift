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
    /// Plaintext. For an end-to-end encrypted message the server sends
    /// `null` and the app fills this in from the decrypted `envelope` (or
    /// its local copy), so screens and report evidence just read `text`.
    var text: String?
    /// End-to-end encrypted content (`docs/api.md`, Message envelope).
    /// When set, the server's `text` is `null`.
    var envelope: MessageEnvelope? = nil
    var attachment: Attachment?
    let sentAt: Date
    var status: Status
    /// When set, the server deletes the message (and its media) at this time.
    var expiresAt: Date?
    /// Client-generated idempotency key; lets the app reconcile an optimistic
    /// local message with the server's copy.
    var clientID: String?
    /// Local only, never on the wire: what the app made of `envelope`.
    var encryption: Encryption? = nil

    enum Status: String, Codable, Sendable {
        case sending, sent, delivered, read, failed
    }

    /// The local outcome for an end-to-end encrypted message.
    enum Encryption: Hashable, Sendable {
        /// Decrypted (or sent) on this device; `text` holds the plaintext.
        case decrypted
        /// Can't be shown: no plaintext was kept on this device and the
        /// ratchet keys are gone (a reinstall, a new phone, or a message
        /// older than this device's keys).
        case unavailable
        /// The sender's identity key changed and the user hasn't accepted
        /// the new key yet. Decrypted once they do.
        case awaitingKeyConfirmation
        /// Decrypted, but the content isn't something this version shows.
        case unsupported
    }

    private enum CodingKeys: String, CodingKey {
        case id, conversationID, senderID, text, envelope, attachment, sentAt, status, expiresAt, clientID
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
    /// Plaintext as typed. `E2EAPIClient` turns it into `envelope` (and
    /// clears it) when the message is end-to-end encrypted.
    var text: String?
    /// Exclusive with `text` on the wire.
    var envelope: MessageEnvelope? = nil
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
            envelope: nil,
            attachment: nil,
            sentAt: .now,
            status: .sending,
            expiresAt: nil,
            clientID: draft.clientID
        )
    }
}
