import Foundation
import Testing
@testable import Stexx

/// Chat history paging, mute, photo timers, failed sends and VoiceOver
/// labels.
@Suite("Chat: history paging")
struct ThreadHistoryTests {
    private static let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func message(_ id: String, at seconds: TimeInterval, from sender: Profile.ID = "p1", status: Message.Status = .delivered, clientID: String? = nil) -> Message {
        Message(id: id, conversationID: "c1", senderID: sender, text: id, attachment: nil,
                sentAt: Self.base.addingTimeInterval(seconds), status: status, expiresAt: nil, clientID: clientID)
    }

    private func page(_ items: [Message], next: Message.ID?) -> Page<Message> {
        Page(items: items, nextCursor: next)
    }

    @Test("The first page sets the cursor to the page's oldest message; a page without older ones ends paging")
    func firstPage() {
        var history = ThreadHistory()
        history.applyLatest(page([message("m50", at: 50), message("m51", at: 51)], next: "m50"), myID: "me")
        #expect(history.messages.map(\.id) == ["m50", "m51"])
        #expect(history.olderCursor == "m50")
        #expect(history.hasOlder)

        var short = ThreadHistory()
        short.applyLatest(page([message("m1", at: 1)], next: nil), myID: "me")
        #expect(short.olderCursor == nil)
        #expect(!short.hasOlder)
    }

    @Test("An older page goes in front, oldest first; overlapping messages aren't duplicated; the old top is the anchor")
    func olderPagePrepends() {
        var history = ThreadHistory()
        history.applyLatest(page([message("m3", at: 3), message("m4", at: 4)], next: "m3"), myID: "me")
        // The window shifted (a new message arrived), so the older page overlaps by one.
        let anchor = history.applyOlder(page([message("m1", at: 1), message("m2", at: 2), message("m3", at: 3)], next: "m1"))
        #expect(history.messages.map(\.id) == ["m1", "m2", "m3", "m4"])
        #expect(history.olderCursor == "m1")
        #expect(anchor?.id == "m3")
        #expect(ThreadHistory.scrollAnchor(previousFirst: anchor, in: history.messages) == history.messages[2].bubbleKey)

        // The start of the thread: no cursor any more.
        history.applyOlder(page([message("m0", at: 0)], next: nil))
        #expect(history.messages.map(\.id) == ["m0", "m1", "m2", "m3", "m4"])
        #expect(!history.hasOlder)
    }

    @Test("Dedupe also matches my optimistic copy by client ID")
    func dedupeByClientID() {
        let pendingCopy = message("local-k1", at: 5, from: "me", status: .sending, clientID: "k1")
        var history = ThreadHistory(messages: [pendingCopy], olderCursor: "x")
        history.applyOlder(page([message("m1", at: 1), message("m5", at: 5, from: "me", status: .sent, clientID: "k1")], next: nil))
        #expect(history.messages.map(\.id) == ["m1", "local-k1"])
    }

    @Test("The scroll anchor is the bubble that was on top, and nothing when the thread was empty")
    func scrollAnchor() {
        let top = message("m9", at: 9, from: "me", status: .sent, clientID: "k9")
        let merged = [message("m1", at: 1), top]
        // The bubble key survives the optimistic → sent swap (client ID).
        let optimistic = message("local-k9", at: 9, from: "me", status: .sending, clientID: "k9")
        #expect(ThreadHistory.scrollAnchor(previousFirst: optimistic, in: merged) == top.bubbleKey)
        #expect(ThreadHistory.scrollAnchor(previousFirst: nil, in: merged) == nil)
        #expect(ThreadHistory.scrollAnchor(previousFirst: message("gone", at: 0), in: merged) == nil)
    }

