import Foundation
import LibSignalClient
import Testing
@testable import Stexx

/// The Signal Protocol client end to end: two devices with real libsignal
/// keys talking through `FakeE2EServer`.
@Suite("E2E engine")
struct E2EEngineTests {
    // MARK: Keys

    @Test("Sign-in generates and uploads a full key set with valid signatures")
    func registersKeys() async throws {
        let server = FakeE2EServer()
        let alice = FakeDevice("alice", peer: "bob", server: server)
        await alice.engine.syncKeys()

        let registration = try #require(await server.registrations["alice"])
        #expect((1...16380).contains(registration.registrationID))
        #expect(registration.deviceID == 1)
        #expect(registration.preKeys.count == 100)
        #expect(registration.pqPreKeys.count == 25)
        #expect(Set(registration.preKeys.map(\.keyID)).count == 100)

        let identity = try IdentityKey(bytes: try #require(Data(base64Encoded: registration.identityKey)))
        #expect(identity.serialize().count == 33)
        // Signed prekey and every Kyber key are signed by the identity key over the serialized public key.
        for signed in [registration.signedPreKey, registration.pqLastResortPreKey] + registration.pqPreKeys {
            let publicKey = try #require(Data(base64Encoded: signed.publicKey))
            let signature = try #require(Data(base64Encoded: signed.signature))
            #expect(try identity.publicKey.verifySignature(message: publicKey, signature: signature))
        }
        #expect(try #require(Data(base64Encoded: registration.pqLastResortPreKey.publicKey)).count == 1569)
        // Kyber one-time and last-resort ids share one id space.
        #expect(!registration.pqPreKeys.map(\.keyID).contains(registration.pqLastResortPreKey.keyID))

        // Private material is in the (Keychain-shaped) storage under the account's prefix.
        let stored = try alice.secrets.keys(withPrefix: "alice/")
        #expect(stored.contains("alice/identity"))
        #expect(stored.filter { $0.hasPrefix("alice/prekey.") }.count == 100)
        #expect(stored.filter { $0.hasPrefix("alice/kyber.") }.count == 26)
    }

    @Test("A relaunch reuses the stored identity and doesn't re-register")
    func reusesStoredKeys() async throws {
        let server = FakeE2EServer()
        let secrets = InMemorySecretStorage()
        await FakeDevice("alice", peer: "bob", server: server, secrets: secrets).engine.syncKeys()
        let first = try #require(await server.registrations["alice"]).identityKey

        await FakeDevice("alice", peer: "bob", server: server, secrets: secrets).engine.syncKeys()
        #expect(await server.count("register") == 1)
        #expect(try #require(await server.registrations["alice"]).identityKey == first)
    }

    @Test("Mode off: no key routes are called and nothing is stored")
    func offModeTouchesNothing() async throws {
        let server = FakeE2EServer()
        await server.set(mode: .off)
        let alice = FakeDevice("alice", peer: "bob", server: server)
        await alice.engine.syncKeys()
        #expect(await server.count("status") == 0)
        #expect(await server.count("register") == 0)
        #expect(try alice.secrets.keys(withPrefix: "").isEmpty)
    }

    @Test("Replenishes one-time prekeys below the watermarks, back up to the maximum")
    func replenishes() async throws {
        let server = FakeE2EServer()
        let alice = FakeDevice("alice", peer: "bob", server: server)
        await alice.engine.syncKeys()
        var status = try await server.keyStatus(as: "alice")
        status.preKeyCount = 5
        status.pqPreKeyCount = 2
        await server.set(status: status, for: "alice")

        await alice.engine.replenishKeys()
        #expect(await server.count("prekeys") == 1)
        #expect(await server.preKeys["alice"]?.count == 100 + 95)
        #expect(await server.pqPreKeys["alice"]?.count == 25 + 23)

        // Above the watermarks: nothing to do.
        await alice.engine.replenishKeys()
        #expect(await server.count("prekeys") == 1)
    }

    @Test("keys.low over the websocket triggers a top-up")
    @MainActor
    func keysLowEvent() async throws {
        let server = FakeE2EServer()
        let alice = FakeDevice("alice", peer: "bob", server: server)
        await alice.engine.syncKeys()
        var status = try await server.keyStatus(as: "alice")
        status.preKeyCount = 0
        await server.set(status: status, for: "alice")

        let e2e = E2EStatus(engine: alice.engine)
        _ = await e2e.process(.keysLow(.init(preKeyCount: 0, pqPreKeyCount: 25)))
        for _ in 0..<50 where await server.count("prekeys") == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await server.count("prekeys") == 1)
    }

