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
    /// Stexx+ entitlement. Will come from StoreKit 2 transactions.
    var hasPlus = false
    /// Profiles blocked during this session; hidden everywhere immediately,
    /// even before the server round-trip finishes.
    private(set) var blockedIDs: Set<Profile.ID> = []
    var isPaywallPresented = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let sessionStore: any SessionStore

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
    /// settings, used after account deletion.
    func signOut(wipeLocalData: Bool = false) {
        sessionStore.clear()
        session = nil
        me = nil
        hasPlus = false
        blockedIDs = []
        if wipeLocalData {
            defaults.removeObject(forKey: Keys.ageConfirmed)
            defaults.removeObject(forKey: Keys.privacy)
            isAgeConfirmed = false
            privacy = PrivacySettings()
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