    @Test("A refetch of the newest page keeps loaded older pages and their cursor")
    func refetchKeepsOlderPages() {
        var history = ThreadHistory()
        history.applyLatest(page([message("m3", at: 3), message("m4", at: 4)], next: "m3"), myID: "me")
        history.applyOlder(page([message("m1", at: 1), message("m2", at: 2)], next: "m1"))
        // Resync: one new message, the window moves to m4…m5.
        history.applyLatest(page([message("m4", at: 4), message("m5", at: 5)], next: "m4"), myID: "me")
        #expect(history.messages.map(\.id) == ["m1", "m2", "m3", "m4", "m5"])
        #expect(history.olderCursor == "m1")
    }

    @Test("When the newest page is the whole thread, messages missing from it are gone")
    func completePageDropsMissing() {
        var history = ThreadHistory(messages: [message("m0", at: 0), message("m1", at: 1)], olderCursor: nil)
        history.applyLatest(page([message("m1", at: 1), message("m2", at: 2)], next: nil), myID: "me")
        #expect(history.messages.map(\.id) == ["m1", "m2"])
        #expect(history.olderCursor == nil)
    }

    @Test("reconcile with keepsOlder keeps older pages in front and unsent messages at the end")
    func reconcileKeepsOlder() {
        let local = [
            message("m1", at: 1), message("m2", at: 2), message("m3", at: 3),
            message("local-k", at: 9, from: "me", status: .failed, clientID: "k"),
        ]
        let snapshot = [message("m3", at: 3), message("m4", at: 4)]
        let kept = ChatStore.reconcile(snapshot: snapshot, with: local, myID: "me", keepsOlder: true)
        #expect(kept.map(\.id) == ["m1", "m2", "m3", "m4", "local-k"])
        let dropped = ChatStore.reconcile(snapshot: snapshot, with: local, myID: "me")
        #expect(dropped.map(\.id) == ["m3", "m4", "local-k"])
    }

    @Test("restart keeps only messages that never reached the server")
    func restart() {
        var history = ThreadHistory(messages: [message("m1", at: 1), message("local-k", at: 2, from: "me", status: .failed, clientID: "k")], olderCursor: "m1")
        history.restart()
        #expect(history.messages.map(\.id) == ["local-k"])
        #expect(history.olderCursor == nil)
    }

    @Test("Near the top means within the threshold of the content's top inset")
    func nearTop() {
        #expect(ThreadHistory.isNearTop(contentOffsetY: -100, topInset: 100))
        #expect(ThreadHistory.isNearTop(contentOffsetY: 250, topInset: 100))
        #expect(!ThreadHistory.isNearTop(contentOffsetY: 2000, topInset: 100))
    }

    private func expiring(_ id: String, at seconds: TimeInterval, expiresAt: TimeInterval?, status: Message.Status = .read) -> Message {
        var m = message(id, at: seconds, status: status)
        m.expiresAt = expiresAt.map { Self.base.addingTimeInterval($0) }
        return m
    }

    @Test("A resync keeps older pages but not messages whose timer ran out")
    func resyncDropsExpiredOlderMessages() {
        var history = ThreadHistory()
        history.applyLatest(page([message("m3", at: 3), message("m4", at: 4)], next: "m3"), myID: "me", now: Self.base)
        // An older page with a read photo on a 1-hour timer.
        history.applyOlder(page([message("m1", at: 1), expiring("m2", at: 2, expiresAt: 3602)], next: "m1"), now: Self.base)
        #expect(history.messages.map(\.id) == ["m1", "m2", "m3", "m4"])

        // The app comes back two hours later: the server deleted m2; the newest page doesn't cover it.
        let later = Self.base.addingTimeInterval(7200)
        history.applyLatest(page([message("m4", at: 4), message("m5", at: 5)], next: "m4"), myID: "me", now: later)
        #expect(history.messages.map(\.id) == ["m1", "m3", "m4", "m5"])
        #expect(history.olderCursor == "m1")
    }

