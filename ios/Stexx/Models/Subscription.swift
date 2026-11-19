import Foundation

/// Stexx+ entitlement as reported by the server
/// (`GET /subscriptions/status`, `POST /subscriptions/apple`). The server is
/// the source of truth; local StoreKit state only triggers a re-check.
struct SubscriptionStatus: Codable, Hashable, Sendable {
    var isActive: Bool
    var expiresAt: Date?
    /// Whether the subscription renews at `expiresAt` (Apple's auto-renew
    /// status, which the server learns from App Store Server Notifications).
    /// `nil` when not active or not known yet. Older servers omit it.
    var willRenew: Bool? = nil
    /// End of the running boost; `nil` when no boost is running. Older
    /// servers omit it.
    var boostEndsAt: Date? = nil

    static let inactive = SubscriptionStatus(isActive: false, expiresAt: nil)

    /// What the paywall says about the current subscription period.
    enum Renewal: Hashable, Sendable {
        /// Auto-renew is on: the next charge is on this date.
        case renews(Date)
        /// Auto-renew is off: Stexx+ ends on this date.
        case ends(Date)
        /// Active, but the server doesn't know the auto-renew status yet.
        case activeUntil(Date)
    }

    /// `nil` unless Stexx+ is active with a known end date.
    var renewal: Renewal? {
        guard isActive, let expiresAt else { return nil }
        switch willRenew {
        case true?: return .renews(expiresAt)
        case false?: return .ends(expiresAt)
        case nil: return .activeUntil(expiresAt)
        }
    }
}

extension SubscriptionStatus.Renewal {
    var date: Date {
        switch self {
        case .renews(let date), .ends(let date), .activeUntil(let date): date
        }
    }

    /// "Stexx+ renews on 19 December 2026" (date in the user's locale).
    func label(locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        var style = Date.FormatStyle(date: .long, time: .omitted, locale: locale)
        style.timeZone = timeZone
        let day = date.formatted(style)
        switch self {
        case .renews: return String(localized: "Stexx+ renews on \(day)")
        case .ends: return String(localized: "Stexx+ ends on \(day)")
        case .activeUntil: return String(localized: "Stexx+ is active until \(day)")
        }
    }
}

/// `POST /subscriptions/apple` body: the StoreKit 2 transaction JWS.
struct AppleTransactionSubmission: Codable, Hashable, Sendable {
    var signedTransaction: String
}

/// `POST /boosts` response.
struct Boost: Codable, Hashable, Sendable {
    var endsAt: Date
}
