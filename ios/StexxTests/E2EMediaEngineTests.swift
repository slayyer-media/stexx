import Foundation
import Testing
import UIKit
@testable import Stexx

enum MediaFixtures {
    /// A real (tiny) JPEG, so decoding works.
    static let jpeg: Data = {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 9), format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 9))
        }
        return image.jpegData(compressionQuality: 0.8)!
    }()
}

/// Encrypted photos through the engine: two devices with real libsignal
/// sessions talking through `FakeE2EServer`.
@Suite("E2E media: engine and history")
struct E2EMediaEngineTests {
    private let jpeg = MediaFixtures.jpeg

    private func pair(clock: E2EClock? = nil) async -> (FakeE2EServer, FakeDevice, FakeDevice) {
        let server = FakeE2EServer()
        let now: @Sendable () -> Date = { clock?.now ?? Date() }
        let alice = FakeDevice("alice", peer: "bob", server: server, now: now)
        let bob = FakeDevice("bob", peer: "alice", server: server, now: now)
        await alice.engine.syncKeys()
        await bob.engine.syncKeys()
        return (server, alice, bob)
    }

    @Test("A photo and its caption go in one envelope; the receiver gets the pointer and the exact photo")
    func photoRoundTrip() async throws {
        let (server, alice, bob) = await pair()
        let sent = try await alice.sendPhoto(jpeg, caption: "the view from here")
        #expect(sent.text == "the view from here")
        #expect(sent.encryption == .decrypted)
        let pointer = try #require(sent.e2eAttachment)
        #expect(pointer.size == jpeg.count)
        #expect(pointer.width == 12 && pointer.height == 9)

        // The server has ciphertext only: no text, an opaque blob.
        let onServer = try #require(await server.messages.last)
        #expect(onServer.text == nil)
        #expect(onServer.envelope != nil)
        #expect(onServer.attachment?.isEncrypted == true)
        let url = try #require(onServer.attachment?.url)
        let blob = try #require(await server.media[url])
        #expect(blob.range(of: jpeg.prefix(64)) == nil)

        let received = try #require(try await bob.thread().last)
        #expect(received.text == "the view from here")
        #expect(received.encryption == .decrypted)
        #expect(received.e2eAttachment == pointer)
        #expect(try E2EMediaCrypto.decrypt(blob: blob, pointer: try #require(received.e2eAttachment)) == jpeg)
        #expect(EncryptedPhotoContent.of(received, isMine: false) == .load(url, pointer))

        // A second read comes from the local history (a ratchet message decrypts once).
        #expect(try await bob.thread().last?.e2eAttachment == pointer)
    }

    @Test("A photo without a caption is still decrypted, not unsupported")
    func photoOnly() async throws {
        let (_, alice, bob) = await pair()
        _ = try await alice.sendPhoto(jpeg)
        let received = try #require(try await bob.thread().last)
        #expect(received.text == nil)
        #expect(received.encryption == .decrypted)
        #expect(received.e2eAttachment != nil)
    }

    @Test("The sender keeps its own pointer (it can't decrypt its envelope), also after a relaunch")
    func senderKeepsPointer() async throws {
        let (server, alice, _) = await pair()
        let sent = try await alice.sendPhoto(jpeg, caption: "mine")
        let pointer = try #require(sent.e2eAttachment)
        #expect(try await alice.thread().last?.e2eAttachment == pointer)

        let relaunched = FakeDevice("alice", peer: "bob", server: server, secrets: alice.secrets, history: alice.history)
        let mine = try #require(try await relaunched.thread().last)
        #expect(mine.e2eAttachment == pointer)
        #expect(mine.text == "mine")
        #expect(EncryptedPhotoContent.of(mine, isMine: true) == .load(try #require(mine.attachment?.url), pointer))
    }

    @Test("An expiring message's key goes with the entry at expiresAt")
    func pruneAtExpiry() async throws {
        let clock = E2EClock(Date())
        let (server, alice, bob) = await pair(clock: clock)
        _ = try await alice.sendPhoto(jpeg, expiresAfterSeconds: 60)
        var message = try #require(await server.messages.last)
        message.expiresAt = clock.now.addingTimeInterval(60)
        #expect(await bob.engine.reveal(message).e2eAttachment != nil)

        clock.advance(61)
        let relaunched = FakeDevice("bob", peer: "alice", server: server, secrets: bob.secrets, history: bob.history, now: { clock.now })
        let revealed = await relaunched.engine.reveal(message)
        #expect(revealed.e2eAttachment == nil)
        #expect(revealed.encryption == .unavailable)
        #expect(try bob.history.load(userID: "bob")?.messages[message.id] == nil)
        #expect(EncryptedPhotoContent.of(revealed, isMine: false) == .unavailable)
    }

    @Test("The sender drops an expiring photo's key at the server's cap even if it never learns expiresAt")
    func senderCap() async throws {
        let clock = E2EClock(Date())
        let (server, alice, _) = await pair(clock: clock)
        _ = try await alice.sendPhoto(jpeg, caption: "for a minute", expiresAfterSeconds: 3600)
        #expect(try await alice.thread().last?.e2eAttachment != nil)

        clock.advance(14 * 24 * 3600 + 3600 + 1)
        let relaunched = FakeDevice("alice", peer: "bob", server: server, secrets: alice.secrets, history: alice.history, now: { clock.now })
        let mine = try #require(try await relaunched.thread().last)
        #expect(mine.e2eAttachment == nil)
        #expect(mine.e2eAttachmentRemoval == .gone)
        // The text stays.
        #expect(mine.text == "for a minute")
        #expect(EncryptedPhotoContent.of(mine, isMine: true) == .gone)
    }

