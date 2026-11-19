import Foundation
import Observation

/// App-wide state: onboarding progress, session, the user's own profile,
/// privacy settings, entitlements and the local block list.
@MainActor
@Observable
final class AppState {
    private(set) var isAgeConfirmed: Bool
    private(set) var session: Session?
    /// Your own profile. Setting it also adopts the server's travel mode
    /// state (`Profile.travel`) and privacy settings (`Profile.privacy`):
    /// the server wins.
    var me: Profile? = nil {
        didSet {
            guard let me else { return }
            syncTravel(with: me.travel)
            if let privacy = me.privacy { adoptServerPrivacy(privacy) }
        }
    }
    /// Your privacy settings as the server applies them (`GET /me`), plus any
    /// change being saved. Change them with `setPrivacy(_:to:)`. Until they
    /// have loaded these are the defaults and the toggles are disabled, so
    /// the screen never shows (or saves) values the server isn't using.
    private(set) var privacy = PrivacySettings()
    private(set) var privacyStatus: PrivacyStatus = .loading
    /// Why the last change didn't save (it was rolled back). Cleared by the
    /// next change.
    private(set) var privacyError: String?
    /// Stexx+ entitlement. Set from the server (`GET /subscriptions/status`,
    /// 402 responses); StoreKit purchases only trigger a server re-check.
    /// Also dropped when `plusExpiresAt` passes while the app is open, or
    /// when `GET /me` reports travel mode paused (both followed by a server
    /// re-check), so the UI never claims a Plus feature the server has
    /// already stopped applying.
    var hasPlus = false
    private(set) var plusExpiresAt: Date?
    /// Profiles blocked during this session; hidden everywhere immediately,
    /// even before the server round-trip finishes.
    private(set) var blockedIDs: Set<Profile.ID> = []
    var isPaywallPresented = false
    /// Stexx+ travel mode, or `nil` when it's off. The server says whether
    /// it's on; where it is (the cell that was sent and a place name looked
    /// up on this phone) is only kept on this device (`TravelPlaceStore`:
    /// a backup-excluded, protected file).
    private(set) var travel: TravelPlace?
    /// Bumped whenever travel mode is turned on, moved or off, so the grid
    /// reloads.
    private(set) var travelRevision = 0

    /// Saves privacy settings on the server (`PUT /me/privacy`) and returns
    /// what it stored. Set by the app.
    @ObservationIgnored var savePrivacy: (@Sendable (PrivacySettings) async throws -> PrivacySettings)?
    /// The user signed out on purpose: erase this account's end-to-end
    /// encryption keys and decrypted chat history from the phone
    /// (`E2EStatus.erase`). Not called when a session merely expires. Set by
    /// the app.
    @ObservationIgnored var eraseAccountData: ((Profile.ID) -> Void)?
    /// What the server last confirmed (`GET /me` or a save); a failed save
    /// rolls back to it.
    @ObservationIgnored private var savedPrivacy = PrivacySettings()
    @ObservationIgnored private var privacySave: Task<Void, Never>?
    /// Bumped whenever the session ends: answers for the previous account
    /// are dropped.
    @ObservationIgnored private var accountGeneration = 0
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let sessionStore: any SessionStore
    @ObservationIgnored private let travelStore: any TravelPlaceStore
    /// Revokes a session on the server when the user signs out. Set by the app.
    @ObservationIgnored var revokeSession: ((Session) -> Void)?
    /// Asks the server for the entitlement again
    /// (`PurchaseService.refreshEntitlement`). Set by the app.
    @ObservationIgnored var recheckEntitlement: (() -> Void)?
    /// Drops Stexx+ locally when `plusExpiresAt` passes.
    @ObservationIgnored private var plusExpiryTask: Task<Void, Never>?

    private enum Keys {
        static let ageConfirmed = "stexx.ageConfirmed"
        /// Older versions kept the privacy toggles here (and treated them as
        /// the truth). Removed on launch.
        static let legacyPrivacy = "stexx.privacy"
    }