    @Test("An older page never brings in a message whose timer already ran out")
    func olderPageSkipsExpired() {
        var history = ThreadHistory(messages: [message("m3", at: 3)], olderCursor: "m3")
        history.applyOlder(page([expiring("m1", at: 1, expiresAt: 10), message("m2", at: 2)], next: nil), now: Self.base.addingTimeInterval(10))
        #expect(history.messages.map(\.id) == ["m2", "m3"])
    }

    @Test("An open thread prunes at the next expiry; unsent messages never expire")
    func pruneAtNextExpiry() {
        let unsent = expiring("local-k", at: 6, expiresAt: 1, status: .failed)
        var history = ThreadHistory(messages: [
            expiring("m1", at: 1, expiresAt: 100), expiring("m2", at: 2, expiresAt: 50), message("m3", at: 3), unsent,
        ])
        #expect(history.nextExpiry(after: Self.base) == Self.base.addingTimeInterval(50))
        let prunedEarly = history.pruneExpired(now: Self.base.addingTimeInterval(49))
        #expect(!prunedEarly)
        let prunedOnTime = history.pruneExpired(now: Self.base.addingTimeInterval(50))
        #expect(prunedOnTime)
        #expect(history.messages.map(\.id) == ["m1", "m3", "local-k"])
        #expect(history.nextExpiry(after: Self.base.addingTimeInterval(50)) == Self.base.addingTimeInterval(100))
        history.pruneExpired(now: Self.base.addingTimeInterval(100))
        #expect(history.messages.map(\.id) == ["m3", "local-k"])
        #expect(history.nextExpiry(after: Self.base.addingTimeInterval(100)) == nil)
    }

    @Test("A failed send the server did get turns into the sent message on refetch")
    func failedSendDeliveredAfterAll() {
        let failed = message("local-k", at: 9, from: "me", status: .failed, clientID: "k")
        var history = ThreadHistory(messages: [message("m1", at: 1), failed])
        #expect(ThreadHistory.deliveredCopy(of: failed, in: history.messages) == nil)

        // The timeout hid a send that landed: the newest page has it under its client ID.
        history.applyLatest(page([message("m1", at: 1), message("m9", at: 9, from: "me", status: .sent, clientID: "k")], next: nil), myID: "me")
        #expect(history.messages.map(\.id) == ["m1", "m9"])
        #expect(ThreadHistory.deliveredCopy(of: failed, in: history.messages)?.id == "m9")

        // A retry still in flight isn't "delivered".
        let retrying = message("local-k", at: 9, from: "me", status: .sending, clientID: "k")
        #expect(ThreadHistory.deliveredCopy(of: failed, in: [retrying]) == nil)
    }

    @Test("Paging through the mock's long thread loads every message once, in order")
    func mockPaging() async throws {
        let api = MockAPIClient(latency: .zero)
        let conversation = try await api.openConversation(with: "p04")
        var history = ThreadHistory()
        history.applyLatest(try await api.messages(in: conversation.id, before: nil), myID: MockData.myID)
        #expect(history.messages.count == 50)
        var pages = 1
        while let cursor = history.olderCursor {
            history.applyOlder(try await api.messages(in: conversation.id, before: cursor))
            pages += 1
        }
        #expect(pages == 2)
        #expect(history.messages.count == MockData.homelabHistory.count + 2)
        #expect(Set(history.messages.map(\.id)).count == history.messages.count)
        #expect(history.messages.map(\.sentAt) == history.messages.map(\.sentAt).sorted())
    }
}

@Suite("Chat: photo timers")
struct PhotoTimerTests {
    private func wire(_ timer: PhotoTimer) throws -> [String: Any] {
        var draft = MessageDraft(clientID: "c", attachmentPhotoID: "ph1")
        timer.apply(to: &draft)
        return try #require(JSONSerialization.jsonObject(with: JSONEncoder.stexx().encode(draft)) as? [String: Any])
    }

