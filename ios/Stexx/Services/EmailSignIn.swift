import Foundation
import Observation
import SwiftUI

// Email sign-up and sign-in (docs/api.md, "Auth & account"):
//
// 1. `POST /auth/email/link` sends ONE email with a sign-in link and an
//    8-digit code. For a new account the nickname and the 18+ confirmation
//    travel with the request; the account is only created when the link or
//    code comes back, so an address nobody can read never gets an account.
// 2. Either the link opens the app (universal link, `EmailLinkRedeemer`) and
//    `POST /auth/email/verify` trades its token for a session, or the user
//    types the code here (`EmailSignInModel`) and `POST /auth/email/code`
//    does. The code covers links read on another device and mail apps that
//    don't hand links to the app.
//
// `POST /auth/register` is the dev server's shortcut only; production
// answers it with 400 `use_email_link`.

/// `POST /auth/email/link`. `displayName` and `confirmedAdult` are sent
/// together for a sign-up, and left out for a sign-in.
struct EmailLinkRequest: Encodable, Hashable, Sendable {
    var email: String
    var displayName: String?
    var confirmedAdult: Bool?

    static func signIn(email: String) -> EmailLinkRequest {
        EmailLinkRequest(email: email)
    }

    /// Only reached after the 18+ gate, so the confirmation travels along.
    static func signUp(email: String, displayName: String) -> EmailLinkRequest {
        EmailLinkRequest(email: email, displayName: displayName, confirmedAdult: true)
    }
}

/// Server answers specific to email sign-in (their `code`).
enum EmailSignInError: Error, Equatable, Sendable {
    /// 400 `invalid_link`: used, expired or unknown link token.
    case invalidLink
    /// 400 `invalid_code`: wrong, used, expired or locked code.
    case invalidCode
    /// 400 `registration_required`: no account for the address, and the
    /// link was requested without a nickname (from the sign-in screen).
    case registrationRequired
    /// 503 `email_unavailable`: the server can't send email right now.
    case unavailable

    init?(code: String?) {
        switch code {
        case "invalid_link": self = .invalidLink
        case "invalid_code": self = .invalidCode
        case "registration_required": self = .registrationRequired
        case "email_unavailable": self = .unavailable
        default: return nil
        }
    }
}

/// What went wrong, in words for people. Pure, so it is unit tested.
enum EmailSignInProblem: Equatable, Sendable {
    case expiredLink
    case wrongCode
    case noAccount
    case unavailable
    /// 429: wait until the date (the server's `Retry-After`).
    case rateLimited(until: Date)
    case offline
    /// Any other answer, shown as the server wrote it (e.g. 400
    /// `disposable_email`, 403 `device_account_limit`).
    case other(String)

    /// The server said something final about the link itself (used or
    /// expired, or no account to sign in to). Anything else (no signal, a
    /// rate limit, email or server trouble) left the link unused, so the same
    /// link may be tried again.
    var isFinalForLink: Bool {
        switch self {
        case .expiredLink, .noAccount: true
        case .wrongCode, .unavailable, .rateLimited, .offline, .other: false
        }
    }

    static func from(_ error: any Error, now: Date = .now) -> EmailSignInProblem {
        switch error {
        case let error as EmailSignInError:
            switch error {
            case .invalidLink: return .expiredLink
            case .invalidCode: return .wrongCode
            case .registrationRequired: return .noAccount
            case .unavailable: return .unavailable
            }
        case APIError.rateLimited(let retryAfter):
            return .rateLimited(until: now.addingTimeInterval(retryAfter ?? EmailSignInModel.resendCooldown))
        case let error as URLError where Self.offlineCodes.contains(error.code):
            return .offline
        default:
            return .other(error.localizedDescription)
        }
    }

    private static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost,
        .dataNotAllowed, .internationalRoamingOff,
    ]

    var title: String {
        switch self {
        case .expiredLink: String(localized: "this link has expired")
        case .wrongCode: String(localized: "that code didn't work")
        case .noAccount: String(localized: "no account yet")
        case .unavailable: String(localized: "email is down")
        case .rateLimited: String(localized: "slow down a little")
        case .offline: String(localized: "you're offline")
        case .other: String(localized: "that didn't work")
        }
    }

    func message(now: Date = .now) -> String {
        switch self {
        case .expiredLink:
            String(localized: "Sign-in links work once, for 15 minutes. Ask for a new one and use the latest email.")
        case .wrongCode:
            String(localized: "Check the 8 digits in your latest Stexx email. Codes work once, for 15 minutes.")
        case .noAccount:
            String(localized: "There's no Stexx account for this address yet. Sign up first: it takes a nickname and the same email.")
        case .unavailable:
            String(localized: "We can't send email right now. Try again in a few minutes, or use a passkey.")
        case .rateLimited(let until):
            String(localized: "You've asked for a few emails already. Use the latest one, or ask again in \(Self.countdown(until.timeIntervalSince(now))).")
        case .offline:
            String(localized: "Check your connection and try again.")
        case .other(let message):
            message
        }
    }

    /// "4:05" for 245 s; never negative.
    static func countdown(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }
}

