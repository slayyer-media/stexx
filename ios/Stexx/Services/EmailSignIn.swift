import Foundation
import Observation
import Security
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
//
// Every email is bound to this app install by a random request nonce
// (`EmailRequestNonceStore`): the code only works here, and a link this
// install didn't ask for (someone sending you a link to *their* account)
// is only used after "Sign in as …?" (docs/security.md, login CSRF).

/// `POST /auth/email/link`. `displayName` and `confirmedAdult` are sent
/// together for a sign-up, and left out for a sign-in.
struct EmailLinkRequest: Encodable, Hashable, Sendable {
    var email: String
    var displayName: String?
    var confirmedAdult: Bool?
    /// Binds the email to this app install (only its hash is stored).
    var requestNonce: String?

    static func signIn(email: String, requestNonce: String? = nil) -> EmailLinkRequest {
        EmailLinkRequest(email: email, requestNonce: requestNonce)
    }

    /// Only reached after the 18+ gate, so the confirmation travels along.
    static func signUp(email: String, displayName: String, requestNonce: String? = nil) -> EmailLinkRequest {
        EmailLinkRequest(email: email, displayName: displayName, confirmedAdult: true, requestNonce: requestNonce)
    }
}

/// Whose account a link this app didn't ask for would sign in to (409
/// `confirm_link`).
struct EmailLinkAccount: Equatable, Sendable {
    /// The link creates this account (a sign-up link) rather than signing
    /// in to an existing one.
    var isNew: Bool
    var displayName: String
}

/// The random value that ties sign-in emails to this app install. Sent with
/// every `POST /auth/email/link` (the server keeps only its hash), with the
/// code, and with every link this app opens.
protocol EmailRequestNonceStore: Sendable {
    /// The nonce for a new email: the pending one if it was used within the
    /// last hour (so every email of one sign-in shares it), else a new one.
    func issue(now: Date) -> String
    /// The pending nonce, if any.
    func current(now: Date) -> String?
    /// After signing in: the next sign-in starts with a new one.
    func clear()
}

enum EmailRequestNonce {
    /// How long a nonce stays pending after its last email. Emails live 15
    /// minutes; this only decides when a fresh nonce is due.
    static let lifetime: TimeInterval = 60 * 60

    /// 32 random bytes, base64url (what the server expects: 20-200 chars).
    static func random() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            var generator = SystemRandomNumberGenerator()
            bytes = bytes.map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    struct Stored: Codable, Equatable {
        var nonce: String
        var usedAt: Date
    }
}

/// In the Keychain (this device only), so a link tapped after iOS closed
/// the app while Mail was open still counts as asked for here.
struct KeychainEmailRequestNonceStore: EmailRequestNonceStore {
    var service = "gay.stexx.app.email-request"
    var account = "nonce"

    func issue(now: Date) -> String {
        let nonce = current(now: now) ?? EmailRequestNonce.random()
        save(EmailRequestNonce.Stored(nonce: nonce, usedAt: now))
        return nonce
    }

    func current(now: Date) -> String? {
        guard let stored = load(), now.timeIntervalSince(stored.usedAt) < EmailRequestNonce.lifetime else { return nil }
        return stored.nonce
    }

    func clear() {
        _ = SecItemDelete(baseQuery as CFDictionary)
    }

