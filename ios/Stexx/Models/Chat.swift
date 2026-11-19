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
    /// Local only: the key for an end-to-end encrypted photo
    /// (`attachment.isEncrypted`), from the decrypted envelope or the local
    /// history. `nil` when this phone doesn't have it (see `e2eAttachmentRemoval`).
    var e2eAttachment: E2EAttachmentPointer? = nil
    /// Local only: why this phone no longer has the key of an encrypted
    /// photo it once had.
    var e2eAttachmentRemoval: AttachmentRemoval? = nil

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

    /// Why an encrypted photo's key was dropped from this phone.
    enum AttachmentRemoval: Hashable, Sendable {
        /// A view-once photo the user opened here.
        case opened
        /// The photo can't exist any more (expired, or spent on the server).
        case gone
    }

    private enum CodingKeys: String, CodingKey {
        case id, conversationID, senderID, text, envelope, attachment, sentAt, status, expiresAt, clientID
    }

    struct Attachment: Hashable, Codable, Sendable {
        enum Kind: String, Codable, Sendable {
            case photo
        }

        var kind: Kind
        /// `nil` once the photo is gone (expired or a spent view-once), and
        /// for the recipient of a view-once photo outside `GET …/messages`.
        var url: URL?
        /// View-once media disappears after the recipient opens it.
        var isViewOnce: Bool = false
        /// The file is an end-to-end encrypted blob; the key is in the
        /// envelope (`Message.e2eAttachment`), never on the server.
        var isEncrypted: Bool = false
    }
}

extension Message.Attachment {
    private enum CodingKeys: String, CodingKey {
        case kind, url, isViewOnce, isEncrypted
    }

    /// The mock and servers from before encrypted photos omit `isEncrypted`
    /// (and older ones `isViewOnce`).
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(Kind.self, forKey: .kind)
        url = try container.decodeIfPresent(URL.self, forKey: .url)
        isViewOnce = try container.decodeIfPresent(Bool.self, forKey: .isViewOnce) ?? false
        isEncrypted = try container.decodeIfPresent(Bool.self, forKey: .isEncrypted) ?? false
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
