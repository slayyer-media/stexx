import Foundation
import Testing
@testable import Stexx

/// Keychain storage, the encrypted history file, and the wire models.
struct E2EStorageTests {
    @Test("Keychain storage reads, updates, lists and deletes this-device-only items")
    func keychain() throws {
        let storage = KeychainSecretStorage(service: "gay.stexx.app.e2e.tests.\(UUID().uuidString)")
        defer { try? storage.deleteAll(withPrefix: "") }
        #expect(try storage.read("u1/identity") == nil)
        try storage.write(Data([1, 2, 3]), for: "u1/identity")
        try storage.write(Data([4]), for: "u1/identity")
        try storage.write(Data([5]), for: "u2/identity")
        #expect(try storage.read("u1/identity") == Data([4]))
        #expect(try Set(storage.keys(withPrefix: "u1/")) == ["u1/identity"])
        try storage.deleteAll(withPrefix: "u1/")
        #expect(try storage.read("u1/identity") == nil)
        #expect(try storage.read("u2/identity") == Data([5]))
    }

    @Test("The protocol store round-trips its identity and survives a reload")
    func protocolStorePersists() throws {
        let storage = InMemorySecretStorage()
        let created = try E2EProtocolStore.loadOrCreate(storage: storage, userID: "u1")
        let loaded = try #require(try E2EProtocolStore.load(storage: storage, userID: "u1"))
        #expect(loaded.identityKeyBase64 == created.identityKeyBase64)
        #expect(loaded.state.registrationID == created.state.registrationID)
        #expect((1...16380).contains(created.state.registrationID))
        #expect(try E2EProtocolStore.load(storage: storage, userID: "u2") == nil)
    }

    @Test("A failed Keychain write fails the operation instead of keeping unsaved state")
    func failedWrite() throws {
        let storage = InMemorySecretStorage()
        let store = try E2EProtocolStore.loadOrCreate(storage: storage, userID: "u1")
        storage.failWrites = true
        #expect(throws: (any Error).self) { try store.updateState { $0.epoch = 9 } }
        #expect(store.state.epoch == 0)
    }

