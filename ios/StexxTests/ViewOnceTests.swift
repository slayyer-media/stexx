import Foundation
import Testing
@testable import Stexx

/// View-once photos are opened explicitly (`POST …/messages/{id}/open`) when
/// the viewer shows them, never by listing the thread; the key of an
/// encrypted one goes as soon as the server has it opened.
@Suite("View-once: open call, key deletion, Opened state")
struct ViewOnceTests {
    private let jpeg = MediaFixtures.jpeg

    private func pair() async -> (FakeE2EServer, FakeDevice, FakeDevice) {
        let server = FakeE2EServer()
        let alice = FakeDevice("alice", peer: "bob", server: server)
        let bob = FakeDevice("bob", peer: "alice", server: server)
        await alice.engine.syncKeys()
        await bob.engine.syncKeys()
        return (server, alice, bob)
    }

    // MARK: Wire

    @Test("attachment.openedAt decodes when present and is nil when a server omits it")
    func openedAtDecodes() throws {
        let opened = #"{"kind":"photo","url":null,"isViewOnce":true,"isEncrypted":true,"openedAt":"2026-11-19T06:00:00Z"}"#
        let attachment = try JSONDecoder.stexx().decode(Message.Attachment.self, from: Data(opened.utf8))
        #expect(attachment.openedAt == StexxDate.parse("2026-11-19T06:00:00Z"))
        #expect(attachment.isViewOnce)

        let old = #"{"kind":"photo","url":"https://media.test/a.jpg","isViewOnce":true}"#
        let legacy = try JSONDecoder.stexx().decode(Message.Attachment.self, from: Data(old.utf8))
        #expect(legacy.openedAt == nil)
        #expect(legacy.isEncrypted == false)

        // And it round-trips through the app's own coders.
        let data = try JSONEncoder.stexx().encode(attachment)
        #expect(try JSONDecoder.stexx().decode(Message.Attachment.self, from: data) == attachment)
    }

    @Test("The live client POSTs to …/messages/{id}/open and decodes the Message")
    func httpOpen() async throws {
        let log = CallLog()
        let baseURL = StubURLProtocol.register { request in
            await log.record("\(request.httpMethod ?? "?") \(request.url?.path() ?? "")")
            let body = #"{"id":"m_1","conversationID":"c_1","senderID":"p_2","text":null,"envelope":null,"attachment":{"kind":"photo","url":"https://media.test/a.jpg","isViewOnce":true,"isEncrypted":false,"openedAt":"2026-11-19T06:00:00Z"},"sentAt":"2026-11-19T05:59:00Z","status":"delivered","expiresAt":null,"clientID":null}"#
            return (200, ["Content-Type": "application/json"], Data(body.utf8))
        }
        let client = HTTPAPIClient(
            configuration: APIConfiguration(baseURL: baseURL, useMock: false),
            session: StubURLProtocol.session(),
            sessions: SessionCoordinator(store: InMemorySessionStore(), hooks: APIClientHooks()),
            hooks: APIClientHooks()
        )
        let message = try await client.openViewOnce(messageID: "m_1", in: "c_1")
        #expect(await log.entries == ["POST /v1/conversations/c_1/messages/m_1/open"])
        #expect(message.attachment?.openedAt != nil)
        #expect(message.isViewOnceOpened)
    }

    @Test("message.updated decodes a Message")
    func messageUpdatedDecodes() throws {
        let event = try RealtimeEvent.decode(RealtimeFixtures.event("message.updated", RealtimeFixtures.message(id: "m7")))
        guard case .messageUpdated(let message) = event else {
            Issue.record("Wrong event: \(event)")
            return
        }
        #expect(message.id == "m7")
    }

    // MARK: Encrypted photos through the engine