    init(
        defaults: UserDefaults = .standard,
        sessionStore: any SessionStore = KeychainSessionStore(),
        travelStore: any TravelPlaceStore = FileTravelPlaceStore()
    ) {
        self.defaults = defaults
        self.sessionStore = sessionStore
        self.travelStore = travelStore
        self.isAgeConfirmed = defaults.bool(forKey: Keys.ageConfirmed)
        self.session = sessionStore.load()
        defaults.removeObject(forKey: Keys.legacyPrivacy)
        self.travel = session == nil ? nil : travelStore.load()
    }

    var isSignedIn: Bool { isAgeConfirmed && session != nil }
    var myID: Profile.ID { session?.userID ?? MockData.myID }

    // MARK: Onboarding & session

    /// Only the fact that the user confirmed 18+ is stored, never a birth date.
    func confirmAge() {
        isAgeConfirmed = true
        defaults.set(true, forKey: Keys.ageConfirmed)
    }

    func signIn(_ session: Session) {
        try? sessionStore.save(session)
        self.session = session
    }

    /// The user signed out (or deleted the account, `wipeLocalData`). Clears
    /// the session and erases the account's encryption keys and decrypted
    /// chat history from this phone (`eraseAccountData`); signing back in
    /// starts with new keys, and earlier encrypted messages show as not
    /// available on this phone. `wipeLocalData` also forgets the 18+
    /// confirmation. A plain sign-out also revokes the session on the server.
    func signOut(wipeLocalData: Bool = false) {
        if let session {
            if !wipeLocalData { revokeSession?(session) }
            eraseAccountData?(session.userID)
        }
        clearSession()
        if wipeLocalData {
            defaults.removeObject(forKey: Keys.ageConfirmed)
            isAgeConfirmed = false
        }
    }

    /// The client rotated the tokens (already saved to the store).
    func sessionDidRefresh(_ session: Session) {
        guard self.session != nil else { return }
        self.session = session
    }

    /// The server rejected the refresh token: back to onboarding, keeping
    /// the 18+ flag, and the encryption keys and history for when the same
    /// account signs in again.
    func sessionDidExpire() {
        guard session != nil else { return }
        clearSession()
    }

    private func clearSession() {
        sessionStore.clear()
        session = nil
        me = nil
        hasPlus = false
        setPlusExpiry(nil)
        blockedIDs = []
        // The place belongs to this account; the next one starts clean.
        setTravel(nil)
        // So do the privacy settings: the next account loads its own.
        accountGeneration += 1
        privacySave?.cancel()
        privacySave = nil
        privacy = PrivacySettings()
        savedPrivacy = PrivacySettings()
        privacyStatus = .loading
        privacyError = nil
    }

    // MARK: Stexx+

    /// Applies the server's view of the entitlement.
    func applySubscription(_ status: SubscriptionStatus) {
        hasPlus = status.isActive
        setPlusExpiry(status.isActive ? status.expiresAt : nil)
        // The server's travel `isActive` is the same entitlement check.
        if me?.travel != nil, me?.travel?.isActive != status.isActive {
            me?.travel?.isActive = status.isActive
        }
        if !status.isActive { dropPlusOnlySettings() }
    }

    /// The server answered 402 `requires_plus`: the entitlement is gone (or
    /// never existed), so turn off Plus-only settings and show the paywall.
    func handleRequiresPlus() {
        hasPlus = false
        setPlusExpiry(nil)
        dropPlusOnlySettings()
        isPaywallPresented = true
    }

    /// Drops Stexx+ if `plusExpiresAt` has passed (run by a timer at that
    /// moment). The server stops applying Plus features then, travel mode
    /// included, so the UI follows right away instead of at the next
    /// foreground. Plus-only settings are only dropped once the server
    /// confirms (a renewal may already be on its way).
    func checkPlusExpiry(now: Date = .now) {
        guard hasPlus, let plusExpiresAt, plusExpiresAt <= now else { return }
        plusDidLapse()
    }