    @Test("Rotates the signed prekey and Kyber last-resort key weekly, keeping the old ones for a while")
    func rotates() async throws {
        let server = FakeE2EServer()
        let clock = E2EClock(Date())
        let alice = FakeDevice("alice", peer: "bob", server: server, now: { clock.now })
        await alice.engine.syncKeys()
        let old = try #require(await server.registrations["alice"]).signedPreKey.keyID

        clock.advance(8 * 24 * 3600)
        var status = try await server.keyStatus(as: "alice")
        status.signedPreKeyUpdatedAt = Date().addingTimeInterval(-8 * 24 * 3600)
        await server.set(status: status, for: "alice")
        await alice.engine.syncKeys()
        #expect(await server.count("rotate") == 1)
        let rotated = try #require(await server.registrations["alice"]).signedPreKey.keyID
        #expect(rotated != old)
        #expect(try alice.secrets.read("alice/signed.\(old)") != nil)

        // 30 days after it was replaced, the old one is dropped.
        clock.advance(31 * 24 * 3600)
        await alice.engine.syncKeys()
        #expect(try alice.secrets.read("alice/signed.\(old)") == nil)
        #expect(try alice.secrets.read("alice/signed.\(rotated)") != nil)
    }

    @Test("A server that lost our keys (or a different identity there) gets a full re-registration")
    func reRegistersOnMismatch() async throws {
        let server = FakeE2EServer()
        let alice = FakeDevice("alice", peer: "bob", server: server)
        await alice.engine.syncKeys()
        await server.set(status: KeyStatus(registered: false, preKeyCount: 0, pqPreKeyCount: 0), for: "alice")
        await alice.engine.syncKeys()
        #expect(await server.count("register") == 2)
    }

    // MARK: Messages

    @Test("PQXDH + Double Ratchet round trip between two devices")
    func roundTrip() async throws {
        let server = FakeE2EServer()
        let alice = FakeDevice("alice", peer: "bob", server: server)
        let bob = FakeDevice("bob", peer: "alice", server: server)
        await alice.engine.syncKeys()
        await bob.engine.syncKeys()

        let sent = try await alice.send("Museum this weekend?")
        #expect(sent.text == "Museum this weekend?")
        #expect(sent.encryption == .decrypted)
        let onServer = try #require(await server.messages.last)
        #expect(onServer.text == nil)
        #expect(onServer.envelope?.type == .prekey)
        #expect(await server.preKeys["bob"]?.count == 99)
        #expect(await server.pqPreKeys["bob"]?.count == 24)

        // Bob decrypts; a second fetch reads the local copy (a ratchet message decrypts once).
        for _ in 0..<2 {
            let thread = try await bob.thread()
            #expect(thread.last?.text == "Museum this weekend?")
            #expect(thread.last?.encryption == .decrypted)
        }

        let reply = try await bob.send("Yes! Sunday?")
        #expect(await server.messages.last?.envelope?.type == .signal)
        #expect(reply.text == "Yes! Sunday?")

        let aliceView = try await alice.thread()
        #expect(aliceView.map(\.text) == ["Museum this weekend?", "Yes! Sunday?"])
        #expect(aliceView.allSatisfy { $0.encryption == .decrypted })

        // After the reply, Alice's messages are plain ratchet messages.
        _ = try await alice.send("Sunday works")
        #expect(await server.messages.last?.envelope?.type == .signal)
        #expect(try await bob.thread().last?.text == "Sunday works")
        #expect(await server.count("bundle") == 1)
    }