    @Test("Listing doesn't open a view-once photo; opening it drops the key; both sides then say Opened")
    func openDropsKey() async throws {
        let (server, alice, bob) = await pair()
        let sent = try await alice.sendPhoto(jpeg, isViewOnce: true)

        let listed = try #require(try await bob.thread().last)
        #expect(await server.count("open") == 0)
        #expect(listed.attachment?.url != nil)
        #expect(listed.attachment?.openedAt == nil)
        #expect(listed.e2eAttachment != nil)
        #expect(EncryptedPhotoContent.of(listed, isMine: false) == .viewOnce(canOpen: true))
        // The sender never gets the URL of their own view-once photo; their tile stays closed.
        let mine = try #require(try await alice.thread().last)
        #expect(mine.id == sent.id)
        #expect(mine.attachment?.url == nil)
        #expect(EncryptedPhotoContent.of(mine, isMine: true) == .viewOnce(canOpen: false))

        let opened = try await bob.client.openViewOnce(messageID: listed.id, in: FakeE2EServer.conversationID)
        #expect(await server.count("open") == 1)
        #expect(opened.attachment?.openedAt != nil)
        #expect(opened.e2eAttachment == nil)
        #expect(opened.e2eAttachmentRemoval == .opened)
        #expect(EncryptedPhotoContent.of(opened, isMine: false) == .opened)
        let entry = try #require(try bob.history.load(userID: "bob")?.messages[listed.id])
        #expect(entry.attachment == nil)
        #expect(entry.viewOnceOpenedAt != nil)
        #expect(await bob.evicted.entries.contains(listed.id))

        // Relisting keeps it opened (and doesn't open again).
        let relisted = try #require(try await bob.thread().last)
        #expect(EncryptedPhotoContent.of(relisted, isMine: false) == .opened)
        #expect(await server.count("open") == 1)
        // The sender sees Opened once the server reports it.
        let senderView = try #require(try await alice.thread().last)
        #expect(senderView.attachment?.openedAt != nil)
        #expect(EncryptedPhotoContent.of(senderView, isMine: true) == .opened)
    }

    @Test("A key still on the phone for a photo the server says was opened goes on the next listing")
    func serverOpenedDropsLeftoverKey() async throws {
        let (server, alice, bob) = await pair()
        _ = try await alice.sendPhoto(jpeg, isViewOnce: true)
        let listed = try #require(try await bob.thread().last)
        #expect(listed.e2eAttachment != nil)
        // Opened on the server, but the app quit before it handled the answer.
        _ = try await server.open(listed.id, as: "bob")

        let after = try #require(try await bob.thread().last)
        #expect(after.e2eAttachment == nil)
        #expect(after.e2eAttachmentRemoval == .opened)
        #expect(EncryptedPhotoContent.of(after, isMine: false) == .opened)
        #expect(try bob.history.load(userID: "bob")?.messages[listed.id]?.attachment == nil)
    }

    @Test("Opening a photo already gone (never opened) drops the key as gone, not opened")
    func goneBeforeOpen() async throws {
        let (server, alice, bob) = await pair()
        _ = try await alice.sendPhoto(jpeg, isViewOnce: true)
        let listed = try #require(try await bob.thread().last)
        await server.spendAttachment(of: listed.id)

        let answer = try await bob.client.openViewOnce(messageID: listed.id, in: FakeE2EServer.conversationID)
        #expect(answer.attachment?.url == nil)
        #expect(answer.attachment?.openedAt == nil)
        #expect(answer.e2eAttachment == nil)
        #expect(answer.e2eAttachmentRemoval == .gone)
        #expect(EncryptedPhotoContent.of(answer, isMine: false) == .gone)
        let entry = try #require(try bob.history.load(userID: "bob")?.messages[listed.id])
        #expect(entry.viewOnceOpenedAt == nil)
    }