    @Test("Each timer encodes to the draft fields the server expects")
    func encoding() throws {
        let keep = try wire(.keep)
        #expect(keep["isViewOnce"] as? Bool == false)
        #expect(keep["expiresAfterSeconds"] == nil)

        let once = try wire(.viewOnce)
        #expect(once["isViewOnce"] as? Bool == true)
        #expect(once["expiresAfterSeconds"] == nil)

        let expected: [PhotoTimer: Int] = [.tenSeconds: 10, .oneMinute: 60, .oneHour: 3600, .oneDay: 86_400]
        for (timer, seconds) in expected {
            let json = try wire(timer)
            #expect(json["expiresAfterSeconds"] as? Int == seconds)
            #expect(json["isViewOnce"] as? Bool == false)
        }
        // Every timed option is within the server's 1…2592000 range.
        for timer in PhotoTimer.allCases {
            if let seconds = timer.expiresAfterSeconds { #expect((1...2_592_000).contains(seconds)) }
        }
    }

    @Test("The default follows \"expiring photos by default\": one minute, else keep")
    func defaults() {
        #expect(PhotoTimer.default(expiringByDefault: true) == .oneMinute)
        #expect(PhotoTimer.default(expiringByDefault: false) == .keep)
    }
}

@Suite("Chat: failed sends")
@MainActor
struct FailedSendTests {
    private func makeStore(_ handler: @escaping StubURLProtocol.Handler) -> ChatStore {
        let api = HTTPAPIClient(
            configuration: APIConfiguration(baseURL: StubURLProtocol.register(handler), useMock: false),
            session: StubURLProtocol.session(),
            sessions: SessionCoordinator(store: InMemorySessionStore(session: Session(userID: "u1", accessToken: "t", refreshToken: "r", expiresAt: nil)))
        )
        return ChatStore(api: api, defaults: UserDefaults(suiteName: "stexx.tests.\(UUID().uuidString)")!)
    }

    nonisolated private static func body(_ request: URLRequest) -> [String: Any] {
        let data = request.httpBody ?? request.httpBodyStream.map(read) ?? Data()
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    nonisolated private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private struct SentFields: Sendable, Equatable {
        let clientID: String?
        let expiresAfterSeconds: Int?
        let isViewOnce: Bool?
    }

    private actor Sends {
        var bodies: [SentFields] = []
        func add(_ body: [String: Any]) -> Int {
            bodies.append(SentFields(
                clientID: body["clientID"] as? String,
                expiresAfterSeconds: body["expiresAfterSeconds"] as? Int,
                isViewOnce: body["isViewOnce"] as? Bool
            ))
            return bodies.count
        }
    }

    @Test("A photo refused with 429 is retried with the same client ID, photo and timer")
    func photoRetry() async throws {
        let sends = Sends()
        let sent = Message(id: "m1", conversationID: "c1", senderID: "u1", text: nil,
                           attachment: Message.Attachment(kind: .photo, url: nil), sentAt: .now,
                           status: .sent, expiresAt: nil, clientID: "k1")
        let store = makeStore { request in
            switch (request.httpMethod, request.url?.path() ?? "") {
            case ("POST", "/v1/me/attachments"):
                return (201, [:], Fixtures.json(["id": "ph1", "url": "https://media.test/ph1.jpg", "isExplicit": false]))
            case ("POST", "/v1/conversations/c1/messages"):
                let attempt = await sends.add(Self.body(request))
                if attempt == 1 { return (429, ["Retry-After": "120"], Fixtures.error("rate_limited")) }
                return (201, [:], try JSONEncoder.stexx().encode(sent))
            default:
                return (404, [:], Fixtures.error("not_found"))
            }
        }
        let conversation = Conversation(id: "c1", participant: MockData.profiles[0], lastMessage: nil, unreadCount: 0, updatedAt: .now)

        var failure: SendFailure?
        do {
            _ = try await store.sendPhoto(jpegData: Data([0xFF, 0xD8]), clientID: "k1", timer: .oneHour, in: conversation)
        } catch {
            failure = SendFailure(error, now: Date(timeIntervalSince1970: 0))
        }
        #expect(failure?.kind == .rateLimited)
        #expect(failure?.retryAfter == Date(timeIntervalSince1970: 120))
        #expect(failure?.canRetry == true)
        #expect(store.hasPendingPhoto(clientID: "k1"))
        #expect(store.pendingPhotoTimer(clientID: "k1") == .oneHour)

        // Retry: no photo, no timer passed; both come from the first attempt.
        let message = try await store.sendPhoto(clientID: "k1", in: conversation)
        #expect(message.id == "m1")
        #expect(!store.hasPendingPhoto(clientID: "k1"))
        let bodies = await sends.bodies
        #expect(bodies.count == 2)
        let expected = SentFields(clientID: "k1", expiresAfterSeconds: 3600, isViewOnce: false)
        #expect(bodies == [expected, expected])
    }

    @Test("Deleting a failed photo forgets it: a retry can't send it any more")
    func discard() async throws {
        let store = makeStore { _ in (503, [:], Fixtures.error("unavailable")) }
        let conversation = Conversation(id: "c1", participant: MockData.profiles[0], lastMessage: nil, unreadCount: 0, updatedAt: .now)
        await #expect(throws: (any Error).self) {
            _ = try await store.sendPhoto(jpegData: Data([0xFF, 0xD8]), clientID: "k2", timer: .viewOnce, in: conversation)
        }
        #expect(store.hasPendingPhoto(clientID: "k2"))
        store.discardPendingPhoto(clientID: "k2")
        #expect(!store.hasPendingPhoto(clientID: "k2"))
        await #expect(throws: APIError.invalidResponse) {
            _ = try await store.sendPhoto(clientID: "k2", in: conversation)
        }
    }

