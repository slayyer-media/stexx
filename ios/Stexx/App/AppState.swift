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
    /// state (`Profile.travel`): the server wins.
    var me: Profile? = nil {
        didSet { if let me { syncTravel(with: me.travel) } }
    }
    var privacy: PrivacySettings
    /// Stexx+ entitlement. Set from the server (`GET /subscriptions/status`,
    /// 402 responses); StoreKit purchases only trigger a server re-check.
    /// Also dropped when `plusExpiresAt` passes while the app is open, or
    /// when `GET /me` reports travel mode paused (both followed by a server
    /// re-check), so the UI never claims a Plus feature the server has
    /// already stopped applying.
    var hasPlus = false
    private(set) var plusExpiresAt: Date?
    /// Auto-renew status of the current Stexx+ period (`nil`: unknown or
    /// not active), for "renews on" / "ends on".
    private(set) var plusWillRenew: Bool?
    /// End of the running boost, so it survives a relaunch.
    private(set) var boostEndsAt: Date?
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
        static let privacy = "stexx.privacy"
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
        self.privacy = defaults.data(forKey: Keys.privacy)
            .flatMap { try? JSONDecoder().decode(PrivacySettings.self, from: $0) } ?? PrivacySettings()
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

    /// Clears the session. `wipeLocalData` also forgets onboarding and
    /// settings, used after account deletion. A plain sign-out also revokes
    /// the session on the server.
    func signOut(wipeLocalData: Bool = false) {
        if !wipeLocalData, let session { revokeSession?(session) }
        clearSession()
        if wipeLocalData {
            defaults.removeObject(forKey: Keys.ageConfirmed)
            defaults.removeObject(forKey: Keys.privacy)
            isAgeConfirmed = false
            privacy = PrivacySettings()
        }
    }

    /// The client rotated the tokens (already saved to the store).
    func sessionDidRefresh(_ session: Session) {
        guard self.session != nil else { return }
        self.session = session
    }

    /// The server rejected the refresh token: back to onboarding, keeping
    /// the 18+ flag and settings.
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
        plusWillRenew = nil
        boostEndsAt = nil
        blockedIDs = []
        // The place belongs to this account; the next one starts clean.
        setTravel(nil)
    }

    // MARK: Stexx+

    /// Applies the server's view of the entitlement.
    func applySubscription(_ status: SubscriptionStatus) {
        hasPlus = status.isActive
        setPlusExpiry(status.isActive ? status.expiresAt : nil)
        plusWillRenew = status.isActive ? status.willRenew : nil
        boostEndsAt = status.boostEndsAt
        // The server's travel `isActive` is the same entitlement check.
        if me?.travel != nil, me?.travel?.isActive != status.isActive {
            me?.travel?.isActive = status.isActive
        }
        if !status.isActive { dropPlusOnlySettings() }
    }

    /// "Renews on" / "ends on" for the paywall; `nil` without Stexx+.
    var plusRenewal: SubscriptionStatus.Renewal? {
        SubscriptionStatus(isActive: hasPlus, expiresAt: plusExpiresAt, willRenew: plusWillRenew).renewal
    }

    /// The server answered 402 `requires_plus`: the entitlement is gone (or
    /// never existed), so turn off Plus-only settings and show the paywall.
    func handleRequiresPlus() {
        hasPlus = false
        setPlusExpiry(nil)
        plusWillRenew = nil
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
        // Re-sending incognito without Plus would just 402 again.
        if privacy.incognito { privacy.incognito = false }
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

    // MARK: Privacy

    func persistPrivacy() {
        if let data = try? JSONEncoder().encode(privacy) {
            defaults.set(data, forKey: Keys.privacy)
        }
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
        if signedIn {
            state.confirmAge()
            state.signIn(MockData.session)
            state.me = MockData.me
        }
        state.hasPlus = plus
        return state
    }
}
