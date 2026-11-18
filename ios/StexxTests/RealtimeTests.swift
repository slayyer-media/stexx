import Foundation
import Testing
@testable import Stexx

enum RealtimeFixtures {
    static let profile = #"""
    {"id":"p1","displayName":"Eigenbro","age":29,"pronouns":null,"headline":null,"about":null,"heightCm":null,
     "position":"versatile","lookingFor":["chat"],"tags":[],"photos":[],"distanceMeters":300,"isOnline":true,
     "lastActiveAt":"2026-11-17T20:30:00Z","isFavorite":false}
    """#

    static func message(id: String = "m1", conversation: String = "c1", sender: String = "p1", clientID: String? = nil, sentAt: String = "2026-11-17T20:31:00Z") -> String {
        let client = clientID.map { "\"\($0)\"" } ?? "null"
        return #"{"id":"\#(id)","conversationID":"\#(conversation)","senderID":"\#(sender)","text":"hi","attachment":null,"sentAt":"\#(sentAt)","status":"delivered","expiresAt":null,"clientID":\#(client)}"#
    }

    static func event(_ type: String, _ data: String) -> Data {
        Data(#"{"type":"\#(type)","data":\#(data)}"#.utf8)
    }
}

struct RealtimeEventTests {
    @Test("message.created decodes a Message")
    func messageCreated() throws {
        let event = try RealtimeEvent.decode(RealtimeFixtures.event("message.created", RealtimeFixtures.message()))
        guard case .messageCreated(let message) = event else {
            Issue.record("Wrong event: \(event)")
            return
        }
        #expect(message.id == "m1")
        #expect(message.conversationID == "c1")
        #expect(message.status == .delivered)
    }

    @Test("message.read decodes a receipt, with fractional seconds")
    func messageRead() throws {
        let event = try RealtimeEvent.decode(RealtimeFixtures.event(
            "message.read",
            #"{"conversationID":"c1","readerID":"p1","readAt":"2026-11-17T20:32:00.500Z"}"#
        ))
        guard case .messageRead(let receipt) = event else {
            Issue.record("Wrong event: \(event)")
            return
        }
        #expect(receipt.conversationID == "c1")
        #expect(receipt.readerID == "p1")
        #expect(receipt.readAt != nil)
        #expect(receipt.messageIDs == nil)
    }

    @Test("conversation.updated decodes a Conversation")
    func conversationUpdated() throws {
        let json = #"{"id":"c1","participant":\#(RealtimeFixtures.profile),"lastMessage":\#(RealtimeFixtures.message()),"unreadCount":3,"updatedAt":"2026-11-17T20:31:00Z","isMuted":false}"#
        let event = try RealtimeEvent.decode(RealtimeFixtures.event("conversation.updated", json))
        guard case .conversationUpdated(let conversation) = event else {
            Issue.record("Wrong event: \(event)")
            return
        }
        #expect(conversation.unreadCount == 3)
        #expect(conversation.participant.displayName == "Eigenbro")
    }

    @Test("tap.received accepts { from } and a bare profile; payload is an alias for data")
    func tapReceived() throws {
        let wrapped = try RealtimeEvent.decode(RealtimeFixtures.event(
            "tap.received", #"{"from":\#(RealtimeFixtures.profile),"sentAt":"2026-11-17T20:31:00Z"}"#
        ))
        let bare = try RealtimeEvent.decode(Data(#"{"type":"tap.received","payload":\#(RealtimeFixtures.profile)}"#.utf8))
        guard case .tapReceived(let first) = wrapped, case .tapReceived(let second) = bare else {
            Issue.record("Wrong events: \(wrapped), \(bare)")
            return
        }
        #expect(first.from.id == "p1")
        #expect(first.sentAt != nil)
        #expect(second.from.id == "p1")
        #expect(second.sentAt == nil)
    }

    @Test("Unknown events are tolerated, malformed ones throw")
    func unknownAndMalformed() throws {
        #expect(try RealtimeEvent.decode(Data(#"{"type":"presence.changed","data":{}}"#.utf8)) == .unknown(type: "presence.changed"))
        #expect(throws: (any Error).self) { try RealtimeEvent.decode(Data("nope".utf8)) }
        #expect(throws: (any Error).self) {
            try RealtimeEvent.decode(RealtimeFixtures.event("message.created", #"{"id":"m1"}"#))
        }
    }

    @Test("Socket URL follows the API scheme")
    func socketURL() {
        let local = APIConfiguration(baseURL: URL(string: "http://127.0.0.1:8787")!, useMock: false)
        #expect(local.realtimeURL.absoluteString == "ws://127.0.0.1:8787/v1/ws")
        let production = APIConfiguration(baseURL: URL(string: "https://api.stexx.gay")!, useMock: false)
        #expect(production.realtimeURL.absoluteString == "wss://api.stexx.gay/v1/ws")
    }

    @Test("Reconnect backoff grows and caps at a minute")
    func backoff() {
        #expect(RealtimeClient.backoff(attempt: 1, jitter: 1) == .seconds(1))
        #expect(RealtimeClient.backoff(attempt: 4, jitter: 1) == .seconds(8))
        #expect(RealtimeClient.backoff(attempt: 30, jitter: 1) == .seconds(60))
    }
}

@MainActor
struct ChatStoreRealtimeTests {
    private func message(_ id: String, in conversation: Conversation.ID, from sender: Profile.ID, clientID: String? = nil, status: Message.Status = .delivered) -> Message {
        Message(id: id, conversationID: conversation, senderID: sender, text: "hi", attachment: nil,
                sentAt: .now, status: status, expiresAt: nil, clientID: clientID)
    }

    private func loadedStore() async -> ChatStore {
        let store = ChatStore(api: MockAPIClient(latency: .zero))
        await store.load()
        return store
    }

    @Test("Incoming messages update the list and the unread badge")
    func incomingRaisesUnread() async throws {
        let store = await loadedStore()
        let conversation = try #require(store.conversations.first { $0.participant.id == "p01" })
        let before = store.unreadTotal

        store.apply(.messageCreated(message("live-1", in: conversation.id, from: "p01")), myID: MockData.myID)

        #expect(store.conversations.first?.id == conversation.id)
        #expect(store.conversations.first?.lastMessage?.id == "live-1")
        #expect(store.unreadTotal == before + 1)

        // A replay of the same message changes nothing.
        store.apply(.messageCreated(message("live-1", in: conversation.id, from: "p01")), myID: MockData.myID)
        #expect(store.unreadTotal == before + 1)
    }

    @Test("Open threads get live updates instead of unread counts")
    func openThreadReceivesUpdates() async throws {
        let store = await loadedStore()
        let conversation = try #require(store.conversations.first { $0.participant.id == "p01" })
        let before = store.unreadTotal
        let updates = store.threadUpdates(for: conversation.id)
        #expect(store.isThreadOpen(conversation.id))

        let incoming = message("live-2", in: conversation.id, from: "p01")
        store.apply(.messageCreated(incoming), myID: MockData.myID)
        #expect(store.unreadTotal == before)

        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next() == .created(incoming))
    }

    @Test("Merging replaces the optimistic copy and applies read receipts")
    func mergeIntoThread() {
        let draft = MessageDraft(clientID: "client-1", text: "hi")
        var messages = [Message.pending(from: draft, conversationID: "c1", senderID: "me")]
        let echoed = message("m9", in: "c1", from: "me", clientID: "client-1", status: .sent)

        ChatStore.merge(.created(echoed), into: &messages, myID: "me")
        #expect(messages.map(\.id) == ["m9"])

        ChatStore.merge(.created(message("m10", in: "c1", from: "p1")), into: &messages, myID: "me")
        #expect(messages.map(\.id) == ["m9", "m10"])

        let receipt = RealtimeEvent.ReadReceipt(conversationID: "c1", readerID: "p1", readAt: .now.addingTimeInterval(5), messageIDs: nil)
        ChatStore.merge(.read(receipt), into: &messages, myID: "me")
        #expect(messages[0].status == .read)
        // Their message isn't affected by my read receipt.
        #expect(messages[1].status == .delivered)
    }

    @Test("conversation.updated inserts or replaces in recency order")
    func conversationUpdated() async throws {
        let store = await loadedStore()
        var conversation = try #require(store.conversations.last)
        conversation.updatedAt = .now.addingTimeInterval(60)
        conversation.unreadCount = 7

        store.apply(.conversationUpdated(conversation), myID: MockData.myID)
        #expect(store.conversations.first?.id == conversation.id)
        #expect(store.conversations.first?.unreadCount == 7)
        #expect(store.conversations.filter { $0.id == conversation.id }.count == 1)
    }
}
