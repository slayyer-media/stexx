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
    var hasPlus = false
    private(set) var plusExpiresAt: Date?
    /// Profiles blocked during this session; hidden everywhere immediately,
    /// even before the server round-trip finishes.
    private(set) var blockedIDs: Set<Profile.ID> = []
    var isPaywallPresented = false
    /// Stexx+ travel mode, or `nil` when it's off. The server says whether
    /// it's on; where it is (the cell that was sent and a place name looked
    /// up on this phone) is only kept here, in this device's preferences.
    private(set) var travel: TravelPlace?
    /// Bumped whenever travel mode is turned on, moved or off, so the grid
    /// reloads.
    private(set) var travelRevision = 0

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let sessionStore: any SessionStore
    /// Revokes a session on the server when the user signs out. Set by the app.
    @ObservationIgnored var revokeSession: ((Session) -> Void)?

    private enum Keys {
        static let ageConfirmed = "stexx.ageConfirmed"
        static let privacy = "stexx.privacy"
        static let travel = "stexx.travel"
    }

    init(defaults: UserDefaults = .standard, sessionStore: any SessionStore = KeychainSessionStore()) {
        self.defaults = defaults
        self.sessionStore = sessionStore
        self.isAgeConfirmed = defaults.bool(forKey: Keys.ageConfirmed)
        self.session = sessionStore.load()
        self.privacy = defaults.data(forKey: Keys.privacy)
            .flatMap { try? JSONDecoder().decode(PrivacySettings.self, from: $0) } ?? PrivacySettings()
        self.travel = session == nil ? nil : defaults.data(forKey: Keys.travel)
            .flatMap { try? JSONDecoder().decode(TravelPlace.self, from: $0) }
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
        plusExpiresAt = nil
        blockedIDs = []
        // The place belongs to this account; the next one starts clean.
        setTravel(nil)
    }

    // MARK: Stexx+

    /// Applies the server's view of the entitlement.
    func applySubscription(_ status: SubscriptionStatus) {
        hasPlus = status.isActive
        plusExpiresAt = status.isActive ? status.expiresAt : nil
        if !status.isActive { dropPlusOnlySettings() }
    }

    /// The server answered 402 `requires_plus`: the entitlement is gone (or
    /// never existed), so turn off Plus-only settings and show the paywall.
    func handleRequiresPlus() {
        hasPlus = false
        plusExpiresAt = nil
        dropPlusOnlySettings()
        isPaywallPresented = true
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
    /// before this version): on, without a place.
    private func syncTravel(with status: TravelStatus?) {
        switch (status, travel) {
        case (nil, nil), (.some, .some): return
        case (nil, .some): setTravel(nil)
        case (.some, nil): setTravel(TravelPlace())
        }
    }

    private func setTravel(_ place: TravelPlace?) {
        guard place != travel else { return }
        travel = place
        travelRevision += 1
        if let place, let data = try? JSONEncoder().encode(place) {
            defaults.set(data, forKey: Keys.travel)
        } else {
            defaults.removeObject(forKey: Keys.travel)
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
        let state = AppState(defaults: defaults, sessionStore: InMemorySessionStore())
        if signedIn {
            state.confirmAge()
            state.signIn(MockData.session)
            state.me = MockData.me
        }
        state.hasPlus = plus
        return state
    }
}