    @Test("The live client keeps the server's error code")
    func errorCodeParsed() async throws {
        let baseURL = StubURLProtocol.register { _ in
            (403, [:], Fixtures.json(["code": "new_account_limit", "message": "New accounts can start 3 new chats a day."]))
        }
        let client = HTTPAPIClient(
            configuration: APIConfiguration(baseURL: baseURL, useMock: false),
            session: StubURLProtocol.session(),
            sessions: SessionCoordinator(store: InMemorySessionStore(session: Session(userID: "u1", accessToken: "t", refreshToken: "r", expiresAt: nil)))
        )
        do {
            _ = try await client.send(MessageDraft(clientID: "k", text: "hi"), in: "c1")
            Issue.record("Expected a refusal")
        } catch {
            #expect(error as? APIError == .server(status: 403, message: "New accounts can start 3 new chats a day.", code: "new_account_limit"))
            let failure = SendFailure(error)
            #expect(failure.kind == .newAccountLimit)
            #expect(failure.reason == "New accounts can start 3 new chats a day.")
        }
    }

    @Test("Refusals map to friendly reasons")
    func mapping() {
        let now = Date(timeIntervalSince1970: 1000)
        let limited = SendFailure(APIError.rateLimited(retryAfter: 600), now: now)
        #expect(limited.kind == .rateLimited)
        #expect(limited.reason == APIError.rateLimitedMessage(retryAfter: 600))
        #expect(limited.retryAfter == Date(timeIntervalSince1970: 1600))
        #expect(SendFailure(APIError.rateLimited(retryAfter: nil)).retryAfter == nil)

        #expect(SendFailure(APIError.server(status: 403, message: nil, code: "links_not_allowed")).kind == .linksNotAllowed)
        #expect(SendFailure(APIError.server(status: 403, message: "x", code: "duplicate_message")).kind == .duplicate)
        let review = SendFailure(APIError.server(status: 403, message: "Reviewed.", code: "account_under_review"))
        #expect(review.kind == .underReview)
        #expect(review.reason == "Reviewed.")
        // No message from the server: the app's own wording.
        #expect(!SendFailure(APIError.server(status: 403, message: nil, code: "new_account_limit")).reason.isEmpty)

        let keyChange = SendFailure(E2EError.identityChanged(peer: "p1"))
        #expect(keyChange.kind == .keyChange)
        #expect(keyChange.canRetry)
        #expect(SendFailure(E2EContentRules.Violation.linksNotAllowed).kind == .linksNotAllowed)
        #expect(SendFailure(APIError.e2e(code: E2EErrorCode.encryptionRequired, message: nil)).kind == .encryption)

        let gone = SendFailure(APIError.notFound)
        #expect(gone.kind == .unavailable)
        #expect(!gone.canRetry)
        #expect(SendFailure(URLError(.notConnectedToInternet)).kind == .other)
    }

