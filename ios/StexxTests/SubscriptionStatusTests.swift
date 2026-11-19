import Foundation
import Testing
@testable import Stexx

/// `SubscriptionStatus` read-back (`willRenew`, `boostEndsAt`), the paywall's
/// "renews on / ends on" label, and the legal links.
struct SubscriptionStatusTests {
    private static let december19 = Date(timeIntervalSince1970: 1_797_674_400) // 2026-12-19T10:00:00Z

    private func decode(_ json: String) throws -> SubscriptionStatus {
        try JSONDecoder.stexx().decode(SubscriptionStatus.self, from: Data(json.utf8))
    }

    @Test("Decodes a response from an older server without the new fields")
    func decodesWithoutNewFields() throws {
        let status = try decode(#"{"isActive": true, "expiresAt": "2026-12-19T10:00:00Z"}"#)
        #expect(status.isActive)
        #expect(status.expiresAt == Self.december19)
        #expect(status.willRenew == nil)
        #expect(status.boostEndsAt == nil)
    }

    @Test("Decodes willRenew and boostEndsAt")
    func decodesNewFields() throws {
        let status = try decode("""
        {"isActive": true, "expiresAt": "2026-12-19T10:00:00Z", "willRenew": false, "boostEndsAt": "2026-11-19T11:00:00Z"}
        """)
        #expect(status.willRenew == false)
        #expect(status.boostEndsAt == Date(timeIntervalSince1970: 1_795_086_000))
    }

    @Test("Decodes explicit nulls (a free user)")
    func decodesNulls() throws {
        let status = try decode(#"{"isActive": false, "expiresAt": null, "willRenew": null, "boostEndsAt": null}"#)
        #expect(status == .inactive)
        #expect(status.renewal == nil)
    }

    @Test("Round-trips through the app's encoder")
    func roundTrips() throws {
        let status = SubscriptionStatus(isActive: true, expiresAt: Self.december19, willRenew: true, boostEndsAt: nil)
        let data = try JSONEncoder.stexx().encode(status)
        #expect(try JSONDecoder.stexx().decode(SubscriptionStatus.self, from: data) == status)
    }

    @Test("Renewal follows willRenew; nothing without an active subscription and an end date")
    func renewalCases() {
        let d = Self.december19
        #expect(SubscriptionStatus(isActive: true, expiresAt: d, willRenew: true).renewal == .renews(d))
        #expect(SubscriptionStatus(isActive: true, expiresAt: d, willRenew: false).renewal == .ends(d))
        #expect(SubscriptionStatus(isActive: true, expiresAt: d, willRenew: nil).renewal == .activeUntil(d))
        #expect(SubscriptionStatus(isActive: false, expiresAt: d, willRenew: true).renewal == nil)
        #expect(SubscriptionStatus(isActive: true, expiresAt: nil, willRenew: true).renewal == nil)
    }

    @Test("Labels: renews on / ends on / active until, with the date in the user's locale")
    func labels() throws {
        let en = Locale(identifier: "en_US")
        let utc = try #require(TimeZone(identifier: "UTC"))
        let d = Self.december19
        #expect(SubscriptionStatus.Renewal.renews(d).label(locale: en, timeZone: utc) == "Stexx+ renews on December 19, 2026")
        #expect(SubscriptionStatus.Renewal.ends(d).label(locale: en, timeZone: utc) == "Stexx+ ends on December 19, 2026")
        #expect(SubscriptionStatus.Renewal.activeUntil(d).label(locale: en, timeZone: utc) == "Stexx+ is active until December 19, 2026")
        // The calendar day is the user's: just before midnight UTC is already the next day in Tokyo.
        let lateUTC = Date(timeIntervalSince1970: 1_797_724_740) // 2026-12-19T23:59:00Z
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        #expect(SubscriptionStatus.Renewal.ends(lateUTC).label(locale: en, timeZone: tokyo) == "Stexx+ ends on December 20, 2026")
    }

    @Test("Legal links are https pages on stexx.gay")
    func legalLinks() {
        for url in [LegalLinks.terms, LegalLinks.privacy, LegalLinks.guidelines] {
            #expect(url.scheme == "https")
            #expect(url.host() == "stexx.gay")
        }
        #expect(Set([LegalLinks.terms, LegalLinks.privacy, LegalLinks.guidelines]).count == 3)
    }
}

@MainActor
struct SubscriptionStateTests {
    private func appState() -> AppState {
        let suite = "stexx.tests.\(UUID().uuidString)"
        let state = AppState(defaults: UserDefaults(suiteName: suite)!, sessionStore: InMemorySessionStore())
        state.confirmAge()
        state.signIn(MockData.session)
        return state
    }

    @Test("AppState keeps willRenew and the boost end from the server; losing Plus clears willRenew")
    func appStateApplies() {
        let state = appState()
        let expires = Date.now.addingTimeInterval(10 * 86_400)
        let boost = Date.now.addingTimeInterval(1_800)
        state.applySubscription(SubscriptionStatus(isActive: true, expiresAt: expires, willRenew: false, boostEndsAt: boost))
        #expect(state.plusRenewal == .ends(expires))
        #expect(state.boostEndsAt == boost)

        state.applySubscription(.inactive)
        #expect(state.plusRenewal == nil)
        #expect(state.plusWillRenew == nil)
        #expect(state.boostEndsAt == nil)
    }

    @Test("Mock backend: subscribers renew, boosts don't stack and show up in the status")
    func mockReadBack() async throws {
        let api = MockAPIClient(latency: .zero)
        _ = try await api.submitAppleTransaction(signedTransaction: "jws")
        var status = try await api.subscriptionStatus()
        #expect(status.willRenew == true)
        #expect(status.boostEndsAt == nil)

        let first = try await api.startBoost()
        let second = try await api.startBoost()
        #expect(first.endsAt == second.endsAt)
        status = try await api.subscriptionStatus()
        #expect(status.boostEndsAt == first.endsAt)

        let state = appState()
        let purchases = PurchaseService(api: api, appState: state)
        await purchases.refreshEntitlement()
        #expect(state.plusRenewal == .renews(try #require(status.expiresAt)))
        #expect(state.boostEndsAt == first.endsAt)
    }
}
