import Foundation
import Testing
@testable import Stexx

/// Records privacy saves and answers them, optionally holding each one until
/// the test releases it.
private actor PrivacyServer {
    private(set) var saves: [PrivacySettings] = []
    var failure: (any Error)?
    var holds = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func set(failure: (any Error)?) { self.failure = failure }
    func set(holds: Bool) { self.holds = holds }

    func save(_ settings: PrivacySettings) async throws -> PrivacySettings {
        saves.append(settings)
        if holds { await withCheckedContinuation { waiting.append($0) } }
        if let failure { throw failure }
        return settings
    }

    /// Lets every held save answer.
    func release() {
        let held = waiting
        waiting = []
        for continuation in held { continuation.resume() }
    }

    var heldCount: Int { waiting.count }
}

@MainActor
@Suite("Privacy settings come from the server")
struct PrivacySyncTests {
    private func makeState(defaults: UserDefaults? = nil) -> AppState {
        let defaults = defaults ?? UserDefaults(suiteName: "stexx.tests.\(UUID().uuidString)")!
        let state = AppState(defaults: defaults, sessionStore: InMemorySessionStore(), travelStore: InMemoryTravelPlaceStore())
        state.confirmAge()
        state.signIn(MockData.session)
        return state
    }

    private func connect(_ state: AppState, to server: PrivacyServer) {
        state.savePrivacy = { try await server.save($0) }
    }