    @Test("Closing a view-once photo forgets its key and stamps viewOnceOpenedAt")
    func forgetViewOnceKey() async throws {
        let (_, alice, bob) = await pair()
        _ = try await alice.sendPhoto(jpeg, isViewOnce: true)
        let received = try #require(try await bob.thread().last)
        #expect(received.attachment?.isViewOnce == true)
        #expect(received.e2eAttachment != nil)
        #expect(EncryptedPhotoContent.of(received, isMine: false) == .viewOnce(canOpen: true))
        // The sender's bubble can't be opened.
        #expect(EncryptedPhotoContent.of(try #require(try await alice.thread().last), isMine: true) == .viewOnce(canOpen: false))

        await bob.engine.forgetAttachmentKey(messageID: received.id)
        let entry = try #require(try bob.history.load(userID: "bob")?.messages[received.id])
        #expect(entry.attachment == nil)
        #expect(entry.viewOnceOpenedAt != nil)

        let after = try #require(try await bob.thread().last)
        #expect(after.e2eAttachment == nil)
        #expect(after.e2eAttachmentRemoval == .opened)
        #expect(EncryptedPhotoContent.of(after, isMine: false) == .opened)
    }

    @Test("An unopened view-once photo's key goes after the server's 14-day cap")
    func unopenedViewOnceCap() async throws {
        let clock = E2EClock(Date())
        let (server, alice, bob) = await pair(clock: clock)
        _ = try await alice.sendPhoto(jpeg, isViewOnce: true)
        #expect(try await bob.thread().last?.e2eAttachment != nil)

        clock.advance(15 * 24 * 3600 + 1)
        let relaunched = FakeDevice("bob", peer: "alice", server: server, secrets: bob.secrets, history: bob.history, now: { clock.now })
        let after = try #require(try await relaunched.thread().last)
        #expect(after.e2eAttachment == nil)
        #expect(after.e2eAttachmentRemoval == .gone)
    }

    @Test("A photo the server no longer has (url null in the listing) drops its key")
    func spentDropsKey() async throws {
        let (server, alice, bob) = await pair()
        _ = try await alice.sendPhoto(jpeg)
        let received = try #require(try await bob.thread().last)
        #expect(received.e2eAttachment != nil)

        await server.spendAttachment(of: received.id)
        let after = try #require(try await bob.thread().last)
        #expect(after.e2eAttachment == nil)
        #expect(after.e2eAttachmentRemoval == .gone)
        #expect(try bob.history.load(userID: "bob")?.messages[received.id]?.attachment == nil)
        #expect(EncryptedPhotoContent.of(after, isMine: false) == .gone)
    }

    @Test("A pointer from a newer version (v: 2) makes the message unsupported")
    func unsupportedPointer() async throws {
        let (server, alice, bob) = await pair()
        var pointer = try E2EMediaCrypto.encrypt(jpeg: jpeg).pointer
        pointer.v = 2
        #expect(try await alice.engine.route(text: nil, to: "bob", conversationID: FakeE2EServer.conversationID) == .encrypt)
        let envelope = try await alice.engine.seal(E2EPayload(attachment: pointer), to: "bob", conversationID: FakeE2EServer.conversationID, clientID: "future")
        let upload = try await server.uploadEncryptedAttachment(Data(repeating: 9, count: 600), as: "alice")
        _ = try await server.send(MessageDraft(clientID: "future", envelope: envelope, attachmentPhotoID: upload.id), as: "alice")

        let received = try #require(try await bob.thread().last)
        #expect(received.encryption == .unsupported)
        #expect(received.e2eAttachment == nil)
        #expect(EncryptedPhotoContent.of(received, isMine: false) == .unsupported)
    }

    @Test("An encrypted photo whose envelope has no pointer is 'not available on this phone'")
    func missingPointer() async throws {
        let (server, alice, bob) = await pair()
        #expect(try await alice.engine.route(text: nil, to: "bob", conversationID: FakeE2EServer.conversationID) == .encrypt)
        let envelope = try await alice.engine.seal(E2EPayload(text: nil), to: "bob", conversationID: FakeE2EServer.conversationID, clientID: "nopointer")
        let upload = try await server.uploadEncryptedAttachment(Data(repeating: 9, count: 600), as: "alice")
        _ = try await server.send(MessageDraft(clientID: "nopointer", envelope: envelope, attachmentPhotoID: upload.id), as: "alice")

        let received = try #require(try await bob.thread().last)
        #expect(received.e2eAttachment == nil)
        #expect(received.encryption == .decrypted)
        #expect(EncryptedPhotoContent.of(received, isMine: false) == .unavailable)
    }

    @Test("After a reinstall, an old encrypted photo is 'not available on this phone', never a broken image")
    func reinstallUnavailable() async throws {
        let (server, alice, bob) = await pair()
        _ = try await alice.sendPhoto(jpeg)
        _ = try await bob.thread()
        let reinstalled = FakeDevice("bob", peer: "alice", server: server, secrets: bob.secrets)
        let message = try #require(try await reinstalled.thread().last)
        #expect(message.encryption == .unavailable)
        #expect(EncryptedPhotoContent.of(message, isMine: false) == .unavailable)
    }