    @Test("The same message from REST and the websocket at once is decrypted once")
    func concurrentReveal() async throws {
        let server = FakeE2EServer()
        let alice = FakeDevice("alice", peer: "bob", server: server)
        let bob = FakeDevice("bob", peer: "alice", server: server)
        await bob.engine.syncKeys()
        _ = try await alice.send("hi there")
        let message = try #require(await server.messages.last)

        async let viaSocket = bob.engine.reveal(RealtimeEvent.messageCreated(message))
        async let viaREST = bob.engine.reveal([message])
        let (event, page) = await (viaSocket, viaREST)
        guard case .messageCreated(let fromSocket) = event else { Issue.record("wrong event"); return }
        #expect(fromSocket.text == "hi there")
        #expect(page.first?.text == "hi there")
    }

    @Test("Many messages out of order still decrypt")
    func outOfOrder() async throws {
        let server = FakeE2EServer()
        let alice = FakeDevice("alice", peer: "bob", server: server)
        let bob = FakeDevice("bob", peer: "alice", server: server)
        await bob.engine.syncKeys()
        for index in 0..<5 { _ = try await alice.send("message \(index)") }
        let all = await server.messages
        let revealed = await bob.engine.reveal(all.reversed())
        #expect(Set(revealed.compactMap(\.text)) == Set((0..<5).map { "message \($0)" }))
    }

    @Test("After a reinstall, old messages show a placeholder instead of failing")
    func reinstallPlaceholder() async throws {
        let server = FakeE2EServer()
        let alice = FakeDevice("alice", peer: "bob", server: server)
        let bob = FakeDevice("bob", peer: "alice", server: server)
        await bob.engine.syncKeys()
        _ = try await alice.send("before")
        _ = try await bob.thread()

        // Bob's history file is gone (reinstall that kept the Keychain): the ratchet key was used up.
        let bobAgain = FakeDevice("bob", peer: "alice", server: server, secrets: bob.secrets)
        let thread = try await bobAgain.thread()
        #expect(thread.last?.text == nil)
        #expect(thread.last?.encryption == .unavailable)

        // Alice on a fresh install can't read her own old envelope either.
        let aliceAgain = FakeDevice("alice", peer: "bob", server: server)
        await aliceAgain.engine.syncKeys()
        #expect(try await aliceAgain.thread().first?.encryption == .unavailable)
    }

    @Test("Garbage in an envelope is a placeholder, never a crash")
    func garbageEnvelope() async throws {
        let server = FakeE2EServer()
        let bob = FakeDevice("bob", peer: "alice", server: server)
        await bob.engine.syncKeys()
        let bogus = Message(
            id: "x1", conversationID: FakeE2EServer.conversationID, senderID: "alice", text: nil,
            envelope: MessageEnvelope(type: .prekey, body: Data(repeating: 7, count: 200).base64EncodedString()),
            attachment: nil, sentAt: .now, status: .delivered, expiresAt: nil, clientID: nil
        )
        let revealed = await bob.engine.reveal(bogus)
        #expect(revealed.text == nil)
        #expect(revealed.encryption == .unavailable)
    }

    // MARK: Identity changes

    @Test("A changed identity key is refused until the user accepts it")
    func identityChangeIsHeld() async throws {
        let server = FakeE2EServer()
        let alice = FakeDevice("alice", peer: "bob", server: server)
        let bob = FakeDevice("bob", peer: "alice", server: server)
        await alice.engine.syncKeys()
        await bob.engine.syncKeys()
        _ = try await alice.send("hey")
        _ = try await bob.thread()
        _ = try await bob.send("hey back")
        _ = try await alice.thread()

        // Bob reinstalls: new identity, re-registered.
        let newBob = FakeDevice("bob", peer: "alice", server: server)
        await newBob.engine.syncKeys()
        #expect(await server.count("register") == 3)

        // Bob's first message from the new install reaches Alice: held, not decrypted.
        _ = try await newBob.send("it's me, new phone")
        let held = try #require(try await alice.thread().last)
        #expect(held.text == nil)
        #expect(held.encryption == .awaitingKeyConfirmation)
        var snapshot = await alice.engine.snapshot()
        #expect(snapshot.keyChanges["bob"] != nil)

        // Nothing goes out to Bob while the change is pending.
        let sentBefore = await server.messages.count
        await #expect(throws: E2EError.identityChanged(peer: "bob")) {
            _ = try await alice.send("are you still you?")
        }
        #expect(await server.messages.count == sentBefore)