    /// Lets the main actor run until `condition` holds (a save in flight).
    private func until(_ condition: () async -> Bool) async {
        for _ in 0..<400 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("Until the server's values arrive the settings are defaults and changes are ignored")
    func loadingIgnoresChanges() async {
        let state = makeState()
        let server = PrivacyServer()
        connect(state, to: server)
        #expect(state.privacyStatus == .loading)
        #expect(!state.isPrivacyEditable)
        #expect(state.privacy == PrivacySettings())

        state.setPrivacy(\.hideDistance, to: true)
        await state.privacySavesFinished()
        #expect(!state.privacy.hideDistance)
        #expect(await server.saves.isEmpty)
    }

    @Test("Settings an older version stored on the phone are ignored and removed")
    func legacyDefaultsIgnored() throws {
        let suite = "stexx.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(try JSONEncoder().encode(PrivacySettings(hideDistance: true, incognito: true)), forKey: "stexx.privacy")

        let state = makeState(defaults: defaults)
        #expect(state.privacy == PrivacySettings())
        #expect(state.privacyStatus == .loading)
        #expect(defaults.object(forKey: "stexx.privacy") == nil)
    }

    @Test("GET /me loads what the server stores, after a reinstall or on another account")
    func loadsFromServer() async throws {
        let api = MockAPIClient(latency: .zero)
        let stored = PrivacySettings(hideDistance: true, showOnlineStatus: false, sendReadReceipts: false, expiringPhotosByDefault: false)
        _ = try await api.updatePrivacy(stored)

        let state = makeState()
        await state.loadMe(from: api)
        #expect(state.privacyStatus == .loaded)
        #expect(state.privacy == stored)
        #expect(state.me?.privacy == stored)
    }

    @Test("A failed GET /me keeps the toggles disabled until a retry loads them")
    func failedLoadRetries() async throws {
        let failing = AtomicFlag(true)
        let baseURL = StubURLProtocol.register { request in
            guard request.url?.path() == "/v1/me" else { return (404, [:], Fixtures.error("not_found")) }
            if failing.value { throw URLError(.notConnectedToInternet) }
            var profile = Fixtures.profile
            profile["travel"] = NSNull()
            profile["privacy"] = [
                "hideDistance": true, "showOnlineStatus": true, "sendReadReceipts": false,
                "expiringPhotosByDefault": true, "blurExplicitPhotos": false, "incognito": false,
            ]
            return (200, [:], Fixtures.json(profile))
        }
        let client = HTTPAPIClient(
            configuration: APIConfiguration(baseURL: baseURL, useMock: false),
            session: StubURLProtocol.session(),
            sessions: SessionCoordinator(store: InMemorySessionStore(session: Session(userID: "u1", accessToken: "a", refreshToken: "r", expiresAt: nil)))
        )
        let state = makeState()

        await state.loadMe(from: client)
        #expect(state.privacyStatus == .unavailable)
        #expect(!state.isPrivacyEditable)

        failing.value = false
        await state.loadMe(from: client)
        #expect(state.privacyStatus == .loaded)
        #expect(state.privacy == PrivacySettings(hideDistance: true, sendReadReceipts: false, blurExplicitPhotos: false))
    }

    @Test("A change is shown at once, saved, and the server's answer is kept")
    func savesChange() async {
        let state = makeState()
        let server = PrivacyServer()
        connect(state, to: server)
        state.adoptServerPrivacy(PrivacySettings())

        state.setPrivacy(\.hideDistance, to: true)
        #expect(state.privacy.hideDistance)
        await state.privacySavesFinished()
        #expect(await server.saves == [PrivacySettings(hideDistance: true)])
        #expect(state.privacy.hideDistance)
        #expect(state.privacyError == nil)
    }

    @Test("A failed save switches the toggle back and says so")
    func failedSaveRollsBack() async {
        let state = makeState()
        let server = PrivacyServer()
        connect(state, to: server)
        state.adoptServerPrivacy(PrivacySettings(showOnlineStatus: true))
        await server.set(failure: URLError(.networkConnectionLost))

        state.setPrivacy(\.showOnlineStatus, to: false)
        #expect(!state.privacy.showOnlineStatus)
        await state.privacySavesFinished()
        #expect(state.privacy.showOnlineStatus)
        #expect(state.privacyError != nil)

        // The next change clears the message, and goes through once the server is back.
        await server.set(failure: nil)
        state.setPrivacy(\.sendReadReceipts, to: false)
        #expect(state.privacyError == nil)
        await state.privacySavesFinished()
        #expect(!state.privacy.sendReadReceipts)
        #expect(state.privacy.showOnlineStatus)
    }

    @Test("Changes made while a save runs are sent together after it, so the last choice wins")
    func changesDuringSaveAreCoalesced() async {
        let state = makeState()
        let server = PrivacyServer()
        await server.set(holds: true)
        connect(state, to: server)
        state.adoptServerPrivacy(PrivacySettings())

        state.setPrivacy(\.hideDistance, to: true)
        await until { await server.heldCount == 1 }
        state.setPrivacy(\.sendReadReceipts, to: false)
        state.setPrivacy(\.blurExplicitPhotos, to: false)
        // GET /me answering meanwhile doesn't undo the pending changes.
        state.adoptServerPrivacy(PrivacySettings())
        #expect(state.privacy == PrivacySettings(hideDistance: true, sendReadReceipts: false, blurExplicitPhotos: false))

        await server.set(holds: false)
        await server.release()
        await state.privacySavesFinished()
        #expect(await server.saves == [
            PrivacySettings(hideDistance: true),
            PrivacySettings(hideDistance: true, sendReadReceipts: false, blurExplicitPhotos: false),
        ])
        #expect(state.privacy == PrivacySettings(hideDistance: true, sendReadReceipts: false, blurExplicitPhotos: false))
    }

    @Test("Incognito without Stexx+ (402) is switched back and opens the paywall, without an error message")
    func incognitoNeedsPlus() async {
        let state = makeState()
        let server = PrivacyServer()
        await server.set(failure: APIError.requiresPlus)
        connect(state, to: server)
        state.hasPlus = true
        state.adoptServerPrivacy(PrivacySettings())

        state.setPrivacy(\.incognito, to: true)
        await state.privacySavesFinished()
        #expect(!state.privacy.incognito)
        #expect(state.isPaywallPresented)
        #expect(!state.hasPlus)
        #expect(state.privacyError == nil)
    }

    @Test("The mock follows the server's incognito rule")
    func mockIncognitoRule() async throws {
        let free = MockAPIClient(latency: .zero)
        await #expect(throws: APIError.requiresPlus) { try await free.updatePrivacy(PrivacySettings(incognito: true)) }
        let plus = MockAPIClient(latency: .zero, plusActive: true)
        #expect(try await plus.updatePrivacy(PrivacySettings(incognito: true)).incognito)
        #expect(try await plus.fetchMe().privacy?.incognito == true)
    }

    @Test("Signing out resets the settings; a save that finishes afterwards changes nothing")
    func signOutResets() async {
        let state = makeState()
        let server = PrivacyServer()
        await server.set(holds: true)
        connect(state, to: server)
        state.adoptServerPrivacy(PrivacySettings(hideDistance: true))
        state.setPrivacy(\.showOnlineStatus, to: false)
        await until { await server.heldCount == 1 }

        state.signOut()
        #expect(state.privacy == PrivacySettings())
        #expect(state.privacyStatus == .loading)

        state.signIn(Session(userID: "p_other", accessToken: "t", refreshToken: nil, expiresAt: nil))
        state.adoptServerPrivacy(PrivacySettings(blurExplicitPhotos: false))
        await server.release()
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(state.privacy == PrivacySettings(blurExplicitPhotos: false))
        #expect(state.privacyError == nil)
    }
}