    @Test("A failure that may have reached the server says so; one that never left doesn't")
    func mayHaveSent() {
        for code: URLError.Code in [.timedOut, .networkConnectionLost] {
            let failure = SendFailure(URLError(code))
            #expect(failure.mayHaveSent)
            #expect(failure.reason.hasPrefix("May not have been sent"))
            #expect(failure.canRetry)
        }
        #expect(SendFailure(APIError.server(status: 502, message: nil)).mayHaveSent)
        for error: any Error in [
            URLError(.notConnectedToInternet), URLError(.cannotConnectToHost),
            APIError.rateLimited(retryAfter: 5), APIError.server(status: 403, message: nil, code: "links_not_allowed"),
            APIError.notFound, E2EError.identityChanged(peer: "p1"),
        ] {
            #expect(!SendFailure(error).mayHaveSent)
        }
    }
}

@Suite("Chat: mute")
@MainActor
struct MuteTests {
    @Test("The live client PUTs to mute and DELETEs to unmute")
    func http() async throws {
        let log = CallLog()
        let baseURL = StubURLProtocol.register { request in
            await log.record("\(request.httpMethod ?? "?") \(request.url?.path() ?? "")")
            return (204, [:], Data())
        }
        let client = HTTPAPIClient(
            configuration: APIConfiguration(baseURL: baseURL, useMock: false),
            session: StubURLProtocol.session(),
            sessions: SessionCoordinator(store: InMemorySessionStore(session: Session(userID: "u1", accessToken: "t", refreshToken: "r", expiresAt: nil)))
        )
        try await client.setMuted(true, conversationID: "c1")
        try await client.setMuted(false, conversationID: "c1")
        #expect(await log.entries == ["PUT /v1/conversations/c1/mute", "DELETE /v1/conversations/c1/mute"])
    }

    @Test("Muting drops a chat from the badge at once; the mock keeps it muted")
    func badge() async throws {
        let api = MockAPIClient(latency: .zero)
        let store = ChatStore(api: api, defaults: UserDefaults(suiteName: "stexx.tests.\(UUID().uuidString)")!)
        await store.load()
        let unread = try #require(store.conversations.first { $0.unreadCount > 0 })
        let before = store.unreadTotal

        #expect(await store.setMuted(true, conversationID: unread.id))
        #expect(store.unreadTotal == before - unread.unreadCount)
        await store.load()
        #expect(store.conversations.first { $0.id == unread.id }?.isMuted == true)

        #expect(await store.setMuted(false, conversationID: unread.id))
        #expect(store.unreadTotal == before)
    }