        // Accepting trusts the new key: the held message decrypts, sending works again.
        try await alice.engine.acceptIdentityChange(of: "bob")
        snapshot = await alice.engine.snapshot()
        #expect(snapshot.keyChanges.isEmpty)
        #expect(try await alice.thread().last?.text == "it's me, new phone")
        _ = try await alice.send("welcome back")
        #expect(try await newBob.thread().last?.text == "welcome back")
    }

    @Test("identity.changed re-checks the key and holds a change; a bundle with a new key is refused")
    @MainActor
    func identityChangedEvent() async throws {
        let server = FakeE2EServer()
        let alice = FakeDevice("alice", peer: "bob", server: server)
        let bob = FakeDevice("bob", peer: "alice", server: server)
        await bob.engine.syncKeys()
        _ = try await alice.send("hey")
        let e2e = E2EStatus(engine: alice.engine)

        // Bob gets a new identity; the event makes Alice re-check it (in the background).
        await FakeDevice("bob", peer: "alice", server: server).engine.syncKeys()
        _ = await e2e.process(.identityChanged(.init(userID: "bob", identityKeyChangedAt: .now)))
        for _ in 0..<100 where !e2e.hasKeyChange(for: "bob") { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await server.count("identity") == 1)
        #expect(e2e.hasKeyChange(for: "bob"))
        await #expect(throws: E2EError.identityChanged(peer: "bob")) {
            _ = try await alice.send("hello?")
        }
        #expect(await e2e.acceptKeyChange(of: "bob"))
        #expect(!e2e.hasKeyChange(for: "bob"))
        _ = try await alice.send("hello again")
        #expect(await server.messages.last?.envelope?.type == .prekey)
    }

    @Test("A bundle with a different identity than the trusted one is refused even without the event")
    func bundleIdentityMismatch() async throws {
        let server = FakeE2EServer()
        let alice = FakeDevice("alice", peer: "bob", server: server)
        let bob = FakeDevice("bob", peer: "alice", server: server)
        await bob.engine.syncKeys()
        _ = try await alice.send("hey")
        // Alice loses the session (but keeps the trusted key), then Bob changes identity.
        try alice.secrets.delete("alice/session.bob.1")
        let aliceAgain = FakeDevice("alice", peer: "bob", server: server, secrets: alice.secrets, history: alice.history)
        await FakeDevice("bob", peer: "alice", server: server).engine.syncKeys()
        await #expect(throws: E2EError.identityChanged(peer: "bob")) {
            _ = try await aliceAgain.send("hello?")
        }
        #expect(await aliceAgain.engine.snapshot().keyChanges["bob"] != nil)
    }

    // MARK: E2E_MODE

    @Test("Mode off sends plaintext and never touches keys")
    func modeOff() async throws {
        let server = FakeE2EServer()
        await server.set(mode: .off)
        let alice = FakeDevice("alice", peer: "bob", server: server)
        let sent = try await alice.send("plain")
        #expect(sent.text == "plain")
        #expect(sent.envelope == nil)
        #expect(await server.count("bundle") == 0)
        #expect(await server.count("send.plaintext") == 1)
    }

    @Test("Optional mode falls back to plaintext when the recipient has no keys")
    func optionalFallback() async throws {
        let server = FakeE2EServer()
        let alice = FakeDevice("alice", peer: "bob", server: server)
        let sent = try await alice.send("you don't have keys yet")
        #expect(sent.text == "you don't have keys yet")
        #expect(sent.envelope == nil)
        #expect(await server.count("bundle") == 1)
    }

    @Test("Required mode never sends plaintext and fails clearly without keys")
    func requiredMode() async throws {
        let server = FakeE2EServer()
        await server.set(mode: .required)
        let alice = FakeDevice("alice", peer: "bob", server: server)
        await #expect(throws: E2EError.recipientHasNoKeys) {
            _ = try await alice.send("hello")
        }
        #expect(await server.messages.isEmpty)
    }

    @Test("A server that switched to required mid-session gets the message encrypted on the retry")
    func switchedToRequired() async throws {
        let server = FakeE2EServer()
        await server.set(mode: .off)
        let alice = FakeDevice("alice", peer: "bob", server: server)
        let bob = FakeDevice("bob", peer: "alice", server: server)
        _ = try await alice.engine.currentConfig()
        await server.set(mode: .required)
        await bob.engine.syncKeys()

        let sent = try await alice.send("now encrypted")
        #expect(sent.text == "now encrypted")
        #expect(await server.messages.last?.envelope != nil)
        #expect(await server.count("send.plaintext") == 1)
        #expect(await server.count("send.envelope") == 1)
    }

    @Test("A server that switched E2E off gets the message as plaintext on the retry")
    func switchedToOff() async throws {
        let server = FakeE2EServer()
        let alice = FakeDevice("alice", peer: "bob", server: server)
        let bob = FakeDevice("bob", peer: "alice", server: server)
        await bob.engine.syncKeys()
        _ = try await alice.send("encrypted")
        await server.set(mode: .off)
        let sent = try await alice.send("server is off now")
        #expect(sent.text == "server is off now")
        #expect(await server.messages.last?.envelope == nil)
    }

    // MARK: Content rules

    @Test("Restricted accounts can't encrypt links; the check runs before any key is fetched")
    func linkRuleBeforeEncrypting() async throws {
        let server = FakeE2EServer()
        await server.set(contentRules: .init(restricted: true, noLinks: true, duplicateRecipients: 3, duplicateMinLength: 16))
        let alice = FakeDevice("alice", peer: "bob", server: server)
        let bob = FakeDevice("bob", peer: "alice", server: server)
        await bob.engine.syncKeys()
        await #expect(throws: E2EContentRules.Violation.linksNotAllowed) {
            _ = try await alice.send("add me on spam-site.com")
        }
        #expect(await server.count("bundle") == 0)
        #expect(await server.messages.isEmpty)
        _ = try await alice.send("no links here")
        #expect(await server.messages.count == 1)
    }

    @Test("Deleting the account wipes this device's keys and history")
    func wipeOnDelete() async throws {
        let server = FakeE2EServer()
        let alice = FakeDevice("alice", peer: "bob", server: server)
        await alice.engine.syncKeys()
        _ = try await alice.send("hi")
        try await alice.client.deleteAccount()
        #expect(try alice.secrets.keys(withPrefix: "alice/").isEmpty)
        #expect(try alice.history.load(userID: "alice") == nil)
    }

    // MARK: Review fixes

    @Test("A failed PUT /keys is re-sent with the same keys, not a new batch")
    func failedRegistrationIsReused() async throws {
        let server = FakeE2EServer()
        let alice = FakeDevice("alice", peer: "bob", server: server)
        await server.failNextRegister(.beforeApply)
        await alice.engine.syncKeys()
        #expect(await server.registrations["alice"] == nil)
        await alice.engine.syncKeys()
        let attempts = await server.registerAttempts
        #expect(attempts.count == 2)
        #expect(attempts[0] == attempts[1])
        #expect(try alice.secrets.keys(withPrefix: "alice/prekey.").count == 100)
        #expect(try alice.secrets.read("alice/upload.registration") == nil)
    }

    @Test("A PUT /keys whose response was lost is committed on the next sync, without registering again")
    func lostRegistrationResponse() async throws {
        let server = FakeE2EServer()
        let alice = FakeDevice("alice", peer: "bob", server: server)
        await server.failNextRegister(.afterApply)
        await alice.engine.syncKeys()
        #expect(try alice.secrets.read("alice/upload.registration") != nil)
        await alice.engine.syncKeys()
        #expect(await server.count("register") == 1)
        #expect(try alice.secrets.read("alice/upload.registration") == nil)
        // And it works: Bob can start a session with Alice's keys.
        let bob = FakeDevice("bob", peer: "alice", server: server)
        _ = try await bob.send("hi")
        #expect(try await alice.thread().last?.text == "hi")
    }

    @Test("An old message under a key the user replaced doesn't bring the warning back")
    func retiredKeyNoNewHold() async throws {
        let server = FakeE2EServer()
        let alice = FakeDevice("alice", peer: "bob", server: server)
        let bob = FakeDevice("bob", peer: "alice", server: server)
        await alice.engine.syncKeys()
        await bob.engine.syncKeys()
        _ = try await alice.send("hi")          // Alice trusts Bob's first key.
        _ = try await bob.send("old message")   // A prekey message under that key, not read yet.
        let old = try #require(await server.messages.last)

        let newBob = FakeDevice("bob", peer: "alice", server: server)
        await newBob.engine.syncKeys()
        _ = try await newBob.send("new phone")
        let new = try #require(await server.messages.last)
        #expect(await alice.engine.reveal(new).encryption == .awaitingKeyConfirmation)
        try await alice.engine.acceptIdentityChange(of: "bob")
        #expect(await alice.engine.reveal(new).text == "new phone")

        let stale = await alice.engine.reveal(old)
        #expect(stale.text == nil)
        #expect(await alice.engine.snapshot().keyChanges.isEmpty)
        _ = try await alice.send("still fine")
        #expect(try await newBob.thread().last?.text == "still fine")
    }

    @Test("A hold the server doesn't back (its key is still the trusted one) clears when the chat opens")
    func unbackedHoldClears() async throws {
        let server = FakeE2EServer()
        let alice = FakeDevice("alice", peer: "bob", server: server)
        let bob = FakeDevice("bob", peer: "alice", server: server)
        await bob.engine.syncKeys()
        _ = try await alice.send("hi")
        // A forged key recorded as pending (e.g. from an injected prekey message).
        let forged = E2EPendingIdentity(identityKey: IdentityKeyPair.generate().identityKey.serialize().base64EncodedString(), detectedAt: .now)
        try alice.secrets.write(try JSONEncoder().encode(forged), for: "alice/pending.bob")
        let aliceAgain = FakeDevice("alice", peer: "bob", server: server, secrets: alice.secrets, history: alice.history)
        await aliceAgain.engine.threadOpened(with: "bob")
        #expect(await aliceAgain.engine.snapshot().keyChanges.isEmpty)
        _ = try await aliceAgain.send("hello again")
        #expect(try await bob.thread().last?.text == "hello again")
    }

    @Test("An unreadable history file is set aside, never silently overwritten")
    func unreadableHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "e2e history \(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = FakeE2EServer()
        let secrets = InMemorySecretStorage()
        let persistence = EncryptedFileHistoryPersistence(secrets: secrets, directory: directory)
        let alice = FakeDevice("alice", peer: "bob", server: server, secrets: secrets, history: persistence)
        let bob = FakeDevice("bob", peer: "alice", server: server)
        await bob.engine.syncKeys()
        _ = try await alice.send("hi")
        let file = try #require(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        try Data("garbage".utf8).write(to: file)

        let aliceAgain = FakeDevice("alice", peer: "bob", server: server, secrets: secrets, history: persistence)
        _ = try await aliceAgain.send("again")
        let aside = file.appendingPathExtension("unreadable")
        #expect(try Data(contentsOf: aside) == Data("garbage".utf8))
        #expect(try persistence.load(userID: "alice")?.sent.isEmpty == false || persistence.load(userID: "alice")?.messages.isEmpty == false)
    }
}