    @Test("History is sealed with a Keychain key; without the key it's unreadable")
    func encryptedHistory() throws {
        // A space in the path, like the real "Application Support".
        let directory = FileManager.default.temporaryDirectory.appending(path: "e2e history \(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let secrets = InMemorySecretStorage()
        let persistence = EncryptedFileHistoryPersistence(secrets: secrets, directory: directory)
        var history = E2EHistory()
        history.messages["m1"] = .init(conversationID: "c1", text: "secret words", storedAt: .now)
        try persistence.save(history, userID: "u1")

        #expect(try persistence.load(userID: "u1") == history)
        // A new instance (next launch) reads the same file.
        #expect(try EncryptedFileHistoryPersistence(secrets: secrets, directory: directory).load(userID: "u1") == history)
        let file = try #require(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let raw = try Data(contentsOf: file)
        #expect(raw.range(of: Data("secret words".utf8)) == nil)
        #expect(!file.lastPathComponent.contains("u1"))

        try secrets.delete("u1/history-key")
        #expect(try persistence.load(userID: "u1") == nil)
        try persistence.delete(userID: "u1")
        #expect(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).isEmpty)
    }

    @Test("History drops expired messages and day-old sends")
    func prune() {
        var history = E2EHistory()
        history.messages["gone"] = .init(conversationID: "c", text: "x", storedAt: .now, expiresAt: .now.addingTimeInterval(-1))
        history.messages["kept"] = .init(conversationID: "c", text: "y", storedAt: .now)
        history.recentSends = [.init(conversationID: "c", normalized: "n", sentAt: .now.addingTimeInterval(-25 * 3600))]
        history.prune(now: .now)
        #expect(Array(history.messages.keys) == ["kept"])
        #expect(history.recentSends.isEmpty)
    }

    @Test("E2E wire models decode the documented JSON")
    func wireModels() throws {
        let config = try JSONDecoder.stexx().decode(E2EConfig.self, from: Data(#"""
        {"mode":"optional","deviceID":1,"maxPreKeys":100,"maxPqPreKeys":25,"preKeyLowWatermark":20,"pqPreKeyLowWatermark":5,
         "envelopeMaxBytes":32768,"contentRules":{"restricted":true,"noLinks":true,"duplicateRecipients":3,"duplicateMinLength":16}}
        """#.utf8))
        #expect(config.mode == .optional)
        #expect(config.contentRules.restricted)
        // An unknown future mode is treated as off.
        let future = try JSONDecoder.stexx().decode(E2EConfig.self, from: Data(#"""
        {"mode":"paranoid","deviceID":1,"maxPreKeys":100,"maxPqPreKeys":25,"preKeyLowWatermark":20,"pqPreKeyLowWatermark":5,
         "envelopeMaxBytes":32768,"contentRules":{"restricted":false,"noLinks":false,"duplicateRecipients":3,"duplicateMinLength":16}}
        """#.utf8))
        #expect(future.mode == .off)

        let status = try JSONDecoder.stexx().decode(KeyStatus.self, from: Data(#"""
        {"registered":false,"deviceID":null,"registrationID":null,"identityKey":null,"identityKeyChangedAt":null,
         "preKeyCount":0,"pqPreKeyCount":0,"signedPreKeyID":null,"signedPreKeyUpdatedAt":null,
         "pqLastResortPreKeyID":null,"pqLastResortPreKeyUpdatedAt":null}
        """#.utf8))
        #expect(!status.registered)

        let message = try JSONDecoder.stexx().decode(Message.self, from: Data(#"""
        {"id":"m1","conversationID":"c1","senderID":"p1","text":null,"envelope":{"type":"prekey","body":"AQID"},
         "attachment":null,"sentAt":"2026-11-17T20:30:00Z","status":"delivered","expiresAt":null,"clientID":"x"}
        """#.utf8))
        #expect(message.envelope == MessageEnvelope(type: .prekey, body: "AQID"))
        #expect(message.encryption == nil)

        // A draft with an envelope carries no text on the wire.
        let draft = MessageDraft(clientID: "c", text: nil, envelope: MessageEnvelope(type: .signal, body: "AQID"))
        let json = try #require(String(data: JSONEncoder.stexx().encode(draft), encoding: .utf8))
        #expect(json.contains("\"envelope\""))
        #expect(!json.contains("\"text\""))
    }

    @Test("identity.changed and keys.low decode from the websocket")
    func realtimeEvents() throws {
        let changed = try RealtimeEvent.decode(RealtimeFixtures.event("identity.changed", #"{"userID":"p7","identityKeyChangedAt":"2026-11-17T20:30:00Z"}"#))
        #expect(changed == .identityChanged(.init(userID: "p7", identityKeyChangedAt: StexxDate.parse("2026-11-17T20:30:00Z"))))
        let low = try RealtimeEvent.decode(RealtimeFixtures.event("keys.low", #"{"preKeyCount":3,"pqPreKeyCount":1}"#))
        #expect(low == .keysLow(.init(preKeyCount: 3, pqPreKeyCount: 1)))
    }

    @Test("HTTP: keys_unavailable and e2e_disabled 404s keep their code; E2E routes are attested")
    func httpMapping() async throws {
        let baseURL = StubURLProtocol.register { request in
            switch request.url?.path() {
            case "/v1/keys/bundle/p1": return (404, [:], Fixtures.json(["code": "keys_unavailable", "message": "no keys"]))
            case "/v1/keys/status": return (404, [:], Fixtures.json(["code": "e2e_disabled", "message": "off"]))
            case "/v1/keys/identity/p2": return (404, [:], Fixtures.json(["code": "not_found", "message": "nope"]))
            default: return (400, [:], Fixtures.json(["code": "encryption_required", "message": "Update"]))
            }
        }
        let client = HTTPAPIClient(
            configuration: APIConfiguration(baseURL: baseURL, useMock: false),
            session: StubURLProtocol.session(),
            sessions: SessionCoordinator(store: InMemorySessionStore(session: Session(userID: "u1", accessToken: "a", refreshToken: "r", expiresAt: nil)))
        )
        await #expect(throws: APIError.e2e(code: "keys_unavailable", message: "no keys")) { _ = try await client.preKeyBundle(for: "p1") }
        await #expect(throws: APIError.e2e(code: "e2e_disabled", message: "off")) { _ = try await client.keyStatus() }
        await #expect(throws: APIError.notFound) { _ = try await client.identityKey(for: "p2") }
        await #expect(throws: APIError.e2e(code: "encryption_required", message: "Update")) {
            _ = try await client.send(MessageDraft(clientID: "c", text: "hi"), in: "c1")
        }
        #expect(HTTPAPIClient.attestedRoute("PUT", "keys") == .content)
        #expect(HTTPAPIClient.attestedRoute("GET", "keys/bundle/p1") == .content)
        #expect(HTTPAPIClient.attestedRoute("GET", "keys/identity/p1") == nil)
        #expect(HTTPAPIClient.attestedRoute("POST", "keys/prekeys") == nil)
    }
}
