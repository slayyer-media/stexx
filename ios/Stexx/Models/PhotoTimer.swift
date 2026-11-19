import Foundation

/// What happens to a chat photo after the recipient sees it, chosen by the
/// sender before sending (`ChatThreadView`'s attachment menu).
///
/// On the wire (`MessageDraft`, `docs/api.md`):
/// - `keep`: `isViewOnce: false`, no timer.
/// - `viewOnce`: `isViewOnce: true`, no timer; the server deletes the photo
///   shortly after the recipient opens it.
/// - a timed option: `expiresAfterSeconds` (counted from when the recipient
///   reads the thread) with `isViewOnce: false`.
///
/// The same fields go into an end-to-end encrypted photo's envelope
/// (`E2EAPIClient.sendPhoto`), so encrypted and plaintext photos behave alike.
enum PhotoTimer: String, CaseIterable, Hashable, Sendable, Identifiable {
    case keep
    case viewOnce
    case tenSeconds
    case oneMinute
    case oneHour
    case oneDay

    var id: String { rawValue }

    /// The default for a new thread: what the app did before there was a
    /// choice. "Expiring photos by default" sent photos that expire a
    /// minute after they're read; otherwise photos were kept.
    static func `default`(expiringByDefault: Bool) -> PhotoTimer {
        expiringByDefault ? .oneMinute : .keep
    }

    /// Seconds after reading until the photo expires, for the timed options.
    var expiresAfterSeconds: Int? {
        switch self {
        case .keep, .viewOnce: nil
        case .tenSeconds: 10
        case .oneMinute: 60
        case .oneHour: 3600
        case .oneDay: 86_400
        }
    }

    var isViewOnce: Bool { self == .viewOnce }

    /// The draft's `expiresAfterSeconds` and `isViewOnce`. `isViewOnce` is
    /// always explicit, so the server never falls back to the sender's
    /// "expiring photos by default" setting behind the user's back.
    var draftFields: (expiresAfterSeconds: Int?, isViewOnce: Bool) {
        (expiresAfterSeconds, isViewOnce)
    }

    /// Applies this timer to a photo draft.
    func apply(to draft: inout MessageDraft) {
        draft.expiresAfterSeconds = expiresAfterSeconds
        draft.isViewOnce = isViewOnce
    }

    /// Picker title.
    var title: String {
        switch self {
        case .keep: String(localized: "Keep")
        case .viewOnce: String(localized: "View once")
        case .tenSeconds: String(localized: "10 seconds")
        case .oneMinute: String(localized: "1 minute")
        case .oneHour: String(localized: "1 hour")
        case .oneDay: String(localized: "1 day")
        }
    }

    /// Short form for the composer badge and VoiceOver ("10s", "1m", …);
    /// nil when photos are kept.
    var shortTitle: String? {
        switch self {
        case .keep: nil
        case .viewOnce: String(localized: "1×")
        case .tenSeconds: String(localized: "10s")
        case .oneMinute: String(localized: "1m")
        case .oneHour: String(localized: "1h")
        case .oneDay: String(localized: "1d")
        }
    }

    var systemImage: String {
        switch self {
        case .keep: "photo"
        case .viewOnce: "eye.slash"
        case .tenSeconds, .oneMinute, .oneHour, .oneDay: "timer"
        }
    }

    /// What the attachments button says to VoiceOver about photos sent now.
    var accessibilityDescription: String {
        switch self {
        case .keep: String(localized: "Photos are kept")
        case .viewOnce: String(localized: "Photos are view once")
        case .tenSeconds: String(localized: "Photos disappear 10 seconds after they're read")
        case .oneMinute: String(localized: "Photos disappear 1 minute after they're read")
        case .oneHour: String(localized: "Photos disappear 1 hour after they're read")
        case .oneDay: String(localized: "Photos disappear 1 day after they're read")
        }
    }
}