    @Test("Only the recipient can open it (404 for the sender, the key stays)")
    func senderCantOpen() async throws {
        let (_, alice, bob) = await pair()
        let sent = try await alice.sendPhoto(jpeg, isViewOnce: true)
        await #expect(throws: APIError.notFound) {
            try await alice.client.openViewOnce(messageID: sent.id, in: FakeE2EServer.conversationID)
        }
        #expect(try await bob.thread().last?.e2eAttachment != nil)
    }

    // MARK: ChatStore

    @MainActor
    @Test("ChatStore marks it opened at once, and retries an open that failed offline")
    func chatStoreRetriesOpen() async throws {
        let (server, alice, bob) = await pair()
        _ = try await alice.sendPhoto(jpeg, isViewOnce: true)
        let listed = try #require(try await bob.thread().last)
        let store = ChatStore(api: bob.client, defaults: Self.freshDefaults())

        await server.failNextOpenOnce()
        let failed = await store.openViewOnce(listed.id, in: FakeE2EServer.conversationID)
        #expect(failed == nil)
        #expect(store.hasOpenedViewOnce(listed.id))
        #expect(await server.count("open") == 1)

        store.retryPendingViewOnceOpens()
        for _ in 0..<200 {
            if await server.messages.last?.attachment?.openedAt != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await server.count("open") == 2)
        #expect(await server.messages.last?.attachment?.openedAt != nil)
        // Done: nothing left to retry.
        store.retryPendingViewOnceOpens()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await server.count("open") == 2)
    }

    @MainActor
    @Test("A 404 (gone, blocked, not the recipient) is never retried")
    func chatStoreDropsNotFound() async throws {
        let (server, alice, _) = await pair()
        let sent = try await alice.sendPhoto(jpeg, isViewOnce: true)
        let store = ChatStore(api: alice.client, defaults: Self.freshDefaults())
        #expect(await store.openViewOnce(sent.id, in: FakeE2EServer.conversationID) == nil)
        store.retryPendingViewOnceOpens()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await server.count("open") == 1)
    }

    private static func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "stexx.tests.\(UUID().uuidString)")!
    }

    @MainActor
    @Test("A failed open survives a relaunch: still Opened on this phone, and the call is retried on the next load")
    func pendingOpenSurvivesRelaunch() async throws {
        // Plaintext (E2E off): the case where nothing but this phone's record stops a second viewing.
        let server = FakeE2EServer()
        await server.set(mode: .off)
        let alice = FakeDevice("alice", peer: "bob", server: server)
        let bob = FakeDevice("bob", peer: "alice", server: server)
        let sent = try await alice.sendPhoto(jpeg, isViewOnce: true)
        #expect(sent.attachment?.isEncrypted == false)
        let listed = try #require(try await bob.thread().last)
        #expect(listed.attachment?.url != nil)
        let defaults = Self.freshDefaults()

        await server.failNextOpenOnce()
        #expect(await ChatStore(api: bob.client, defaults: defaults).openViewOnce(listed.id, in: FakeE2EServer.conversationID) == nil)
        #expect(await server.messages.last?.attachment?.openedAt == nil)

        // "Relaunch": a new store on the same defaults, before anything loads.
        let relaunched = ChatStore(api: bob.client, defaults: defaults)
        #expect(relaunched.hasOpenedViewOnce(listed.id))
        await relaunched.load()
        for _ in 0..<200 {
            if await server.messages.last?.attachment?.openedAt != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await server.messages.last?.attachment?.openedAt != nil)
        #expect(await server.count("open") == 2)

        // Confirmed: a later launch has nothing left to send, but still knows it was opened here.
        let later = ChatStore(api: bob.client, defaults: defaults)
        #expect(later.hasOpenedViewOnce(listed.id))
        later.retryPendingViewOnceOpens()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await server.count("open") == 2)
    }

    @MainActor
    @Test("The record of opens is dropped at sign-out and after the server's cap, and holds IDs only")
    func openRecordLifetime() async throws {
        let (server, alice, bob) = await pair()
        _ = try await alice.sendPhoto(jpeg, isViewOnce: true)
        let listed = try #require(try await bob.thread().last)
        let defaults = Self.freshDefaults()

        await server.failNextOpenOnce()
        let store = ChatStore(api: bob.client, defaults: defaults)
        _ = await store.openViewOnce(listed.id, in: FakeE2EServer.conversationID)
        let stored = try #require(defaults.dictionary(forKey: "chat.viewOnce.opened") as? [String: Date])
        #expect(Array(stored.keys) == [listed.id])
        #expect(defaults.dictionary(forKey: "chat.viewOnce.pendingOpens") as? [String: String] == [listed.id: FakeE2EServer.conversationID])

        // Past the cap the server has deleted the photo anyway: forgotten, and not retried.
        let muchLater = Date.now.addingTimeInterval(ChatStore.viewOnceMemory + 60)
        let aged = ChatStore(api: bob.client, defaults: defaults, now: muchLater)
        #expect(!aged.hasOpenedViewOnce(listed.id))
        #expect(defaults.dictionary(forKey: "chat.viewOnce.pendingOpens")?.isEmpty == true)

        // Sign-out wipes it.
        let fresh = Self.freshDefaults()
        await server.failNextOpenOnce()
        let signedIn = ChatStore(api: bob.client, defaults: fresh)
        _ = await signedIn.openViewOnce(listed.id, in: FakeE2EServer.conversationID)
        signedIn.reset()
        #expect(!signedIn.hasOpenedViewOnce(listed.id))
        #expect(fresh.dictionary(forKey: "chat.viewOnce.opened") == nil)
        #expect(fresh.dictionary(forKey: "chat.viewOnce.pendingOpens") == nil)
        #expect(!ChatStore(api: bob.client, defaults: fresh).hasOpenedViewOnce(listed.id))
    }

    @MainActor
    @Test("message.updated replaces the list's last message and the thread's copy, never inserts")
    func messageUpdatedApplies() async throws {
        let store = ChatStore(api: MockAPIClient(latency: .zero))
        await store.load()
        let conversation = try #require(store.conversations.first { $0.participant.id == "p01" })
        let last = try #require(conversation.lastMessage)
        var updated = last
        updated.attachment = Message.Attachment(kind: .photo, url: nil, isViewOnce: true, openedAt: .now)
        updated.status = .delivered

        let updates = store.threadUpdates(for: conversation.id)
        store.apply(.messageUpdated(updated), myID: MockData.myID)
        #expect(store.conversations.first { $0.id == conversation.id }?.lastMessage?.attachment?.openedAt != nil)
        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next() == .updated(updated))

        var thread = [last]
        thread[0].status = .read
        ChatStore.merge(.updated(updated), into: &thread, myID: MockData.myID)
        #expect(thread.count == 1)
        #expect(thread[0].attachment?.openedAt != nil)
        #expect(thread[0].status == .read) // a locally newer read status stays

        var other: [Message] = []
        ChatStore.merge(.updated(updated), into: &other, myID: MockData.myID)
        #expect(other.isEmpty)
    }

    @Test("The mock backend refuses to open your own message")
    func mockRefusesSender() async throws {
        let mock = MockAPIClient(latency: .zero)
        let conversation = try await mock.openConversation(with: "p01")
        let sent = try await mock.send(MessageDraft(clientID: "vo", text: "hi", isViewOnce: true), in: conversation.id)
        await #expect(throws: APIError.notFound) {
            try await mock.openViewOnce(messageID: sent.id, in: conversation.id)
        }
    }
}