/// The "check your email" step for sign-up and sign-in: sends the email,
/// handles resends (with the server's rate limit) and the typed code.
@MainActor
@Observable
final class EmailSignInModel {
    enum Purpose: Equatable, Sendable {
        case signUp(displayName: String)
        case signIn
    }

    enum Phase: Equatable, Sendable {
        /// Nothing sent yet (or the first send failed).
        case idle
        case sending
        /// An email is on its way to `address`.
        case sent
        case verifying
    }

    /// Seconds between resends when the server doesn't say. The server
    /// allows 3 emails per 15 minutes per address and device.
    nonisolated static let resendCooldown: TimeInterval = 60
    nonisolated static let codeLength = 8

    let purpose: Purpose
    private(set) var phase: Phase = .idle
    /// The normalized address the last email went to.
    private(set) var address = ""
    private(set) var problem: EmailSignInProblem?
    /// When "Send another email" works again.
    private(set) var resendAvailableAt: Date?
    /// Emails accepted by the server in this flow.
    private(set) var sentCount = 0
    /// The typed code: digits only, at most 8 (set through `updateCode`).
    private(set) var code = ""

    @ObservationIgnored private let api: any APIClient
    @ObservationIgnored private let now: () -> Date
    /// The complete code that last went out on its own (see `claimAutoSubmit`).
    @ObservationIgnored private var autoSubmittedCode: String?

    init(purpose: Purpose, api: any APIClient, now: @escaping () -> Date = { .now }) {
        self.purpose = purpose
        self.api = api
        self.now = now
    }

    var isBusy: Bool { phase == .sending || phase == .verifying }

    /// What the code field typed, pasted or AutoFilled: keeps digits only,
    /// at most 8, and clears a "wrong code" message.
    func updateCode(_ raw: String) {
        code = Self.sanitizedCode(raw)
        if problem == .wrongCode { problem = nil }
    }

    nonisolated static func sanitizedCode(_ raw: String) -> String {
        String(raw.filter { ("0"..."9").contains($0) }.prefix(codeLength))
    }
    var isCodeComplete: Bool { code.count == Self.codeLength }

    /// Whether a complete code should be submitted on its own right now:
    /// once per code (a wrong one goes again only after an edit), and only
    /// when it can be (not while an email is being sent or a code checked).
    /// Says yes once, and remembers the code. Asked when the code changes and
    /// again when the model is free, so 8 digits pasted during a resend still
    /// go out when it finishes.
    func claimAutoSubmit() -> Bool {
        guard phase == .sent, isCodeComplete, code != autoSubmittedCode else { return false }
        autoSubmittedCode = code
        return true
    }

    /// Seconds until a resend is allowed (0 = now).
    func resendWait(at date: Date? = nil) -> TimeInterval {
        guard let resendAvailableAt else { return 0 }
        return max(0, resendAvailableAt.timeIntervalSince(date ?? now()))
    }

    func canResend(at date: Date? = nil) -> Bool {
        phase == .sent && resendWait(at: date) == 0
    }

    /// Sends the first email. Returns whether to show the "check your
    /// email" screen: also after a 429, since an earlier email is then
    /// likely waiting in the inbox.
    @discardableResult
    func send(to email: String) async -> Bool {
        let normalized = Self.normalize(email)
        guard !isBusy, !normalized.isEmpty else { return false }
        address = normalized
        code = ""
        return await deliver()
    }

    /// "Send another email", once the countdown is over.
    func resend() async {
        guard canResend() else { return }
        await deliver()
    }

    /// Trades the typed code for a session. On failure the problem is set
    /// and nil comes back.
    func submitCode() async -> Session? {
        guard phase == .sent, isCodeComplete else { return nil }
        phase = .verifying
        problem = nil
        defer { if phase == .verifying { phase = .sent } }
        do {
            return try await api.verifyEmailCode(email: address, code: code)
        } catch {
            let problem = EmailSignInProblem.from(error, now: now())
            if case .rateLimited(let until) = problem { resendAvailableAt = max(resendAvailableAt ?? until, until) }
            self.problem = problem
            return nil
        }
    }

    /// Back to the address field.
    func reset() {
        phase = .idle
        problem = nil
        code = ""
    }