    @Test("A refused mute is put back")
    func rollback() async throws {
        let baseURL = StubURLProtocol.register { request in
            if request.url?.path() == "/v1/conversations" {
                let conversation: [String: Any] = ["id": "c1", "participant": Fixtures.profile, "lastMessage": NSNull(),
                                                   "unreadCount": 2, "updatedAt": "2026-11-17T20:30:00Z", "isMuted": false]
                return (200, [:], Fixtures.json([conversation]))
            }
            return (404, [:], Fixtures.error("not_found"))
        }
        let api = HTTPAPIClient(
            configuration: APIConfiguration(baseURL: baseURL, useMock: false),
            session: StubURLProtocol.session(),
            sessions: SessionCoordinator(store: InMemorySessionStore(session: Session(userID: "u1", accessToken: "t", refreshToken: "r", expiresAt: nil)))
        )
        let store = ChatStore(api: api, defaults: UserDefaults(suiteName: "stexx.tests.\(UUID().uuidString)")!)
        await store.load()
        #expect(store.unreadTotal == 2)
        #expect(await store.setMuted(true, conversationID: "c1") == false)
        #expect(store.conversations.first?.isMuted == false)
        #expect(store.unreadTotal == 2)
        #expect(store.errorMessage != nil)
    }
}

@Suite("Chat: VoiceOver labels")
struct MessageAccessibilityTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func message(text: String?, status: Message.Status = .delivered, attachment: Message.Attachment? = nil, expiresAt: Date? = nil) -> Message {
        Message(id: "m1", conversationID: "c1", senderID: "p1", text: text, attachment: attachment,
                sentAt: now.addingTimeInterval(-60), status: status, expiresAt: expiresAt, clientID: nil)
    }

    @Test("A bubble reads sender, text, time and, for mine, the status")
    func textBubble() {
        let calendar = Calendar(identifier: .gregorian)
        let time = MessageAccessibility.time(now.addingTimeInterval(-60), now: now, calendar: calendar)
        let theirs = MessageAccessibility.label(for: message(text: "Hi"), isMine: false, senderName: "Alex", now: now, calendar: calendar)
        #expect(theirs == "Alex, Hi, \(time)")
        let mine = MessageAccessibility.label(for: message(text: "Hey", status: .read), isMine: true, senderName: "Alex", now: now, calendar: calendar)
        #expect(mine == "You, Hey, \(time), Read")
        let failed = MessageAccessibility.label(for: message(text: "Hey", status: .failed), isMine: true, senderName: "Alex", now: now, calendar: calendar)
        #expect(failed.hasSuffix("Send failed"))
    }

    @Test("Photos read their kind, state and timer")
    func photos() {
        let viewOnce = message(text: nil, attachment: Message.Attachment(kind: .photo, url: nil, isViewOnce: true))
        let closed = MessageAccessibility.label(for: viewOnce, isMine: false, senderName: "Alex", photo: .viewOnceClosed, now: now)
        #expect(closed.hasPrefix("Alex, View-once photo, not opened, "))
        let opened = MessageAccessibility.label(for: viewOnce, isMine: true, senderName: "Alex", photo: .viewOnceOpened, now: now)
        #expect(opened.contains("View-once photo, opened"))

        let expiring = message(text: nil, attachment: Message.Attachment(kind: .photo, url: URL(string: "https://media.test/a.jpg")),
                               expiresAt: now.addingTimeInterval(3600))
        let label = MessageAccessibility.label(for: expiring, isMine: false, senderName: "Alex", photo: .visible, now: now)
        #expect(label.hasPrefix("Alex, Photo, disappears "))
        // An expiry in the past isn't announced.
        let past = message(text: nil, attachment: Message.Attachment(kind: .photo, url: nil), expiresAt: now.addingTimeInterval(-5))
        #expect(!MessageAccessibility.label(for: past, isMine: false, senderName: "Alex", photo: .gone, now: now).contains("disappears"))
    }

    @Test("An encrypted message this phone can't read reads its placeholder")
    func placeholder() {
        let label = MessageAccessibility.label(for: message(text: nil), isMine: false, senderName: "Alex",
                                               placeholder: "Encrypted message. Not available on this phone.", now: now)
        #expect(label.contains("Encrypted message. Not available on this phone."))
    }
}