@MainActor
@Suite("Privacy cover")
struct PrivacyCoverTests {
    private func cover(enabled: Bool?) -> PrivacyCover {
        let defaults = UserDefaults(suiteName: "stexx.tests.cover.\(UUID().uuidString)")!
        if let enabled { defaults.set(enabled, forKey: PrivacyCover.enabledKey) }
        return PrivacyCover(defaults: defaults)
    }

    @Test("On by default: covers when the app deactivates or goes to the background, not when it's active")
    func onByDefault() {
        let cover = cover(enabled: nil)
        #expect(cover.isEnabled)
        #expect(cover.wantsCover(after: .willDeactivate))
        #expect(cover.wantsCover(after: .didEnterBackground))
        #expect(!cover.wantsCover(after: .didActivate))
    }

    @Test("Turned off in Settings: never covers")
    func off() {
        let cover = cover(enabled: false)
        #expect(!cover.wantsCover(after: .willDeactivate))
        #expect(!cover.wantsCover(after: .didEnterBackground))
    }

    @Test("A system prompt the app started doesn't flash the cover, but the background still does")
    func systemPrompt() {
        let cover = cover(enabled: true)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        cover.expectSystemPrompt(now: now)
        #expect(!cover.wantsCover(after: .willDeactivate, now: now.addingTimeInterval(1)))
        #expect(cover.wantsCover(after: .didEnterBackground, now: now.addingTimeInterval(1)))
        // Only for a short while after asking.
        #expect(cover.wantsCover(after: .willDeactivate, now: now.addingTimeInterval(PrivacyCover.systemPromptWindow + 1)))
    }

    @Test("The exemption is single-use: the prompt's deactivation spends it, the next one covers")
    func systemPromptSingleUse() {
        let cover = cover(enabled: true)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        cover.expectSystemPrompt(now: now)
        #expect(!cover.handle(.willDeactivate, now: now.addingTimeInterval(1)))
        // Going to the background while the prompt is up still covers, and doesn't need the exemption back.
        #expect(cover.handle(.didEnterBackground, now: now.addingTimeInterval(2)))
        #expect(cover.handle(.willDeactivate, now: now.addingTimeInterval(3)))
    }

    @Test("Reactivating ends the exemption")
    func systemPromptEndsOnActivate() {
        let cover = cover(enabled: true)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        cover.expectSystemPrompt(now: now)
        #expect(!cover.handle(.didActivate, now: now.addingTimeInterval(1)))
        #expect(cover.handle(.willDeactivate, now: now.addingTimeInterval(2)))
    }

    @Test("A prompt that never appeared (the call returned first) leaves the next deactivation covered")
    func systemPromptEndedByCaller() {
        let cover = cover(enabled: true)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        cover.expectSystemPrompt(now: now)
        cover.endSystemPrompt()
        #expect(cover.handle(.willDeactivate, now: now.addingTimeInterval(1)))
    }
}