    @discardableResult
    private func deliver() async -> Bool {
        let previous = phase
        phase = .sending
        problem = nil
        let request: EmailLinkRequest = switch purpose {
        case .signUp(let displayName): .signUp(email: address, displayName: displayName)
        case .signIn: .signIn(email: address)
        }
        do {
            try await api.requestEmailLink(request)
            sentCount += 1
            phase = .sent
            resendAvailableAt = now().addingTimeInterval(Self.resendCooldown)
            return true
        } catch {
            let problem = EmailSignInProblem.from(error, now: now())
            self.problem = problem
            if case .rateLimited(let until) = problem {
                // Earlier emails are still good: wait it out on the next screen.
                phase = .sent
                resendAvailableAt = until
                return true
            }
            phase = previous == .sent ? .sent : .idle
            return false
        }
    }

    nonisolated static func normalize(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Loose check before sending; the server has the final say.
    nonisolated static func looksLikeEmail(_ email: String) -> Bool {
        let value = normalize(email)
        guard let at = value.firstIndex(of: "@"), at != value.startIndex, !value.contains(" ") else { return false }
        let domain = value[value.index(after: at)...]
        return domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".") && !domain.contains("@")
    }
}

/// Email sign-in links that reach the app (universal links): what to do
/// with one, and the sign-in it starts.
@MainActor
@Observable
final class EmailLinkRedeemer {
    enum State: Equatable {
        case idle
        /// The 18+ gate is per device; it comes first on a new iPhone. The
        /// token is kept (in memory) and only used after it.
        case needsAgeConfirmation
        case verifying
        /// Someone is signed in on this iPhone already; the link is left
        /// unused.
        case alreadySignedIn
        case failed(EmailSignInProblem)
    }

    /// Where the onboarding should go after a failed link.
    enum FollowUp: Equatable {
        case signIn, signUp
    }

    private(set) var state: State = .idle
    /// Set by the problem sheet's button; the onboarding flow consumes it.
    var followUp: FollowUp?

    @ObservationIgnored private var pendingToken: String?
    /// A link that signed in, or that the server called used, expired or
    /// account-less: delivering it again does nothing.
    @ObservationIgnored private var lastRedeemedToken: String?
    /// The link of a failed attempt the server didn't burn (offline, 429,
    /// 503, server error), for "Try again".
    @ObservationIgnored private var retryToken: String?
    @ObservationIgnored private let now: () -> Date

    init(now: @escaping () -> Date = { .now }) {
        self.now = now
    }

    /// Decides what to do with an opened URL. Returns false when it isn't a
    /// sign-in link (someone else's to handle). When the state becomes
    /// `.verifying`, call `redeem(with:)`.
    @discardableResult
    func handle(_ url: URL, isSignedIn: Bool, isAgeConfirmed: Bool) -> Bool {
        guard let token = EmailSignInLink.token(from: url) else { return false }
        // The same link delivered twice (or tapped again while in flight).
        guard token != lastRedeemedToken, state != .verifying else { return true }
        retryToken = nil
        if isSignedIn {
            pendingToken = nil
            state = .alreadySignedIn
            return true
        }
        pendingToken = token
        state = isAgeConfirmed ? .verifying : .needsAgeConfirmation
        return true
    }

    /// After the 18+ gate on this device.
    func ageConfirmed() {
        guard state == .needsAgeConfirmation, pendingToken != nil else { return }
        state = .verifying
    }

    /// Uses the pending token. Returns the session on success (state back to
    /// `.idle`); otherwise the state says why.
    func redeem(with api: any APIClient) async -> Session? {
        guard state == .verifying, let token = pendingToken else { return nil }
        pendingToken = nil
        retryToken = nil
        do {
            let session = try await api.verifyEmailLink(token: token)
            lastRedeemedToken = token
            state = .idle
            return session
        } catch {
            let problem = EmailSignInProblem.from(error, now: now())
            if problem.isFinalForLink {
                lastRedeemedToken = token
            } else {
                // Not burnt: tapping the link in Mail again, or "Try again", has another go.
                if lastRedeemedToken == token { lastRedeemedToken = nil }
                retryToken = token
            }
            state = .failed(problem)
            return nil
        }
    }

    /// Whether the problem sheet can offer "Try again" with the same link.
    var canRetry: Bool {
        guard case .failed(let problem) = state else { return false }
        return !problem.isFinalForLink && retryToken != nil
    }

    /// "Try again" after a failure that left the link unused. When the state
    /// becomes `.verifying`, call `redeem(with:)`.
    func retry() {
        guard canRetry, let token = retryToken else { return }
        retryToken = nil
        pendingToken = token
        state = .verifying
    }

    /// Closes whatever is shown; forgets an unused token.
    func dismiss(followUp: FollowUp? = nil) {
        pendingToken = nil
        retryToken = nil
        state = .idle
        self.followUp = followUp
    }
}

extension EnvironmentValues {
    /// Debug builds against a dev server (`Local`): offer the dev server's
    /// `POST /auth/register` shortcut next to the real email flow.
    @Entry var allowsDevSignUpShortcut = false
}