    /// Stexx+ looks gone (local clock or `GET /me`): show the free state and
    /// ask the server, which turns it back on if it was renewed.
    private func plusDidLapse() {
        hasPlus = false
        setPlusExpiry(nil)
        if me?.travel?.isActive == true { me?.travel?.isActive = false }
        recheckEntitlement?()
    }

    private func setPlusExpiry(_ date: Date?) {
        plusExpiresAt = date
        plusExpiryTask?.cancel()
        plusExpiryTask = nil
        guard let date else { return }
        let delay = date.timeIntervalSinceNow
        // Already past: the server says active, trust it until the next check.
        guard delay > 0 else { return }
        plusExpiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay) + .milliseconds(500), clock: .continuous)
            guard !Task.isCancelled else { return }
            self?.checkPlusExpiry()
        }
    }

    private func dropPlusOnlySettings() {
        // Re-sending incognito without Plus would just 402 again; the server
        // accepts turning it off.
        if privacy.incognito {
            if privacyStatus == .loaded {
                setPrivacy(\.incognito, to: false)
            } else {
                privacy.incognito = false
            }
        }
        // Travel mode is NOT dropped: the server keeps the cell and ignores
        // it while Stexx+ is off (`isTravelPaused`), and resumes it when
        // Stexx+ is back. The user can still turn it off for free.
    }

    // MARK: Travel mode (Stexx+)

    /// You browse, and others see you, from the travel place right now.
    var isTravelActive: Bool { travel != nil && hasPlus }

    /// Travel mode is on but has no effect because Stexx+ has lapsed.
    var isTravelPaused: Bool { travel != nil && !hasPlus }

    /// The server accepted a travel change (`PUT /me/travel`): `place` is
    /// the new travel place, `nil` when it was turned off.
    func travelDidChange(to place: TravelPlace?) {
        setTravel(place)
        me?.travel = place.map { _ in TravelStatus(isActive: hasPlus) }
    }

    /// Adopts the server's state. On but unknown here (a reinstall, or set
    /// before this version): on, without a place. Paused by the server
    /// (`isActive: false`) while this device still thinks it has Stexx+:
    /// the server has already moved you back home, so Plus is dropped here
    /// too and re-checked.
    private func syncTravel(with status: TravelStatus?) {
        switch (status, travel) {
        case (nil, nil), (.some, .some): break
        case (nil, .some): setTravel(nil)
        case (.some, nil): setTravel(TravelPlace())
        }
        if status?.isActive == false, hasPlus { plusDidLapse() }
    }

    private func setTravel(_ place: TravelPlace?) {
        guard place != travel else { return }
        travel = place
        travelRevision += 1
        if let place {
            travelStore.save(place)
        } else {
            travelStore.clear()
        }
    }

    // MARK: Profile & privacy

    enum PrivacyStatus: Equatable, Sendable {
        /// Not loaded from the server yet: toggles disabled.
        case loading
        case loaded
        /// `GET /me` failed: toggles disabled, with a retry.
        case unavailable
    }

    /// The privacy toggles can be changed (the server's values are known).
    var isPrivacyEditable: Bool { privacyStatus == .loaded }

    /// `GET /me`: your profile, travel mode and privacy settings. Run on
    /// launch and sign-in (the main tabs), and to retry from Settings.
    func loadMe(from api: any APIClient) async {
        let generation = accountGeneration
        if privacyStatus == .unavailable { privacyStatus = .loading }
        do {
            let profile = try await api.fetchMe()
            guard generation == accountGeneration else { return }
            me = profile
            // A server without `privacy` on /me: nothing to show truthfully.
            if profile.privacy == nil, privacyStatus == .loading { privacyStatus = .unavailable }
        } catch {
            guard generation == accountGeneration else { return }
            if privacyStatus == .loading { privacyStatus = .unavailable }
        }
    }

    /// Adopts the server's settings, unless a change is being saved (its
    /// answer is newer).
    func adoptServerPrivacy(_ settings: PrivacySettings) {
        guard privacySave == nil else { return }
        savedPrivacy = settings
        privacy = settings
        privacyStatus = .loaded
    }

    /// Changes one privacy setting: shown at once, saved on the server, and
    /// rolled back (with `privacyError`) if the save fails. Ignored until the
    /// settings have loaded. Changes made while a save is running are sent
    /// together right after it, so the server ends up with the last choice.
    func setPrivacy(_ setting: WritableKeyPath<PrivacySettings, Bool>, to value: Bool) {
        guard privacyStatus == .loaded, privacy[keyPath: setting] != value else { return }
        privacy[keyPath: setting] = value
        privacyError = nil
        savePrivacyIfNeeded()
    }

    private func savePrivacyIfNeeded() {
        guard privacySave == nil, privacy != savedPrivacy, let savePrivacy else { return }
        let wanted = privacy
        let generation = accountGeneration
        privacySave = Task { [weak self] in
            let result: Result<PrivacySettings, any Error>
            do {
                result = .success(try await savePrivacy(wanted))
            } catch {
                result = .failure(error)
            }
            self?.privacySaveFinished(result, wanted: wanted, generation: generation)
        }
    }

    private func privacySaveFinished(_ result: Result<PrivacySettings, any Error>, wanted: PrivacySettings, generation: Int) {
        // Signed out meanwhile: the next account's settings aren't touched.
        guard generation == accountGeneration else { return }
        privacySave = nil
        switch result {
        case .success(let saved):
            savedPrivacy = saved
            if privacy == wanted {
                // The server may have adjusted it (incognito after Stexx+ lapsed).
                privacy = saved
            } else {
                savePrivacyIfNeeded()
            }
        case .failure(let error):
            privacy = savedPrivacy
            if case APIError.requiresPlus = error {
                // The paywall explains it; nothing else to say.
                handleRequiresPlus()
            } else {
                privacyError = Self.privacySaveMessage(for: error)
            }
        }
    }

    /// Waits until no privacy save is running (tests).
    func privacySavesFinished() async {
        while let save = privacySave { await save.value }
    }

    /// The user saw the message.
    func clearPrivacyError() {
        privacyError = nil
    }

    static func privacySaveMessage(for error: any Error) -> String {
        if let apiError = error as? APIError, case .rateLimited = apiError {
            return apiError.localizedDescription
        }
        return String(localized: "Couldn't save that change, so it was switched back. Check your connection and try again.")
    }

    // MARK: Safety

    func markBlocked(_ id: Profile.ID) {
        blockedIDs.insert(id)
    }

    func markUnblocked(_ id: Profile.ID) {
        blockedIDs.remove(id)
    }

    /// Opens the paywall unless the user already has Stexx+.
    /// Returns `true` when the gated feature may be used.
    @discardableResult
    func requirePlus() -> Bool {
        if hasPlus { return true }
        isPaywallPresented = true
        return false
    }
}

extension AppState {
    /// A signed-in state backed by in-memory storage, for previews.
    static func preview(signedIn: Bool = true, plus: Bool = false) -> AppState {
        let defaults = UserDefaults(suiteName: "stexx.preview") ?? .standard
        defaults.removePersistentDomain(forName: "stexx.preview")
        let state = AppState(defaults: defaults, sessionStore: InMemorySessionStore(), travelStore: InMemoryTravelPlaceStore())
        state.savePrivacy = { try await MockAPIClient.shared.updatePrivacy($0) }
        if signedIn {
            state.confirmAge()
            state.signIn(MockData.session)
            state.me = MockData.me
        }
        state.hasPlus = plus
        return state
    }
}