/// A Bool shared with a `@Sendable` stub.
private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool
    init(_ value: Bool) { stored = value }
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

@MainActor
@Suite("Sign-out hygiene")
struct SignOutHygieneTests {
    private func makeState() -> AppState {
        let state = AppState(
            defaults: UserDefaults(suiteName: "stexx.tests.\(UUID().uuidString)")!,
            sessionStore: InMemorySessionStore(),
            travelStore: InMemoryTravelPlaceStore()
        )
        state.confirmAge()
        state.signIn(MockData.session)
        return state
    }

    @Test("Signing out (or deleting the account) erases the account's data on the phone; an expired session doesn't")
    func eraseOnlyOnExplicitSignOut() {
        var erased: [Profile.ID] = []

        let expired = makeState()
        expired.eraseAccountData = { erased.append($0) }
        expired.sessionDidExpire()
        #expect(erased.isEmpty)

        let signedOut = makeState()
        signedOut.eraseAccountData = { erased.append($0) }
        signedOut.signOut()
        #expect(erased == [MockData.session.userID])
        #expect(signedOut.isAgeConfirmed)

        let deleted = makeState()
        deleted.eraseAccountData = { erased.append($0) }
        deleted.signOut(wipeLocalData: true)
        #expect(erased == [MockData.session.userID, MockData.session.userID])
        #expect(!deleted.isAgeConfirmed)
    }

    @Test("Signing out erases this account's keys and decrypted history; signing in again starts a new identity")
    func signOutErasesE2E() async throws {
        let server = FakeE2EServer()
        let secrets = InMemorySecretStorage()
        let history = InMemoryHistoryPersistence()
        let alice = FakeDevice("alice", peer: "bob", server: server, secrets: secrets, history: history)
        let bob = FakeDevice("bob", peer: "alice", server: server)
        await alice.engine.syncKeys()
        await bob.engine.syncKeys()
        _ = try await alice.send("before sign-out")
        let firstIdentity = try #require(await server.registrations["alice"]).identityKey
        #expect(try history.load(userID: "alice") != nil)

        await alice.engine.erase(userID: "alice")
        #expect(try secrets.keys(withPrefix: "alice/").isEmpty)
        #expect(try history.load(userID: "alice") == nil)
        // The session-ended path running afterwards writes nothing back.
        await alice.engine.signedOut()
        #expect(try secrets.keys(withPrefix: "alice/").isEmpty)
        #expect(try history.load(userID: "alice") == nil)

        // Same phone, same account: a new identity (chat partners get the key-change notice).
        await alice.engine.syncKeys()
        let secondIdentity = try #require(await server.registrations["alice"]).identityKey
        #expect(secondIdentity != firstIdentity)
        #expect(try secrets.read("alice/identity") != nil)
    }

