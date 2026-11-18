import Foundation

/// Stexx+ entitlement as reported by the server
/// (`GET /subscriptions/status`, `POST /subscriptions/apple`). The server is
/// the source of truth; local StoreKit state only triggers a re-check.
struct SubscriptionStatus: Codable, Hashable, Sendable {
    var isActive: Bool
    var expiresAt: Date?

    static let inactive = SubscriptionStatus(isActive: false, expiresAt: nil)
}

/// `POST /subscriptions/apple` body: the StoreKit 2 transaction JWS.
struct AppleTransactionSubmission: Codable, Hashable, Sendable {
    var signedTransaction: String
}

/// `POST /boosts` response.
struct Boost: Codable, Hashable, Sendable {
    var endsAt: Date
}