    @Test("History files from before encrypted photos still load")
    func oldHistoryDecodes() throws {
        let json = #"""
        {"messages":{"m1":{"conversationID":"c1","text":"hello","storedAt":800000000}},
         "sent":{"client-1":{"conversationID":"c1","text":"sent","storedAt":800000000,"expiresAt":800003600}},
         "recentSends":[{"conversationID":"c1","normalized":"sent","sentAt":800000000}]}
        """#
        let history = try JSONDecoder().decode(E2EHistory.self, from: Data(json.utf8))
        let entry = try #require(history.messages["m1"])
        #expect(entry.text == "hello")
        #expect(entry.attachment == nil)
        #expect(entry.viewOnceOpenedAt == nil)
        #expect(entry.attachmentKeyUntil == nil)
        #expect(entry.hadAttachment == nil)
        #expect(history.sent["client-1"]?.expiresAt != nil)

        // And an entry with a pointer round-trips.
        var updated = history
        updated.messages["m2"] = .init(
            conversationID: "c1", text: nil, storedAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
            attachment: E2EAttachmentPointer(key: "a", digest: "b", size: 3)
        )
        #expect(try JSONDecoder().decode(E2EHistory.self, from: JSONEncoder().encode(updated)) == updated)
    }

    @Test("History prune: expired entries go whole, keys past attachmentKeyUntil go alone")
    func historyPrune() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let pointer = E2EAttachmentPointer(key: "a", digest: "b", size: 3)
        var history = E2EHistory()
        history.messages["expired"] = .init(conversationID: "c", text: "x", storedAt: now, expiresAt: now.addingTimeInterval(-1), attachment: pointer)
        history.messages["capped"] = .init(conversationID: "c", text: "y", storedAt: now, attachment: pointer, attachmentKeyUntil: now.addingTimeInterval(-1))
        history.messages["live"] = .init(conversationID: "c", text: "z", storedAt: now, attachment: pointer, attachmentKeyUntil: now.addingTimeInterval(60))
        history.prune(now: now)
        #expect(history.messages["expired"] == nil)
        #expect(history.messages["capped"]?.attachment == nil)
        #expect(history.messages["capped"]?.text == "y")
        #expect(history.messages["capped"]?.hadAttachment == true)
        #expect(history.messages["live"]?.attachment == pointer)
    }

    @Test("Removing a failed encrypted photo drops the blob and key kept for its retries")
    func discardUnsentPhoto() async throws {
        let (_, alice, _) = await pair()
        let first = try await alice.engine.encryptedPhoto(jpeg, clientID: "k1")
        // A retry reuses the same blob and key.
        #expect(try await alice.engine.encryptedPhoto(jpeg, clientID: "k1").pointer == first.pointer)
        await alice.client.discardUnsentPhoto(clientID: "k1")
        // Gone: the same client ID now gets a fresh key.
        #expect(try await alice.engine.encryptedPhoto(jpeg, clientID: "k1").pointer.key != first.pointer.key)
    }
}

/// How `E2EAPIClient.sendPhoto` routes a photo under each `E2E_MODE`: never
/// a plaintext upload in an encrypted chat.
@Suite("E2E media: send routing")
struct E2EMediaRoutingTests {
    private let jpeg = MediaFixtures.jpeg

    private func uploads(_ server: FakeE2EServer) async -> [Bool] { await server.uploadLog.map(\.encrypted) }

    @Test("off: plaintext upload and plaintext caption, no keys touched")
    func off() async throws {
        let server = FakeE2EServer()
        await server.set(mode: .off)
        let alice = FakeDevice("alice", peer: "bob", server: server)
        let sent = try await alice.sendPhoto(jpeg, caption: "plain")
        #expect(await uploads(server) == [false])
        #expect(await server.uploadLog.first?.data == jpeg)
        #expect(sent.envelope == nil)
        #expect(sent.text == "plain")
        #expect(sent.attachment?.isEncrypted == false)
        #expect(await server.count("bundle") == 0)
    }

    @Test("optional with keys: encrypted upload + envelope, never a plaintext upload")
    func optionalWithKeys() async throws {
        let server = FakeE2EServer()
        let alice = FakeDevice("alice", peer: "bob", server: server)
        let bob = FakeDevice("bob", peer: "alice", server: server)
        await bob.engine.syncKeys()
        let sent = try await alice.sendPhoto(jpeg, caption: "secret")
        #expect(await uploads(server) == [true])
        #expect(await server.count("upload.plaintext") == 0)
        #expect(await server.count("send.envelope") == 1)
        #expect(await server.count("send.plaintext") == 0)
        let onServer = try #require(await server.messages.last)
        #expect(onServer.text == nil)
        #expect(onServer.attachment?.isEncrypted == true)
        #expect(sent.text == "secret")
        let blob = try #require(await server.uploadLog.first?.data)
        #expect(blob != jpeg)
        #expect(try E2EMediaCrypto.decrypt(blob: blob, pointer: try #require(sent.e2eAttachment)) == jpeg)
    }

    @Test("optional without keys: plaintext upload and caption")
    func optionalWithoutKeys() async throws {
        let server = FakeE2EServer()
        let alice = FakeDevice("alice", peer: "bob", server: server)
        let sent = try await alice.sendPhoto(jpeg, caption: "you have no keys yet")
        #expect(await uploads(server) == [false])
        #expect(sent.envelope == nil)
        #expect(sent.text == "you have no keys yet")
        #expect(sent.e2eAttachment == nil)
    }

    @Test("required without keys: throws, and nothing is uploaded at all")
    func requiredWithoutKeys() async throws {
        let server = FakeE2EServer()
        await server.set(mode: .required)
        let alice = FakeDevice("alice", peer: "bob", server: server)
        await #expect(throws: E2EError.recipientHasNoKeys) {
            _ = try await alice.sendPhoto(jpeg, caption: "hello")
        }
        #expect(await server.uploadLog.isEmpty)
        #expect(await server.messages.isEmpty)
    }

    @Test("required with keys: encrypted")
    func requiredWithKeys() async throws {
        let server = FakeE2EServer()
        await server.set(mode: .required)
        let alice = FakeDevice("alice", peer: "bob", server: server)
        let bob = FakeDevice("bob", peer: "alice", server: server)
        await bob.engine.syncKeys()
        _ = try await alice.sendPhoto(jpeg)
        #expect(await uploads(server) == [true])
        #expect(try await bob.thread().last?.e2eAttachment != nil)
    }

    @Test("A pending identity change: throws, nothing uploaded")
    func identityChange() async throws {
        let server = FakeE2EServer()
        let alice = FakeDevice("alice", peer: "bob", server: server)
        let bob = FakeDevice("bob", peer: "alice", server: server)
        await alice.engine.syncKeys()
        await bob.engine.syncKeys()
        _ = try await alice.send("hey")
        _ = try await bob.thread()
        _ = try await bob.send("hey back")
        _ = try await alice.thread()

        // Bob reinstalls with a new identity; his first message is held on Alice's phone.
        let newBob = FakeDevice("bob", peer: "alice", server: server)
        await newBob.engine.syncKeys()
        _ = try await newBob.send("new phone")
        #expect(try await alice.thread().last?.encryption == .awaitingKeyConfirmation)

        let uploadsBefore = await server.uploadLog.count
        let messagesBefore = await server.messages.count
        await #expect(throws: E2EError.identityChanged(peer: "bob")) {
            _ = try await alice.sendPhoto(jpeg, caption: "still you?")
        }
        #expect(await server.uploadLog.count == uploadsBefore)
        #expect(await server.messages.count == messagesBefore)
    }

    @Test("A retry of the same client ID re-uploads the same blob and pointer; a new send gets a new key")
    func retryReusesBlob() async throws {
        let server = FakeE2EServer()
        let alice = FakeDevice("alice", peer: "bob", server: server)
        let bob = FakeDevice("bob", peer: "alice", server: server)
        await bob.engine.syncKeys()

        await server.failNextSendOnce()
        await #expect(throws: URLError.self) {
            _ = try await alice.sendPhoto(jpeg, clientID: "retry-1")
        }
        let sent = try await alice.sendPhoto(jpeg, clientID: "retry-1")
        let log = await server.uploadLog
        #expect(log.count == 2)
        #expect(log[0].encrypted && log[1].encrypted)
        #expect(log[0].data == log[1].data)
        let received = try #require(try await bob.thread().last)
        #expect(received.e2eAttachment == sent.e2eAttachment)

        let other = try await alice.sendPhoto(jpeg, clientID: "retry-2")
        #expect(other.e2eAttachment?.key != sent.e2eAttachment?.key)
        #expect(await server.uploadLog.last?.data != log[0].data)
    }

    @Test("A server that switched E2E off gets the photo as plaintext on the retry")
    func switchedOff() async throws {
        let server = FakeE2EServer()
        let alice = FakeDevice("alice", peer: "bob", server: server)
        let bob = FakeDevice("bob", peer: "alice", server: server)
        await bob.engine.syncKeys()
        _ = try await alice.send("encrypted")
        await server.set(mode: .off)
        let sent = try await alice.sendPhoto(jpeg)
        #expect(sent.envelope == nil)
        #expect(sent.attachment?.isEncrypted == false)
        // Tried encrypted first (refused), then plaintext once the config said off.
        #expect(await server.count("upload.encrypted") == 1)
        #expect(await uploads(server) == [false])
    }

    @Test("A photo uploaded elsewhere is never sent as plaintext into an encrypted chat")
    func rawSendRefusedWhenEncrypted() async throws {
        let server = FakeE2EServer()
        let alice = FakeDevice("alice", peer: "bob", server: server)
        let bob = FakeDevice("bob", peer: "alice", server: server)
        await bob.engine.syncKeys()
        let upload = try await alice.client.uploadAttachment(jpegData: jpeg)
        await #expect(throws: E2EError.encryptionFailed) {
            _ = try await alice.client.send(MessageDraft(clientID: "raw", text: "caption", attachmentPhotoID: upload.id), in: FakeE2EServer.conversationID)
        }
        #expect(await server.messages.isEmpty)
    }

    @Test("The mock behaves like E2E_MODE=off: plaintext photo sends work, encrypted uploads are refused")
    func mock() async throws {
        let api = MockAPIClient(latency: .milliseconds(1))
        let conversationID = try #require(try await api.conversations().first).id
        let sent = try await api.sendPhoto(
            jpegData: jpeg,
            draft: MessageDraft(clientID: "mock-photo", text: "hi", isViewOnce: false),
            in: conversationID
        )
        #expect(sent.attachment?.kind == .photo)
        #expect(sent.attachment?.isEncrypted == false)
        await #expect(throws: APIError.e2e(code: E2EErrorCode.disabled, message: "End-to-end encryption isn't switched on for this server yet.")) {
            _ = try await api.uploadEncryptedAttachment(Data(repeating: 1, count: 100))
        }
    }
}

/// `ChatMediaLoader`: download, verify, decrypt, memory-only cache.
@Suite("E2E media: loader")
struct ChatMediaLoaderTests {
    private struct ExplicitAnalyzer: ChatPhotoAnalyzer {
        var systemWarningsEnabled: Bool { false }
        func assess(_ image: CGImage) async -> ChatPhotoVerdict { .explicit }
    }

    @Test("Loads and caches a good photo; 404 is gone; a swapped blob is tampered; evict and clear drop it")
    func outcomes() async throws {
        let (blob, pointer) = try E2EMediaCrypto.encrypt(jpeg: MediaFixtures.jpeg)
        let other = try E2EMediaCrypto.encrypt(jpeg: MediaFixtures.jpeg).blob
        let base = StubURLProtocol.register { request in
            switch request.url?.path() {
            case "/good.bin": return (200, ["Content-Type": "application/octet-stream"], blob)
            case "/swapped.bin": return (200, [:], other)
            case "/broken.bin": return (500, [:], Data())
            default: return (404, [:], Data())
            }
        }
        let loader = ChatMediaLoader(session: StubURLProtocol.session())

        let loaded = await loader.photo(messageID: "m1", url: base.appending(path: "good.bin"), pointer: pointer, analyzer: ExplicitAnalyzer())
        guard case .image(let image, let verdict) = loaded else { Issue.record("expected an image, got \(loaded)"); return }
        #expect(image.size.width > 0)
        #expect(verdict == .explicit)
        #expect(await loader.cached("m1") != nil)

        #expect(await loader.photo(messageID: "m2", url: base.appending(path: "gone.bin"), pointer: pointer) == .gone)
        #expect(await loader.photo(messageID: "m3", url: base.appending(path: "swapped.bin"), pointer: pointer) == .tampered)
        #expect(await loader.photo(messageID: "m4", url: base.appending(path: "broken.bin"), pointer: pointer) == .failed)
        #expect(await loader.cached("m2") == nil)

        // View-once photos are never cached.
        _ = await loader.photo(messageID: "v1", url: base.appending(path: "good.bin"), pointer: pointer, caches: false)
        #expect(await loader.cached("v1") == nil)

        await loader.evict("m1")
        #expect(await loader.cached("m1") == nil)
        _ = await loader.photo(messageID: "m5", url: base.appending(path: "good.bin"), pointer: pointer)
        #expect(await loader.cached("m5") != nil)
        await loader.clear()
        #expect(await loader.cached("m5") == nil)
    }

    @Test("Decrypted photos are fetched without a disk cache")
    func privateSession() {
        let configuration = PrivateMedia.session.configuration
        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test("HTTP: an encrypted upload is an octet-stream body to /me/attachments; isEncrypted decodes")
    func httpUpload() async throws {
        let blob = Data(repeating: 0xAB, count: 600)
        let baseURL = StubURLProtocol.register { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path() == "/v1/me/attachments")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
            let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
            #expect(body == blob)
            return (201, [:], Fixtures.json(["id": "ph_1", "url": "https://media.test/abc.bin", "isExplicit": false, "isEncrypted": true]))
        }
        let client = HTTPAPIClient(
            configuration: APIConfiguration(baseURL: baseURL, useMock: false),
            session: StubURLProtocol.session(),
            sessions: SessionCoordinator(store: InMemorySessionStore(session: Session(userID: "u1", accessToken: "a", refreshToken: "r", expiresAt: nil)))
        )
        let photo = try await client.uploadEncryptedAttachment(blob)
        #expect(photo.id == "ph_1")
        #expect(HTTPAPIClient.attestedRoute("POST", "me/attachments") != nil)
    }

    @Test("Message attachments decode isEncrypted, defaulting to false when absent")
    func attachmentDecoding() throws {
        let encrypted = try JSONDecoder.stexx().decode(Message.Attachment.self, from: Data(#"{"kind":"photo","url":"https://media.test/a.bin","isViewOnce":true,"isEncrypted":true}"#.utf8))
        #expect(encrypted.isEncrypted)
        #expect(encrypted.isViewOnce)
        let old = try JSONDecoder.stexx().decode(Message.Attachment.self, from: Data(#"{"kind":"photo","url":null}"#.utf8))
        #expect(!old.isEncrypted)
        #expect(!old.isViewOnce)
        #expect(old.url == nil)
        // Local-only fields never go on the wire.
        var message = Message(id: "m", conversationID: "c", senderID: "s", text: nil, attachment: encrypted, sentAt: .now, status: .sent)
        message.e2eAttachment = E2EAttachmentPointer(key: "k", digest: "d", size: 1)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder.stexx().encode(message)) as? [String: Any])
        #expect(json["e2eAttachment"] == nil)
        #expect(!String(decoding: try JSONEncoder.stexx().encode(message), as: UTF8.self).contains("digest"))
    }

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

// MARK: Expiry during a session, timers in the envelope

extension E2EMediaEngineTests {
    private static let day: TimeInterval = 24 * 3600

    @Test("A running session prunes an expired photo key (no relaunch) and evicts its image")
    func pruneDuringSession() async throws {
        let clock = E2EClock(Date())
        let (server, alice, bob) = await pair(clock: clock)
        _ = try await alice.sendPhoto(jpeg, expiresAfterSeconds: 60)
        let id = try #require(await server.messages.last?.id)
        await server.setExpiresAt(clock.now.addingTimeInterval(60), of: id)
        #expect(try await bob.thread().last?.e2eAttachment != nil)

        clock.advance(30)
        #expect(await bob.engine.pruneHistory().isEmpty)
        clock.advance(31)
        #expect(await bob.engine.pruneHistory() == [id])
        #expect(try bob.history.load(userID: "bob")?.messages[id] == nil)
        #expect(await bob.evicted.entries.contains(id))
    }

    @Test("reveal prunes at most once a minute, so a key that expired meanwhile goes without a relaunch")
    func revealPrunesThrottled() async throws {
        let clock = E2EClock(Date())
        let (server, alice, bob) = await pair(clock: clock)
        _ = try await alice.sendPhoto(jpeg, expiresAfterSeconds: 60)
        let photo = try #require(await server.messages.last)
        await server.setExpiresAt(clock.now.addingTimeInterval(60), of: photo.id)
        _ = try await bob.thread()
        _ = try await alice.send("later")
        let text = try #require(await server.messages.last)

        clock.advance(61)
        // Revealing something else runs the prune (the last one was over a minute ago).
        _ = await bob.engine.reveal(text)
        #expect(try bob.history.load(userID: "bob")?.messages[photo.id] == nil)
        #expect(await bob.evicted.entries.contains(photo.id))
    }

    @Test("Between prunes, an entry past expiresAt shows its photo as gone and drops the key")
    func expiredEntryBetweenPrunes() async throws {
        let clock = E2EClock(Date())
        let (server, alice, bob) = await pair(clock: clock)
        _ = try await alice.sendPhoto(jpeg, caption: "brief", expiresAfterSeconds: 60)
        let id = try #require(await server.messages.last?.id)
        await server.setExpiresAt(clock.now.addingTimeInterval(60), of: id)
        #expect(try await bob.thread().last?.e2eAttachment != nil)

        clock.advance(59)
        await bob.engine.pruneHistory()
        clock.advance(2)
        // Within the prune interval: the existing entry itself is checked.
        let after = try #require(try await bob.thread().last)
        #expect(after.e2eAttachment == nil)
        #expect(after.e2eAttachmentRemoval == .gone)
        #expect(EncryptedPhotoContent.of(after, isMine: false) == .gone)
        #expect(try bob.history.load(userID: "bob")?.messages[id]?.attachment == nil)
        #expect(await bob.evicted.entries.contains(id))
    }

    @Test("A spent photo and a deleted conversation evict their decrypted images")
    func evictsOnGoneAndForget() async throws {
        let (server, alice, bob) = await pair()
        _ = try await alice.sendPhoto(jpeg)
        _ = try await alice.sendPhoto(jpeg)
        let ids = await server.messages.map(\.id)
        _ = try await bob.thread()

        await server.spendAttachment(of: ids[0])
        _ = try await bob.thread()
        #expect(await bob.evicted.entries == [ids[0]])

        try await bob.client.deleteConversation(FakeE2EServer.conversationID)
        #expect(Set(await bob.evicted.entries) == Set(ids))
        #expect(try bob.history.load(userID: "bob")?.messages.isEmpty == true)
    }

    @Test("The timer travels in the envelope: the recipient keeps the key until the cap plus the timer plus a margin")
    func recipientTimerDeadline() async throws {
        let clock = E2EClock(Date())
        let (server, alice, bob) = await pair(clock: clock)
        _ = try await alice.sendPhoto(jpeg, caption: "an hour", expiresAfterSeconds: 3600)
        let id = try #require(await server.messages.last?.id)
        let received = try #require(try await bob.thread().last)
        #expect(received.e2eAttachment != nil)
        let entry = try #require(try bob.history.load(userID: "bob")?.messages[id])
        #expect(entry.expiresAfterSeconds == 3600)
        #expect(entry.attachmentKeyUntil == entry.storedAt.addingTimeInterval(14 * Self.day + 3600 + Self.day))

        // Unread (no expiresAt ever seen): kept through the sender's cap, gone after the margin.
        clock.advance(14 * Self.day + 3600 + 1)
        #expect(await bob.engine.pruneHistory().isEmpty)
        clock.advance(Self.day)
        #expect(await bob.engine.pruneHistory() == [id])
        let kept = try #require(try bob.history.load(userID: "bob")?.messages[id])
        #expect(kept.attachment == nil)
        #expect(kept.text == "an hour")
    }

    @Test("Reading the chat starts the local timer, so the entry goes when the server deletes the message")
    func markReadStampsExpiry() async throws {
        let clock = E2EClock(Date())
        let (server, alice, bob) = await pair(clock: clock)
        _ = try await alice.sendPhoto(jpeg, expiresAfterSeconds: 3600)
        let timed = try #require(await server.messages.last?.id)
        _ = try await alice.sendPhoto(jpeg)
        let untimed = try #require(await server.messages.last?.id)
        _ = try await bob.thread()

        clock.advance(600)
        let readAt = clock.now
        try await bob.client.markRead(conversationID: FakeE2EServer.conversationID)
        let history = try #require(try bob.history.load(userID: "bob"))
        #expect(history.messages[timed]?.expiresAt == readAt.addingTimeInterval(3600))
        // No timer in the envelope: nothing changes.
        #expect(history.messages[untimed]?.expiresAt == nil)
        #expect(history.messages[untimed]?.attachmentKeyUntil == nil)

        // A listing without expiresAt (fetched before the read) never clears the stamp.
        _ = try await bob.thread()
        #expect(try bob.history.load(userID: "bob")?.messages[timed]?.expiresAt == readAt.addingTimeInterval(3600))

        clock.advance(3601)
        #expect(await bob.engine.pruneHistory() == [timed])
        #expect(try bob.history.load(userID: "bob")?.messages[timed] == nil)
        #expect(try bob.history.load(userID: "bob")?.messages[untimed]?.attachment != nil)
    }

    @Test("A message that arrives while POST …/read is in flight keeps no local timer (it may be unread on the server)")
    func markReadIgnoresLateArrivals() async throws {
        let clock = E2EClock(Date())
        let (server, alice, bob) = await pair(clock: clock)
        let requestedAt = clock.now
        clock.advance(1)
        _ = try await alice.sendPhoto(jpeg, expiresAfterSeconds: 60)
        let late = try #require(await server.messages.last?.id)
        _ = try await bob.thread()
        await bob.engine.didMarkRead(conversationID: FakeE2EServer.conversationID, requestedAt: requestedAt)
        #expect(try bob.history.load(userID: "bob")?.messages[late]?.expiresAt == nil)
        // The next read (after it arrived) starts its timer.
        await bob.engine.didMarkRead(conversationID: FakeE2EServer.conversationID, requestedAt: clock.now)
        #expect(try bob.history.load(userID: "bob")?.messages[late]?.expiresAt == clock.now.addingTimeInterval(60))
    }

    @Test("E2EPayload: expiresAfterSeconds is omitted when nil, and a malformed or out-of-range one never costs the text")
    func payloadTimerCoding() throws {
        let plain = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(E2EPayload(text: "hi"))) as? [String: Any])
        #expect(Set(plain.keys) == ["text"])
        let timed = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(E2EPayload(text: "hi", expiresAfterSeconds: 3600))) as? [String: Any])
        #expect(timed["expiresAfterSeconds"] as? Int == 3600)

        func decode(_ json: String) throws -> E2EPayload { try JSONDecoder().decode(E2EPayload.self, from: Data(json.utf8)) }
        #expect(try decode(#"{"text":"hi","expiresAfterSeconds":60}"#).timer == 60)
        let malformed = try decode(#"{"text":"hi","expiresAfterSeconds":"soon","future":true}"#)
        #expect(malformed.text == "hi")
        #expect(malformed.expiresAfterSeconds == nil)
        #expect(try decode(#"{"text":"hi","expiresAfterSeconds":0}"#).timer == nil)
        #expect(try decode(#"{"text":"hi","expiresAfterSeconds":2592001}"#).timer == nil)
        #expect(try decode(#"{"text":"old"}"#) == E2EPayload(text: "old"))
    }
}

// MARK: Plaintext uploads only on a fresh config

extension E2EMediaRoutingTests {
    @Test("A stale cached 'off' never uploads plaintext: the config is re-read and the photo goes encrypted")
    func staleOffRoutesAgain() async throws {
        let server = FakeE2EServer()
        await server.set(mode: .off)
        let alice = FakeDevice("alice", peer: "bob", server: server)
        #expect(try await alice.engine.currentConfig().mode == .off)
        await server.set(mode: .required)
        let bob = FakeDevice("bob", peer: "alice", server: server)
        await bob.engine.syncKeys()

        let sent = try await alice.sendPhoto(jpeg, caption: "fresh")
        #expect(await uploads(server) == [true])
        #expect(await server.count("upload.plaintext") == 0)
        #expect(sent.e2eAttachment != nil)
    }

    @Test("No fresh config before a plaintext upload: throws, nothing uploaded")
    func plaintextNeedsFreshConfig() async throws {
        let server = FakeE2EServer()
        let alice = FakeDevice("alice", peer: "bob", server: server)
        _ = try await alice.engine.currentConfig()
        await server.set(failConfig: true)
        await #expect(throws: URLError.self) {
            _ = try await alice.sendPhoto(jpeg, caption: "no keys yet")
        }
        #expect(await server.uploadLog.isEmpty)
        #expect(await server.messages.isEmpty)
        // Text keeps falling back to the cached config.
        let text = try await alice.send("hello")
        #expect(text.envelope == nil)
    }

    @Test("encryption_required after a plaintext upload and the config can't be re-read: the original error, no second upload")
    func retryNeedsFreshConfig() async throws {
        let server = FakeE2EServer()
        let alice = FakeDevice("alice", peer: "bob", server: server)
        await server.afterNextPlaintextUpload(mode: .required, failConfig: true)
        await #expect(throws: APIError.e2e(code: E2EErrorCode.encryptionRequired, message: "required")) {
            _ = try await alice.sendPhoto(jpeg)
        }
        #expect(await uploads(server) == [false])
        #expect(await server.messages.isEmpty)
    }
}

// MARK: Loader: races and size bounds

/// Streams an endless body in chunks until the client cancels (or a cap),
/// recording how much it sent.
private final class EndlessURLProtocol: URLProtocol, @unchecked Sendable {
    static let chunk = 256 * 1024
    static let cap = 400 * chunk
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sent: [String: Int] = [:]
    nonisolated(unsafe) private static var stopped: Set<String> = []

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EndlessURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func sentBytes(_ host: String) -> Int { lock.withLock { sent[host] ?? 0 } }
    static func wasStopped(_ host: String) -> Bool { lock.withLock { stopped.contains(host) } }

    private var loadingTask: Task<Void, Never>?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let host = url.host() ?? ""
        loadingTask = Task {
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            var total = 0
            while total < Self.cap, !Task.isCancelled {
                client?.urlProtocol(self, didLoad: Data(count: Self.chunk))
                total += Self.chunk
                Self.lock.withLock { Self.sent[host] = total }
                try? await Task.sleep(for: .milliseconds(5))
            }
            if !Task.isCancelled { client?.urlProtocolDidFinishLoading(self) }
        }
    }

    override func stopLoading() {
        let host = request.url?.host() ?? ""
        Self.lock.withLock { _ = Self.stopped.insert(host) }
        loadingTask?.cancel()
    }
}

extension ChatMediaLoaderTests {
    @Test("A load that outlives clear() or evict() of its photo returns the image but doesn't cache it")
    func clearDuringLoad() async throws {
        let (blob, pointer) = try E2EMediaCrypto.encrypt(jpeg: MediaFixtures.jpeg)
        let clearGate = Gate()
        let evictGate = Gate()
        let started = CallLog()
        let base = StubURLProtocol.register { request in
            let path = request.url?.path() ?? ""
            await started.record(path)
            if path == "/c1.bin" { await clearGate.wait() } else { await evictGate.wait() }
            return (200, [:], blob)
        }
        let loader = ChatMediaLoader(session: StubURLProtocol.session())
        func waitForStarts(_ count: Int) async throws {
            while await started.entries.count < count { try await Task.sleep(for: .milliseconds(5)) }
        }

        // Signed out while it loaded.
        let cleared = Task { await loader.photo(messageID: "c1", url: base.appending(path: "c1.bin"), pointer: pointer) }
        try await waitForStarts(1)
        await loader.clear()
        await clearGate.open()
        guard case .image = await cleared.value else { Issue.record("expected an image"); return }
        #expect(await loader.cached("c1") == nil)

        // Its key forgotten while it loaded; another photo loading meanwhile is cached.
        let evicted = Task { await loader.photo(messageID: "e1", url: base.appending(path: "e1.bin"), pointer: pointer) }
        let other = Task { await loader.photo(messageID: "o1", url: base.appending(path: "o1.bin"), pointer: pointer) }
        try await waitForStarts(3)
        await loader.evict("e1")
        await evictGate.open()
        guard case .image = await evicted.value else { Issue.record("expected an image"); return }
        _ = await other.value
        #expect(await loader.cached("e1") == nil)
        #expect(await loader.cached("o1") != nil)

        // Later loads cache again.
        _ = await loader.photo(messageID: "e1", url: base.appending(path: "e1.bin"), pointer: pointer)
        #expect(await loader.cached("e1") != nil)
    }

    @Test("A body announced as longer than any blob is refused before it's read")
    func oversizedContentLength() async throws {
        let (blob, pointer) = try E2EMediaCrypto.encrypt(jpeg: MediaFixtures.jpeg)
        let base = StubURLProtocol.register { _ in
            (200, ["Content-Length": "\(E2EMediaCrypto.maxBlobLength + 1)"], blob)
        }
        let loader = ChatMediaLoader(session: StubURLProtocol.session())
        #expect(await loader.photo(messageID: "big", url: base.appending(path: "big.bin"), pointer: pointer) == .tampered)
        #expect(await loader.cached("big") == nil)
    }

    @Test("An endless body is cut off just past the blob limit, not buffered")
    func endlessBody() async throws {
        let pointer = try E2EMediaCrypto.encrypt(jpeg: MediaFixtures.jpeg).pointer
        let host = "endless-\(UUID().uuidString.prefix(8).lowercased()).test"
        let loader = ChatMediaLoader(session: EndlessURLProtocol.session())
        let outcome = await loader.photo(messageID: "endless", url: URL(string: "https://\(host)/blob.bin")!, pointer: pointer)
        #expect(outcome == .tampered)
        // URLSession calls stopLoading on its own queue after the cancel, which
        // can land just after the loader returns, so give it a moment.
        for _ in 0..<100 where !EndlessURLProtocol.wasStopped(host) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(EndlessURLProtocol.wasStopped(host))
        #expect(EndlessURLProtocol.sentBytes(host) < EndlessURLProtocol.cap)
    }
}
