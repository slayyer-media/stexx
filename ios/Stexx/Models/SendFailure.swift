import Foundation

/// Why a message or photo didn't go out, as shown under its failed bubble
/// (with Retry and Delete). Built from the error the send threw.
struct SendFailure: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// 429: sending too fast. Retry works after `retryAfter`.
        case rateLimited
        /// 403 `new_account_limit`: a new account wrote to too many people.
        case newAccountLimit
        /// 403 `links_not_allowed` (server) or the app's own link rule
        /// before encrypting.
        case linksNotAllowed
        /// 403 `duplicate_message`: the same text to many people.
        case duplicate
        /// 403 `account_under_review`: hidden after reports.
        case underReview
        /// The other person's security key changed; accept it first.
        case keyChange
        /// Encryption problems (no keys yet, an update needed, libsignal).
        case encryption
        /// The chat or the person is gone (deleted, blocked).
        case unavailable
        /// The network or anything unexpected.
        case other
    }

    var kind: Kind
    /// One short, friendly sentence.
    var reason: String
    /// When a rate-limited send can go again (`Retry-After`).
    var retryAfter: Date?
    /// The request may have reached the server before it failed (a
    /// timeout, a dropped connection, a 5xx): the message may already be
    /// delivered. Retry is safe (same client ID, deduplicated); removing the
    /// bubble only removes it from this phone, and the thread says so.
    var mayHaveSent: Bool = false

    /// Server error codes (`docs/api.md`, anti-spam) the app explains itself.
    enum Code {
        static let newAccountLimit = "new_account_limit"
        static let linksNotAllowed = "links_not_allowed"
        static let duplicateMessage = "duplicate_message"
        static let accountUnderReview = "account_under_review"
    }

    init(kind: Kind, reason: String, retryAfter: Date? = nil, mayHaveSent: Bool = false) {
        self.kind = kind
        self.reason = reason
        self.retryAfter = retryAfter
        self.mayHaveSent = mayHaveSent
    }

    /// Transport failures after which the request may have been handled
    /// (sent, then the answer was lost). The others mean it never left.
    private static let uncertainURLErrors: Set<URLError.Code> = [
        .timedOut, .networkConnectionLost, .badServerResponse, .cannotParseResponse,
    ]

    private static let mayHaveSentReason = String(localized: "May not have been sent. Check your connection and retry.")

    init(_ error: any Error, now: Date = .now) {
        switch error {
        case let error as E2EError:
            switch error {
            case .identityChanged:
                self.init(kind: .keyChange, reason: String(localized: "Their security key changed. Accept the new key at the top, then retry."))
            case .notSignedIn:
                self.init(kind: .other, reason: error.localizedDescription)
            case .recipientHasNoKeys, .encryptionFailed, .messageTooLong:
                self.init(kind: .encryption, reason: error.localizedDescription)
            }
        case let violation as E2EContentRules.Violation:
            // The app's copy of the server's text rules for new accounts.
            self.init(kind: violation == .linksNotAllowed ? .linksNotAllowed : .duplicate, reason: violation.localizedDescription)
        case let error as APIError:
            self.init(api: error, now: now)
        case let error as URLError where Self.uncertainURLErrors.contains(error.code):
            self.init(kind: .other, reason: Self.mayHaveSentReason, mayHaveSent: true)
        case is URLError:
            self.init(kind: .other, reason: String(localized: "Not sent. Check your connection and retry."))
        default:
            self.init(kind: .other, reason: String(localized: "Not sent. Try again in a moment."))
        }
    }

    private init(api error: APIError, now: Date) {
        switch error {
        case .rateLimited(let retryAfter):
            self.init(
                kind: .rateLimited,
                reason: APIError.rateLimitedMessage(retryAfter: retryAfter),
                retryAfter: retryAfter.map { now.addingTimeInterval($0) }
            )
        case .server(_, let message, let code?) where code == Code.newAccountLimit:
            self.init(kind: .newAccountLimit, reason: message ?? String(localized: "New accounts can only start a few chats a day. Try again tomorrow."))
        case .server(_, let message, let code?) where code == Code.linksNotAllowed:
            self.init(kind: .linksNotAllowed, reason: message ?? String(localized: "New accounts can't send links yet. Remove the link and retry."))
        case .server(_, let message, let code?) where code == Code.duplicateMessage:
            self.init(kind: .duplicate, reason: message ?? String(localized: "You've sent this exact message to several people already. Try something personal."))
        case .server(_, let message, let code?) where code == Code.accountUnderReview:
            self.init(kind: .underReview, reason: message ?? String(localized: "Your account is being reviewed. You can only reply to people who wrote to you."))
        case .server(let status, let message?, _) where status == 400 || status == 403:
            self.init(kind: .other, reason: message)
        case .e2e(let code, _) where code == E2EErrorCode.encryptionRequired:
            self.init(kind: .encryption, reason: error.localizedDescription)
        case .e2e:
            self.init(kind: .encryption, reason: String(localized: "Couldn't send this encrypted. Try again in a moment."))
        case .notFound:
            self.init(kind: .unavailable, reason: String(localized: "This chat isn't available any more."))
        case .unauthorized:
            self.init(kind: .other, reason: error.localizedDescription)
        case .server(let status, _, _) where status >= 500:
            // The server may have stored it before failing.
            self.init(kind: .other, reason: Self.mayHaveSentReason, mayHaveSent: true)
        case .requiresPlus, .server, .invalidResponse:
            self.init(kind: .other, reason: String(localized: "Not sent. Try again in a moment."))
        }
    }

    /// Retrying can work: everything except a chat that's gone. (A content
    /// refusal can work after the user removes the link, or once a limit
    /// resets, so it isn't ruled out.)
    var canRetry: Bool { kind != .unavailable }
}
