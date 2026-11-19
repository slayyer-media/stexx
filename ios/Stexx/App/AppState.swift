import Foundation
import Observation

/// App-wide state: onboarding progress, session, the user's own profile,
/// privacy settings, entitlements and the local block list.
@MainActor
@Observable
final class AppState {
    private(set) var isAgeConfirmed: Bool
    private(set) var session: Session?
    var me: Profile? = nil
    var privacy: PrivacySettings
    /// Stexx+ entitlement. Set from the server (`GET /subscriptions/status`,
    /// 402 responses); StoreKit purchases only trigger a server re-check.
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

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let sessionStore: any SessionStore
    /// Revokes a session on the server when the user signs out. Set by the app.
    @ObservationIgnored var revokeSession: ((Session) -> Void)?

    private enum Keys {
        static let ageConfirmed = "stexx.ageConfirmed"
        static let privacy = "stexx.privacy"
    }

    init(defaults: UserDefaults = .standard, sessionStore: any SessionStore = KeychainSessionStore()) {
        self.defaults = defaults
        self.sessionStore = sessionStore
        self.isAgeConfirmed = defaults.bool(forKey: Keys.ageConfirmed)
        self.session = sessionStore.load()
        self.privacy = defaults.data(forKey: Keys.privacy)
            .flatMap { try? JSONDecoder().decode(PrivacySettings.self, from: $0) } ?? PrivacySettings()
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
        plusWillRenew = nil
        boostEndsAt = nil
        blockedIDs = []
    }

    // MARK: Stexx+

    /// Applies the server's view of the entitlement.
    func applySubscription(_ status: SubscriptionStatus) {
        hasPlus = status.isActive
        plusExpiresAt = status.isActive ? status.expiresAt : nil
        plusWillRenew = status.isActive ? status.willRenew : nil
        boostEndsAt = status.boostEndsAt
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
        plusExpiresAt = nil
        plusWillRenew = nil
        dropPlusOnlySettings()
        isPaywallPresented = true
    }

    private func dropPlusOnlySettings() {
        // Re-sending incognito without Plus would just 402 again.
        if privacy.incognito { privacy.incognito = false }
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