    private func load() -> EmailRequestNonce.Stored? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(EmailRequestNonce.Stored.self, from: data)
    }

    private func save(_ stored: EmailRequestNonce.Stored) {
        guard let data = try? JSONEncoder().encode(stored) else { return }
        clear()
        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        _ = SecItemAdd(query as CFDictionary, nil)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// Tests and previews.
final class InMemoryEmailRequestNonceStore: EmailRequestNonceStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: EmailRequestNonce.Stored?

    init(pending: String? = nil, usedAt: Date = .now) {
        stored = pending.map { EmailRequestNonce.Stored(nonce: $0, usedAt: usedAt) }
    }

    func issue(now: Date) -> String {
        lock.withLock {
            let nonce = stored.flatMap { now.timeIntervalSince($0.usedAt) < EmailRequestNonce.lifetime ? $0.nonce : nil }
                ?? EmailRequestNonce.random()
            stored = EmailRequestNonce.Stored(nonce: nonce, usedAt: now)
            return nonce
        }
    }

    func current(now: Date) -> String? {
        lock.withLock {
            guard let stored, now.timeIntervalSince(stored.usedAt) < EmailRequestNonce.lifetime else { return nil }
            return stored.nonce
        }
    }

    func clear() {
        lock.withLock { stored = nil }
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
    /// 409 `confirm_link`: a link this app didn't ask for. It is left
    /// unused until the person confirms the account.
    case confirmationRequired(EmailLinkAccount)

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
    /// 429 on an email: wait until the date (the server's `Retry-After`).
    case rateLimited(until: Date)
    /// 429 on the code: too many tries from here for this address.
    case tooManyCodeAttempts(until: Date)
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
        case .wrongCode, .unavailable, .rateLimited, .tooManyCodeAttempts, .offline, .other: false
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
            // Handled by `EmailLinkRedeemer` before it gets here.
            case .confirmationRequired: return .other(String(localized: "Confirm the account to use this link."))
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
        case .rateLimited, .tooManyCodeAttempts: String(localized: "slow down a little")
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
        case .tooManyCodeAttempts(let until):
            String(localized: "Too many tries with codes. Use the link in the email, or try again in \(Self.countdown(until.timeIntervalSince(now))).")
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
    @ObservationIgnored private let nonces: any EmailRequestNonceStore
    @ObservationIgnored private let now: () -> Date
    /// The complete code that last went out on its own (see `claimAutoSubmit`).
    @ObservationIgnored private var autoSubmittedCode: String?
    /// The nonce this flow's emails were asked for with; the code needs it.
    @ObservationIgnored private var requestNonce: String?

    init(
        purpose: Purpose,
        api: any APIClient,
        nonces: any EmailRequestNonceStore = KeychainEmailRequestNonceStore(),
        now: @escaping () -> Date = { .now }
    ) {
        self.purpose = purpose
        self.api = api
        self.nonces = nonces
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
        // The code only works with the nonce its email was asked for with
        // (after a 429 on the first send, that's the pending one).
        let nonce = requestNonce ?? nonces.current(now: now()) ?? EmailRequestNonce.random()
        do {
            let session = try await api.verifyEmailCode(email: address, code: code, requestNonce: nonce)
            nonces.clear()
            return session
        } catch {
            var problem = EmailSignInProblem.from(error, now: now())
            // The code's own limit, not the email one: resending is still fine.
            if case .rateLimited(let until) = problem { problem = .tooManyCodeAttempts(until: until) }
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
        let nonce = nonces.issue(now: now())
        requestNonce = nonce
        let request: EmailLinkRequest = switch purpose {
        case .signUp(let displayName): .signUp(email: address, displayName: displayName, requestNonce: nonce)
        case .signIn: .signIn(email: address, requestNonce: nonce)
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
        /// A link this app didn't ask for: "Sign in as …?" before it is
        /// used. The token is kept (in memory) until the answer.
        case needsConfirmation(EmailLinkAccount)
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
    /// The person said yes to this link's account.
    @ObservationIgnored private var confirmedToken: String?
    /// A link that signed in, or that the server called used, expired or
    /// account-less: delivering it again does nothing.
    @ObservationIgnored private var lastRedeemedToken: String?
    /// The link of a failed attempt the server didn't burn (offline, 429,
    /// 503, server error), for "Try again".
    @ObservationIgnored private var retryToken: String?
    @ObservationIgnored private let nonces: any EmailRequestNonceStore
    @ObservationIgnored private let now: () -> Date

    init(nonces: any EmailRequestNonceStore = KeychainEmailRequestNonceStore(), now: @escaping () -> Date = { .now }) {
        self.nonces = nonces
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
        confirmedToken = nil
        if isSignedIn {
            pendingToken = nil
            state = .alreadySignedIn
            return true
        }
        pendingToken = token
        state = isAgeConfirmed ? .verifying : .needsAgeConfirmation
        return true
    }

    /// "Sign in" on the confirmation sheet. When the state becomes
    /// `.verifying`, call `redeem(with:)`.
    func confirmAccount() {
        guard case .needsConfirmation = state, let pendingToken else { return }
        confirmedToken = pendingToken
        state = .verifying
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
        // Always sends a nonce, so the server always checks: with none
        // pending, a throwaway one that matches no link.
        let nonce = nonces.current(now: now()) ?? EmailRequestNonce.random()
        let confirmed = confirmedToken == token
        do {
            let session = try await api.verifyEmailLink(token: token, requestNonce: nonce, confirmed: confirmed)
            lastRedeemedToken = token
            confirmedToken = nil
            nonces.clear()
            state = .idle
            return session
        } catch EmailSignInError.confirmationRequired(let account) {
            // Unused: ask whose account it is first.
            pendingToken = token
            state = .needsConfirmation(account)
            return nil
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
        // A confirmed link stays confirmed for "Try again".
        retryToken = nil
        pendingToken = token
        state = .verifying
    }

    /// Closes whatever is shown; forgets an unused token.
    func dismiss(followUp: FollowUp? = nil) {
        pendingToken = nil
        retryToken = nil
        confirmedToken = nil
        state = .idle
        self.followUp = followUp
    }
}

extension EnvironmentValues {
    /// Debug builds against a dev server (`Local`): offer the dev server's
    /// `POST /auth/register` shortcut next to the real email flow.
    @Entry var allowsDevSignUpShortcut = false
}
