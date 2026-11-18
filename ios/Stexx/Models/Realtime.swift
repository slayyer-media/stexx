import Foundation

/// Events pushed over `GET /v1/ws`. Payloads use the same JSON models as the
/// REST API.
///
/// Wire format (one JSON object per text frame):
/// `{ "type": "message.created", "data": { ...Message } }`. `payload` is
/// accepted as an alias for `data`. Unknown types are ignored so the server
/// can add events without breaking older apps.
enum RealtimeEvent: Hashable, Sendable {
    case messageCreated(Message)
    case messageRead(ReadReceipt)
    case conversationUpdated(Conversation)
    case tapReceived(Tap)
    case unknown(type: String)

    /// `message.read`: the other participant read messages in a conversation.
    struct ReadReceipt: Codable, Hashable, Sendable {
        var conversationID: Conversation.ID
        /// Who read. Optional; when missing the reader is the other participant.
        var readerID: Profile.ID?
        /// Everything sent at or before this instant is read.
        var readAt: Date?
        /// Explicit message IDs, if the server sends them.
        var messageIDs: [Message.ID]?
    }

    /// `tap.received`: someone tapped you.
    struct Tap: Hashable, Sendable {
        var from: Profile
        var sentAt: Date?
    }

    private struct Envelope: Decodable {
        var type: String
    }

    private struct DataEnvelope<Payload: Decodable>: Decodable {
        var payload: Payload

        enum CodingKeys: String, CodingKey { case data, payload }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if container.contains(.data) {
                payload = try container.decode(Payload.self, forKey: .data)
            } else {
                payload = try container.decode(Payload.self, forKey: .payload)
            }
        }
    }

    /// `tap.received` data is `{ "from": Profile, "sentAt": ... }`; a bare
    /// Profile (or `profile` instead of `from`) is accepted too.
    private struct TapPayload: Decodable {
        var tap: Tap

        enum CodingKeys: String, CodingKey { case from, profile, sentAt }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let sentAt = try container.decodeIfPresent(Date.self, forKey: .sentAt)
            if let profile = try container.decodeIfPresent(Profile.self, forKey: .from)
                ?? container.decodeIfPresent(Profile.self, forKey: .profile) {
                tap = Tap(from: profile, sentAt: sentAt)
            } else {
                tap = Tap(from: try Profile(from: decoder), sentAt: sentAt)
            }
        }
    }

    static func decode(_ data: Data, decoder: JSONDecoder = .stexx()) throws -> RealtimeEvent {
        let type = try decoder.decode(Envelope.self, from: data).type
        switch type {
        case "message.created":
            return .messageCreated(try decoder.decode(DataEnvelope<Message>.self, from: data).payload)
        case "message.read":
            return .messageRead(try decoder.decode(DataEnvelope<ReadReceipt>.self, from: data).payload)
        case "conversation.updated":
            return .conversationUpdated(try decoder.decode(DataEnvelope<Conversation>.self, from: data).payload)
        case "tap.received":
            return .tapReceived(try decoder.decode(DataEnvelope<TapPayload>.self, from: data).payload.tap)
        default:
            return .unknown(type: type)
        }
    }
}
