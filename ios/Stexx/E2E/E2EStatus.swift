import Foundation
import Observation

/// End-to-end encryption state for the UI (the chat thread's key-change
/// warning and "encrypted" label), and the glue between the app's lifecycle,
/// realtime events and `E2EEngine`.
///
/// `engine` is nil with the mock backend and in previews: everything here is
/// then a no-op and chats stay plaintext.
@MainActor
@Observable
final class E2EStatus {
    private(set) var mode: E2EConfig.Mode = .off
    /// People whose identity key changed, waiting for the user to accept it.
    private(set) var keyChanges: [Profile.ID: Date] = [:]
    /// People this device has an encrypted session with.
    private(set) var encryptedPeers: Set<Profile.ID> = []

    @ObservationIgnored let engine: E2EEngine?

    init(engine: E2EEngine?) {
        self.engine = engine
        guard let engine else { return }
        weak let weakSelf = self
        Task {
            await engine.setSnapshotHandler { snapshot in
                await weakSelf?.apply(snapshot)
            }
        }
    }

    func apply(_ snapshot: E2ESnapshot) {
        if mode != snapshot.mode { mode = snapshot.mode }
        if keyChanges != snapshot.keyChanges { keyChanges = snapshot.keyChanges }
        if encryptedPeers != snapshot.encryptedPeers { encryptedPeers = snapshot.encryptedPeers }
    }

    func hasKeyChange(for peer: Profile.ID) -> Bool { keyChanges[peer] != nil }

    func isEncrypted(with peer: Profile.ID) -> Bool { mode != .off && encryptedPeers.contains(peer) }

    // MARK: Lifecycle

    /// Signed in, launched or back in the foreground: register / replenish /
    /// rotate keys.
    func syncKeys() {
        guard let engine else { return }
        Task { await engine.syncKeys() }
    }

    /// Back in the foreground: drop messages and photo keys that expired
    /// while the app was in the background.
    func pruneHistory() {
        guard let engine else { return }
        Task { await engine.pruneHistory() }
    }

    func signedOut() {
        apply(E2ESnapshot())
        // Decrypted photos are memory only; none survive the account.
        Task { await ChatMediaLoader.shared.clear() }
        guard let engine else { return }
        Task { await engine.signedOut() }
    }

    /// A view-once photo was closed (or found spent): drop its key.
    func forgetAttachmentKey(messageID: Message.ID, gone: Bool = false) async {
        guard let engine else { return }
        if gone {
            await engine.attachmentsGone(messageIDs: [messageID])
        } else {
            await engine.forgetAttachmentKey(messageID: messageID)
        }
    }

    func threadOpened(with peer: Profile.ID) async {
        await engine?.threadOpened(with: peer)
    }

    /// The user accepted `peer`'s new key. Returns false if it failed.
    func acceptKeyChange(of peer: Profile.ID) async -> Bool {
        guard let engine else { return true }
        do {
            try await engine.acceptIdentityChange(of: peer)
            // The engine's own view, not a local guess: another change may
            // have been recorded meanwhile.
            apply(await engine.snapshot())
            return true
        } catch {
            return false
        }
    }

    // MARK: Realtime

    /// Decrypts message events and acts on encryption events, in order.
    func process(_ event: RealtimeEvent) async -> RealtimeEvent {
        guard let engine else { return event }
        switch event {
        case .identityChanged(let change):
            // Off the ordered event path: it's a network round trip.
            Task { await engine.checkIdentity(of: change.userID, maxAge: 0) }
            return event
        case .keysLow:
            Task { await engine.replenishKeys() }
            return event
        default:
            return await engine.reveal(event)
        }
    }
}