    @Test("Erasing one account leaves another account's keys on the phone alone")
    func eraseIsPerAccount() async throws {
        let server = FakeE2EServer()
        let secrets = InMemorySecretStorage()
        await FakeDevice("carol", peer: "bob", server: server, secrets: secrets).engine.syncKeys()
        let alice = FakeDevice("alice", peer: "bob", server: server, secrets: secrets)
        await alice.engine.syncKeys()

        await alice.engine.erase(userID: "alice")
        #expect(try secrets.keys(withPrefix: "alice/").isEmpty)
        #expect(try secrets.read("carol/identity") != nil)
    }

    @Test("A key store whose keys were erased can't write them back")
    func revokedStoreRefusesWrites() throws {
        let secrets = InMemorySecretStorage()
        let store = try E2EProtocolStore.loadOrCreate(storage: secrets, userID: "u1")
        try E2EProtocolStore.wipe(storage: secrets, userID: "u1")
        store.revoke()
        #expect(throws: E2EProtocolStore.RevokedError.self) { try store.updateState { $0.epoch = 3 } }
        #expect(try secrets.keys(withPrefix: "u1/").isEmpty)
    }
}

@Suite("Download my data")
struct DataExportTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "export tests \(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test("The export is written as a dated JSON file and the whole folder goes afterwards")
    func writesAndDeletes() throws {
        let root = directory()
        defer { DataExportFile.removeAll(in: root) }
        let json = Data(#"{"account":{"id":"p_1"},"notes":["a/b"]}"#.utf8)
        let day = Date(timeIntervalSince1970: 1_795_000_000) // 2026-11-18 UTC
        let file = try DataExportFile.write(json, in: root, now: day)

        #expect(file.url.lastPathComponent == "stexx-data-2026-11-18.json")
        #expect(file.url.path().hasPrefix(root.path()))
        let written = try Data(contentsOf: file.url)
        let object = try #require(try JSONSerialization.jsonObject(with: written) as? [String: Any])
        #expect((object["account"] as? [String: Any])?["id"] as? String == "p_1")
        // Pretty-printed, slashes kept readable.
        #expect(String(decoding: written, as: UTF8.self).contains("\n"))
        #expect(String(decoding: written, as: UTF8.self).contains("a/b"))
        let excluded = try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        #expect(excluded == true)

        DataExportFile.removeAll(in: root)
        #expect(!FileManager.default.fileExists(atPath: file.url.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: root.path(percentEncoded: false)))
    }

    @Test("A new export replaces anything an earlier one left behind")
    func replacesLeftovers() throws {
        let root = directory()
        defer { DataExportFile.removeAll(in: root) }
        let first = try DataExportFile.write(Data("{}".utf8), in: root)
        let second = try DataExportFile.write(Data("[]".utf8), in: root)
        #expect(!FileManager.default.fileExists(atPath: first.url.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: second.url.path(percentEncoded: false)))
        // Something that isn't JSON is kept as it came.
        let raw = try DataExportFile.write(Data("not json".utf8), in: root)
        #expect(try Data(contentsOf: raw.url) == Data("not json".utf8))
    }

    @Test("The mock's export is JSON with the profile and privacy settings")
    func mockExport() async throws {
        let data = try await MockAPIClient(latency: .zero).exportData()
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["privacy"] != nil)
        #expect(object["profile"] != nil)
    }
}

@MainActor
@Suite("Account dialogs")
struct AccountDialogTests {
    @Test("The delete-account warning is accurate: no location history, 28-day backups, Stexx+ is cancelled separately")
    func deleteWording() {
        let message = SettingsView.deleteAccountMessage
        #expect(!message.contains("location history"))
        #expect(message.contains("28 days"))
        #expect(message.contains("App Store"))
        #expect(message.contains("can't be undone"))
    }
}
