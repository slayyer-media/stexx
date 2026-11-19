import Foundation
import Testing
@testable import Stexx

/// A clock the tests move by hand.
@MainActor
private final class EmailTestClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

/// Canned answers per path, in order; records each request's path and JSON body.
private actor ScriptedServer {
    typealias Reply = (status: Int, headers: [String: String], body: Data)
    private var replies: [String: [Reply]] = [:]
    private var requests: [(path: String, body: Data)] = []

    func queue(_ path: String, _ reply: Reply) { replies[path, default: []].append(reply) }

    func answer(_ request: URLRequest) -> Reply {
        let path = request.url?.path() ?? ""
        requests.append((path, request.httpBody ?? request.httpBodyStream.map(readStream) ?? Data()))
        guard var list = replies[path], !list.isEmpty else { return (500, [:], Data()) }
        let reply = list.removeFirst()
        replies[path] = list
        return reply
    }

    func rawBodies(_ path: String) -> [Data] { requests.filter { $0.path == path }.map(\.body) }
    func count(_ path: String) -> Int { requests.filter { $0.path == path }.count }

    /// The JSON bodies sent to `path`, in order.
    nonisolated func bodies(_ path: String) async -> [[String: Any]] {
        await rawBodies(path).map { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] ?? [:] }
    }
}

private func readStream(_ stream: InputStream) -> Data {
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        data.append(buffer, count: count)
    }
    return data
}

private let sessionJSON = Fixtures.json(Fixtures.session("acc", refresh: "ref"))
private let linkPath = "/v1/auth/email/link"
private let verifyPath = "/v1/auth/email/verify"
private let codePath = "/v1/auth/email/code"

private func client(for server: ScriptedServer) -> HTTPAPIClient {
    let baseURL = StubURLProtocol.register { request in await server.answer(request) }
    return HTTPAPIClient(
        configuration: APIConfiguration(baseURL: baseURL, useMock: false),
        session: StubURLProtocol.session(),
        sessions: SessionCoordinator(store: InMemorySessionStore())
    )
}

private func error(_ status: Int, _ code: String, headers: [String: String] = [:]) -> ScriptedServer.Reply {
    (status, headers, Fixtures.json(["code": code, "message": "server says \(code)"]))
}

// MARK: - Wire format and error mapping

struct EmailSignInWireTests {
    @Test("Sign-up sends the nickname and 18+ with the link request; sign-in sends only the address")
    func linkBodies() async throws {
        let server = ScriptedServer()
        await server.queue(linkPath, (204, [:], Data()))
        await server.queue(linkPath, (204, [:], Data()))
        let api = client(for: server)
        try await api.requestEmailLink(.signUp(email: "otter@example.com", displayName: "QuantumOtter"))
        try await api.requestEmailLink(.signIn(email: "otter@example.com"))
        let bodies = await server.bodies(linkPath)
        #expect(bodies.count == 2)
        #expect(bodies[0]["email"] as? String == "otter@example.com")
        #expect(bodies[0]["displayName"] as? String == "QuantumOtter")
        #expect(bodies[0]["confirmedAdult"] as? Bool == true)
        // The server refuses one without the other, so both keys are left out (not null).
        #expect(bodies[1].keys.sorted() == ["email"])
    }

    @Test("The code goes to /auth/email/code with the address and comes back as a session")
    func codeRequest() async throws {
        let server = ScriptedServer()
        await server.queue(codePath, (200, [:], sessionJSON))
        let session = try await client(for: server).verifyEmailCode(email: "otter@example.com", code: "01234567", requestNonce: "nonce-nonce-nonce-nonce")
        #expect(session.accessToken == "acc")
        let body = try #require(await server.bodies(codePath).first)
        #expect(body["email"] as? String == "otter@example.com")
        #expect(body["code"] as? String == "01234567")
        #expect(body["requestNonce"] as? String == "nonce-nonce-nonce-nonce")
    }

    @Test("The code route carries device attestation like the other email routes")
    func codeIsAttested() {
        #expect(HTTPAPIClient.attestedRoute("POST", "auth/email/code") != nil)
        #expect(HTTPAPIClient.attestedRoute("POST", "auth/email/link") != nil)
        #expect(HTTPAPIClient.attestedRoute("POST", "auth/email/verify") != nil)
    }

    @Test(
        "Email error codes become EmailSignInError",
        arguments: [
            (400, "invalid_link", EmailSignInError.invalidLink),
            (400, "invalid_code", .invalidCode),
            (400, "registration_required", .registrationRequired),
            (503, "email_unavailable", .unavailable),
        ]
    )
    func errorCodes(status: Int, code: String, expected: EmailSignInError) async throws {
        let server = ScriptedServer()
        await server.queue(verifyPath, error(status, code))
        await #expect(throws: expected) {
            try await client(for: server).verifyEmailLink(token: "t0k3n-t0k3n-t0k3n-t0k3n", requestNonce: "n0nc3-n0nc3-n0nc3-n0nc3", confirmed: false)
        }
    }

    @Test("Other answers keep their server message (disposable email) and 429 keeps Retry-After")
    func otherErrors() async throws {
        let server = ScriptedServer()
        await server.queue(linkPath, error(400, "disposable_email"))
        await server.queue(linkPath, error(429, "rate_limited", headers: ["Retry-After": "245"]))
        let api = client(for: server)
        await #expect(throws: APIError.server(status: 400, message: "server says disposable_email", code: "disposable_email")) {
            try await api.requestEmailLink(.signIn(email: "a@mailinator.com"))
        }
        await #expect(throws: APIError.rateLimited(retryAfter: 245)) {
            try await api.requestEmailLink(.signIn(email: "a@example.com"))
        }
    }

    @Test("Problems in words: mapping, countdown and copy")
    func problems() {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(EmailSignInProblem.from(EmailSignInError.invalidLink) == .expiredLink)
        #expect(EmailSignInProblem.from(EmailSignInError.invalidCode) == .wrongCode)
        #expect(EmailSignInProblem.from(EmailSignInError.registrationRequired) == .noAccount)
        #expect(EmailSignInProblem.from(EmailSignInError.unavailable) == .unavailable)
        #expect(EmailSignInProblem.from(APIError.rateLimited(retryAfter: 90), now: now) == .rateLimited(until: now.addingTimeInterval(90)))
        #expect(EmailSignInProblem.from(APIError.rateLimited(retryAfter: nil), now: now) == .rateLimited(until: now.addingTimeInterval(60)))
        #expect(EmailSignInProblem.from(URLError(.notConnectedToInternet)) == .offline)
        #expect(EmailSignInProblem.from(APIError.server(status: 403, message: "One account per device.")) == .other("One account per device."))

        #expect(EmailSignInProblem.countdown(245) == "4:05")
        #expect(EmailSignInProblem.countdown(0.2) == "0:01")
        #expect(EmailSignInProblem.countdown(-3) == "0:00")
        let limited = EmailSignInProblem.rateLimited(until: now.addingTimeInterval(75))
        #expect(limited.message(now: now).contains("1:15"))
        #expect(EmailSignInProblem.expiredLink.message().contains("15 minutes"))
    }

    @Test(arguments: ["a@b.co", "  otter@example.com ", "first.last+tag@sub.example.org"])
    func plausibleAddresses(_ value: String) {
        #expect(EmailSignInModel.looksLikeEmail(value))
    }

    @Test(arguments: ["", "otter", "@example.com", "otter@", "otter@example", "otter@.com", "otter@example.", "ot ter@example.com", "a@b@c.com"])
    func implausibleAddresses(_ value: String) {
        #expect(!EmailSignInModel.looksLikeEmail(value))
    }
}

// MARK: - The "check your email" state machine

@MainActor
struct EmailSignInModelTests {
    @Test("Send → sent, with a 60 s resend countdown that the clock runs down")
    func sendAndCountdown() async throws {
        let server = ScriptedServer()
        await server.queue(linkPath, (204, [:], Data()))
        await server.queue(linkPath, (204, [:], Data()))
        let clock = EmailTestClock()
        let model = EmailSignInModel(purpose: .signUp(displayName: "QuantumOtter"), api: client(for: server), nonces: InMemoryEmailRequestNonceStore(), now: { clock.now })
        #expect(model.phase == .idle)

        #expect(await model.send(to: "  otter@example.com "))
        #expect(model.phase == .sent)
        #expect(model.address == "otter@example.com")
        #expect(model.sentCount == 1)
        #expect(model.resendWait() == 60)
        #expect(!model.canResend())

        await model.resend() // too early: nothing sent
        #expect(await server.count(linkPath) == 1)

        clock.advance(59)
        #expect(model.resendWait() == 1)
        clock.advance(1)
        #expect(model.canResend())
        await model.resend()
        #expect(model.sentCount == 2)
        #expect(model.resendWait() == 60)
        // every email of a sign-up carries the pending registration
        for body in await server.bodies(linkPath) {
            #expect(body["displayName"] as? String == "QuantumOtter")
        }
    }

    @Test("429 on a resend: the countdown follows Retry-After and a warning explains it")
    func resendRateLimited() async throws {
        let server = ScriptedServer()
        await server.queue(linkPath, (204, [:], Data()))
        await server.queue(linkPath, error(429, "rate_limited", headers: ["Retry-After": "240"]))
        let clock = EmailTestClock()
        let model = EmailSignInModel(purpose: .signIn, api: client(for: server), nonces: InMemoryEmailRequestNonceStore(), now: { clock.now })
        await model.send(to: "otter@example.com")
        clock.advance(60)
        await model.resend()
        #expect(model.phase == .sent)
        #expect(model.sentCount == 1)
        #expect(model.resendWait() == 240)
        #expect(model.problem == .rateLimited(until: clock.now.addingTimeInterval(240)))
    }

    @Test("429 on the first send still shows the inbox screen (an earlier email is waiting), with the wait")
    func firstSendRateLimited() async throws {
        let server = ScriptedServer()
        await server.queue(linkPath, error(429, "rate_limited", headers: ["Retry-After": "120"]))
        let clock = EmailTestClock()
        let model = EmailSignInModel(purpose: .signIn, api: client(for: server), nonces: InMemoryEmailRequestNonceStore(), now: { clock.now })
        #expect(await model.send(to: "otter@example.com"))
        #expect(model.phase == .sent)
        #expect(model.sentCount == 0)
        #expect(model.resendWait() == 120)
    }

    @Test("Other failures on the first send stay on the form with the server's words")
    func firstSendFails() async throws {
        let server = ScriptedServer()
        await server.queue(linkPath, error(400, "disposable_email"))
        await server.queue(linkPath, error(503, "email_unavailable"))
        let model = EmailSignInModel(purpose: .signIn, api: client(for: server), nonces: InMemoryEmailRequestNonceStore())
        #expect(!(await model.send(to: "a@mailinator.com")))
        #expect(model.phase == .idle)
        #expect(model.problem == .other("server says disposable_email"))
        #expect(!(await model.send(to: "a@example.com")))
        #expect(model.problem == .unavailable)
        #expect(!(await model.send(to: "   ")))
    }

    @Test("The code field keeps digits only, at most 8 (paste, AutoFill, spaces)")
    func codeSanitizing() {
        let model = EmailSignInModel(purpose: .signIn, api: MockAPIClient(latency: .zero), nonces: InMemoryEmailRequestNonceStore())
        model.updateCode("1234 5678")
        #expect(model.code == "12345678")
        #expect(model.isCodeComplete)
        model.updateCode("12-34-56-78-90")
        #expect(model.code == "12345678")
        model.updateCode("abc12")
        #expect(model.code == "12")
        #expect(!model.isCodeComplete)
    }

    @Test("Wrong code: stays on the screen with a message that goes away when the code is edited; right code signs in")
    func codeFlow() async throws {
        let server = ScriptedServer()
        await server.queue(linkPath, (204, [:], Data()))
        await server.queue(codePath, error(400, "invalid_code"))
        await server.queue(codePath, (200, [:], sessionJSON))
        let model = EmailSignInModel(purpose: .signIn, api: client(for: server), nonces: InMemoryEmailRequestNonceStore())
        #expect(await model.submitCode() == nil) // nothing sent yet
        await model.send(to: "otter@example.com")

        model.updateCode("1111111")
        #expect(await model.submitCode() == nil) // incomplete: not sent
        #expect(await server.count(codePath) == 0)

        model.updateCode("11111111")
        #expect(await model.submitCode() == nil)
        #expect(model.problem == .wrongCode)
        #expect(model.phase == .sent)
        model.updateCode("2222222")
        #expect(model.problem == nil)

        model.updateCode("22222222")
        let session = try #require(await model.submitCode())
        #expect(session.accessToken == "acc")
        #expect(await server.bodies(codePath).last?["email"] as? String == "otter@example.com")
    }

    @Test("Auto-submit: once per complete code, and 8 digits that land during a resend go out when it's done")
    func autoSubmit() async throws {
        let clock = EmailTestClock()
        let model = EmailSignInModel(purpose: .signIn, api: MockAPIClient(latency: .milliseconds(300)), nonces: InMemoryEmailRequestNonceStore(), now: { clock.now })
        model.updateCode("12345678")
        #expect(!model.claimAutoSubmit()) // nothing sent yet
        await model.send(to: "otter@example.com")
        model.updateCode("1234567")
        #expect(!model.claimAutoSubmit()) // incomplete

        clock.advance(EmailSignInModel.resendCooldown)
        let resend = Task { await model.resend() }
        while model.phase != .sending { await Task.yield() }
        model.updateCode("12345678") // pasted while the resend is in flight
        #expect(!model.claimAutoSubmit())
        await resend.value
        #expect(model.phase == .sent)
        #expect(model.claimAutoSubmit()) // the view asks again when the phase is back to .sent
        #expect(!model.claimAutoSubmit()) // once per code
        model.updateCode("1234567")
        model.updateCode("12345679")
        #expect(model.claimAutoSubmit()) // an edited code goes out again
    }

    @Test("A code for an address without an account says to sign up")
    func codeWithoutAccount() async throws {
        let server = ScriptedServer()
        await server.queue(linkPath, (204, [:], Data()))
        await server.queue(codePath, error(400, "registration_required"))
        let model = EmailSignInModel(purpose: .signIn, api: client(for: server), nonces: InMemoryEmailRequestNonceStore())
        await model.send(to: "new@example.com")
        model.updateCode("12345678")
        #expect(await model.submitCode() == nil)
        #expect(model.problem == .noAccount)
    }

    @Test("Different address: back to the form, code cleared")
    func reset() async {
        let model = EmailSignInModel(purpose: .signIn, api: MockAPIClient(latency: .zero), nonces: InMemoryEmailRequestNonceStore())
        await model.send(to: "otter@example.com")
        model.updateCode("123")
        model.reset()
        #expect(model.phase == .idle)
        #expect(model.code.isEmpty)
    }

    @Test("Mock backend: fake emails carry code 12345678, links work once, 4th email in 15 min is 429")
    func mockBackend() async throws {
        let mock = MockAPIClient(latency: .zero)
        let model = EmailSignInModel(purpose: .signUp(displayName: "MockOtter"), api: mock, nonces: InMemoryEmailRequestNonceStore())
        await model.send(to: "otter@example.com")
        model.updateCode("87654321")
        #expect(await model.submitCode() == nil)
        #expect(model.problem == .wrongCode)
        model.updateCode(MockAPIClient.emailCode)
        #expect(await model.submitCode() != nil)
        #expect(try await mock.fetchMe().displayName == "MockOtter")

        try await mock.requestEmailLink(.signIn(email: "link@example.com"))
        let token = try #require(await mock.lastEmailLinkToken)
        _ = try await mock.verifyEmailLink(token: token, requestNonce: "other", confirmed: true)
        await #expect(throws: EmailSignInError.invalidLink) { try await mock.verifyEmailLink(token: token, requestNonce: "other", confirmed: true) }

        try await mock.requestEmailLink(.signIn(email: "link@example.com"))
        try await mock.requestEmailLink(.signIn(email: "link@example.com"))
        let limited = await #expect(throws: APIError.self) {
            try await mock.requestEmailLink(.signIn(email: "LINK@example.com"))
        }
        guard case .rateLimited(let wait?) = limited else {
            Issue.record("expected 429 with a wait, got \(String(describing: limited))")
            return
        }
        #expect(wait > 0 && wait <= 900)
    }
}

// MARK: - Links that open the app

@MainActor
struct EmailLinkRedeemerTests {
    private let link = URL(string: "https://stexx.gay/auth/email?token=tok_abcdefghijklmnopqrstuvwxyz")!

    @Test("Not a sign-in link: ignored")
    func otherURLs() {
        let redeemer = EmailLinkRedeemer(nonces: InMemoryEmailRequestNonceStore())
        #expect(!redeemer.handle(URL(string: "https://stexx.gay/about")!, isSignedIn: false, isAgeConfirmed: true))
        #expect(redeemer.state == .idle)
    }

    @Test("Signed out on a confirmed device: verifies, then signs in")
    func success() async throws {
        let server = ScriptedServer()
        await server.queue(verifyPath, (200, [:], sessionJSON))
        let redeemer = EmailLinkRedeemer(nonces: InMemoryEmailRequestNonceStore())
        #expect(redeemer.handle(link, isSignedIn: false, isAgeConfirmed: true))
        #expect(redeemer.state == .verifying)
        let session = try #require(await redeemer.redeem(with: client(for: server)))
        #expect(session.userID == "u1")
        #expect(redeemer.state == .idle)
        #expect(await server.bodies(verifyPath).first?["token"] as? String == "tok_abcdefghijklmnopqrstuvwxyz")
    }

    @Test("Already signed in: the link is left unused")
    func alreadySignedIn() async throws {
        let server = ScriptedServer()
        let redeemer = EmailLinkRedeemer(nonces: InMemoryEmailRequestNonceStore())
        #expect(redeemer.handle(link, isSignedIn: true, isAgeConfirmed: true))
        #expect(redeemer.state == .alreadySignedIn)
        #expect(await redeemer.redeem(with: client(for: server)) == nil)
        #expect(await server.count(verifyPath) == 0)
        redeemer.dismiss()
        #expect(redeemer.state == .idle)
    }

    @Test("A new iPhone: the 18+ gate comes before the token is used; closing it forgets the token")
    func ageGateFirst() async throws {
        let server = ScriptedServer()
        await server.queue(verifyPath, (200, [:], sessionJSON))
        let redeemer = EmailLinkRedeemer(nonces: InMemoryEmailRequestNonceStore())
        redeemer.handle(link, isSignedIn: false, isAgeConfirmed: false)
        #expect(redeemer.state == .needsAgeConfirmation)
        #expect(await redeemer.redeem(with: client(for: server)) == nil)
        #expect(await server.count(verifyPath) == 0)
        redeemer.ageConfirmed()
        #expect(redeemer.state == .verifying)
        #expect(await redeemer.redeem(with: client(for: server)) != nil)

        let other = EmailLinkRedeemer(nonces: InMemoryEmailRequestNonceStore())
        other.handle(link, isSignedIn: false, isAgeConfirmed: false)
        other.dismiss()
        other.ageConfirmed()
        #expect(other.state == .idle)
    }

    @Test(
        "Failures say why: expired link, no account yet",
        arguments: [("invalid_link", EmailSignInProblem.expiredLink), ("registration_required", .noAccount)]
    )
    func failures(code: String, expected: EmailSignInProblem) async throws {
        let server = ScriptedServer()
        await server.queue(verifyPath, error(400, code))
        let redeemer = EmailLinkRedeemer(nonces: InMemoryEmailRequestNonceStore())
        redeemer.handle(link, isSignedIn: false, isAgeConfirmed: true)
        #expect(await redeemer.redeem(with: client(for: server)) == nil)
        #expect(redeemer.state == .failed(expected))
        redeemer.dismiss(followUp: .signIn)
        #expect(redeemer.state == .idle)
        #expect(redeemer.followUp == .signIn)
    }

    @Test(
        "A failure that left the link unused (offline, 503, 429, server error): the same link works again, and Try again too",
        arguments: [0, 503, 429, 500]
    )
    func transientFailureCanRetry(status: Int) async throws {
        let calls = CallLog()
        let baseURL = StubURLProtocol.register { _ in
            await calls.record("verify")
            if await calls.count("verify") <= 2 {
                switch status {
                case 0: throw URLError(.notConnectedToInternet)
                case 503: return (503, [:], Fixtures.json(["code": "email_unavailable", "message": "down"]))
                case 429: return (429, ["Retry-After": "30"], Fixtures.json(["code": "rate_limited", "message": "slow"]))
                default: return (500, [:], Fixtures.json(["code": "internal", "message": "oops"]))
                }
            }
            return (200, [:], sessionJSON)
        }
        let api = HTTPAPIClient(
            configuration: APIConfiguration(baseURL: baseURL, useMock: false),
            session: StubURLProtocol.session(),
            sessions: SessionCoordinator(store: InMemorySessionStore())
        )
        let redeemer = EmailLinkRedeemer(nonces: InMemoryEmailRequestNonceStore())
        redeemer.handle(link, isSignedIn: false, isAgeConfirmed: true)
        #expect(await redeemer.redeem(with: api) == nil)
        guard case .failed(let problem) = redeemer.state else {
            Issue.record("expected a failure, got \(redeemer.state)")
            return
        }
        #expect(!problem.isFinalForLink)
        #expect(redeemer.canRetry)

        // Tapping the same link in Mail again has another go.
        redeemer.dismiss()
        #expect(redeemer.handle(link, isSignedIn: false, isAgeConfirmed: true))
        #expect(redeemer.state == .verifying)
        #expect(await redeemer.redeem(with: api) == nil)

        // "Try again" on the sheet uses the same link.
        #expect(redeemer.canRetry)
        redeemer.retry()
        #expect(redeemer.state == .verifying)
        #expect(await redeemer.redeem(with: api) != nil)
        #expect(redeemer.state == .idle)
        #expect(!redeemer.canRetry)
        #expect(await calls.count("verify") == 3)

        // Once it signed in, the link is spent: a later delivery does nothing.
        #expect(redeemer.handle(link, isSignedIn: false, isAgeConfirmed: true))
        #expect(redeemer.state == .idle)
    }

    @Test("A used or expired link can't be retried from the sheet")
    func expiredLinkNoRetry() async throws {
        let server = ScriptedServer()
        await server.queue(verifyPath, error(400, "invalid_link"))
        let redeemer = EmailLinkRedeemer(nonces: InMemoryEmailRequestNonceStore())
        redeemer.handle(link, isSignedIn: false, isAgeConfirmed: true)
        _ = await redeemer.redeem(with: client(for: server))
        #expect(redeemer.state == .failed(.expiredLink))
        #expect(!redeemer.canRetry)
        redeemer.retry()
        #expect(redeemer.state == .failed(.expiredLink))
    }

    @Test("The same link delivered twice is used once")
    func duplicateDelivery() async throws {
        let server = ScriptedServer()
        await server.queue(verifyPath, error(400, "invalid_link"))
        let redeemer = EmailLinkRedeemer(nonces: InMemoryEmailRequestNonceStore())
        redeemer.handle(link, isSignedIn: false, isAgeConfirmed: true)
        #expect(redeemer.handle(link, isSignedIn: false, isAgeConfirmed: true)) // while in flight
        _ = await redeemer.redeem(with: client(for: server))
        redeemer.dismiss()
        #expect(redeemer.handle(link, isSignedIn: false, isAgeConfirmed: true))
        #expect(redeemer.state == .idle)
        #expect(await server.count(verifyPath) == 1)
    }
}

// MARK: - Binding emails to this app install (combined audit)

@MainActor
struct EmailRequestBindingTests {
    private let link = URL(string: "https://stexx.gay/auth/email?token=tok_abcdefghijklmnopqrstuvwxyz")!

    private func confirmLink(account: String, name: String) -> ScriptedServer.Reply {
        (409, [:], Fixtures.json(["code": "confirm_link", "message": "whose", "account": account, "displayName": name]))
    }

    @Test("Every email of one sign-in carries the same nonce, kept in the store; the code goes with it")
    func nonceTravels() async throws {
        let server = ScriptedServer()
        await server.queue(linkPath, (204, [:], Data()))
        await server.queue(linkPath, (204, [:], Data()))
        await server.queue(codePath, (200, [:], sessionJSON))
        let clock = EmailTestClock()
        let store = InMemoryEmailRequestNonceStore()
        let model = EmailSignInModel(purpose: .signIn, api: client(for: server), nonces: store, now: { clock.now })
        await model.send(to: "otter@example.com")
        clock.advance(EmailSignInModel.resendCooldown)
        await model.resend()
        let nonces = await server.bodies(linkPath).compactMap { $0["requestNonce"] as? String }
        #expect(nonces.count == 2)
        #expect(Set(nonces).count == 1)
        let nonce = try #require(nonces.first)
        #expect(nonce.count == 43) // 32 bytes, base64url without padding
        #expect(nonce.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        #expect(store.current(now: clock.now) == nonce)

        model.updateCode("12345678")
        #expect(await model.submitCode() != nil)
        #expect(await server.bodies(codePath).first?["requestNonce"] as? String == nonce)
        // Signed in: the next sign-in starts with a new nonce.
        #expect(store.current(now: clock.now) == nil)
    }

    @Test("A 429 on the code says it's the code limit, and doesn't hold up \"Send another email\"")
    func codeRateLimit() async throws {
        let server = ScriptedServer()
        await server.queue(linkPath, (204, [:], Data()))
        await server.queue(codePath, error(429, "rate_limited", headers: ["Retry-After": "600"]))
        let clock = EmailTestClock()
        let model = EmailSignInModel(purpose: .signIn, api: client(for: server), nonces: InMemoryEmailRequestNonceStore(), now: { clock.now })
        await model.send(to: "otter@example.com")
        model.updateCode("12345678")
        #expect(await model.submitCode() == nil)
        #expect(model.problem == .tooManyCodeAttempts(until: clock.now.addingTimeInterval(600)))
        #expect(model.resendWait() == EmailSignInModel.resendCooldown)
        let text = try #require(model.problem).message(now: clock.now)
        #expect(text.contains("Too many tries with codes"))
        #expect(text.contains("10:00"))
        #expect(!text.contains("asked for a few emails"))
    }

    @Test("Wire: verify sends the nonce, and confirmed only once the person said yes")
    func verifyBody() async throws {
        let server = ScriptedServer()
        await server.queue(verifyPath, (200, [:], sessionJSON))
        await server.queue(verifyPath, (200, [:], sessionJSON))
        let api = client(for: server)
        _ = try await api.verifyEmailLink(token: "t0k3n-t0k3n-t0k3n-t0k3n", requestNonce: "n0nc3-n0nc3-n0nc3-n0nc3", confirmed: false)
        _ = try await api.verifyEmailLink(token: "t0k3n-t0k3n-t0k3n-t0k3n", requestNonce: "n0nc3-n0nc3-n0nc3-n0nc3", confirmed: true)
        let bodies = await server.bodies(verifyPath)
        #expect(bodies[0].keys.sorted() == ["requestNonce", "token"])
        #expect(bodies[1]["confirmed"] as? Bool == true)
        #expect(bodies[1]["requestNonce"] as? String == "n0nc3-n0nc3-n0nc3-n0nc3")
    }

    @Test("Wire: 409 confirm_link names the account", arguments: [("existing", false), ("new", true)])
    func confirmLinkDecodes(account: String, isNew: Bool) async throws {
        let server = ScriptedServer()
        await server.queue(verifyPath, confirmLink(account: account, name: "SomeoneElse"))
        await #expect(throws: EmailSignInError.confirmationRequired(EmailLinkAccount(isNew: isNew, displayName: "SomeoneElse"))) {
            try await client(for: server).verifyEmailLink(token: "t0k3n-t0k3n-t0k3n-t0k3n", requestNonce: "n0nc3-n0nc3-n0nc3-n0nc3", confirmed: false)
        }
    }

    @Test("A link this app asked for signs in at once, with the stored nonce, which is then cleared")
    func askedHere() async throws {
        let server = ScriptedServer()
        await server.queue(verifyPath, (200, [:], sessionJSON))
        let store = InMemoryEmailRequestNonceStore(pending: "mine-mine-mine-mine-mine")
        let redeemer = EmailLinkRedeemer(nonces: store)
        redeemer.handle(link, isSignedIn: false, isAgeConfirmed: true)
        #expect(await redeemer.redeem(with: client(for: server)) != nil)
        let body = try #require(await server.bodies(verifyPath).first)
        #expect(body["requestNonce"] as? String == "mine-mine-mine-mine-mine")
        #expect(body["confirmed"] == nil)
        #expect(store.current(now: .now) == nil)
    }

    @Test("Login CSRF: someone else's link isn't used until \"Sign in as …?\" gets a yes")
    func someoneElsesLink() async throws {
        let server = ScriptedServer()
        await server.queue(verifyPath, confirmLink(account: "existing", name: "Stranger"))
        await server.queue(verifyPath, (200, [:], sessionJSON))
        let redeemer = EmailLinkRedeemer(nonces: InMemoryEmailRequestNonceStore()) // nothing asked for here
        let api = client(for: server)
        redeemer.handle(link, isSignedIn: false, isAgeConfirmed: true)
        #expect(await redeemer.redeem(with: api) == nil) // no session: nobody gets signed in
        #expect(redeemer.state == .needsConfirmation(EmailLinkAccount(isNew: false, displayName: "Stranger")))
        #expect(await redeemer.redeem(with: api) == nil) // nothing more is sent while it asks
        #expect(await server.count(verifyPath) == 1)

        redeemer.confirmAccount()
        #expect(redeemer.state == .verifying)
        let session = try #require(await redeemer.redeem(with: api))
        #expect(session.accessToken == "acc")
        let bodies = await server.bodies(verifyPath)
        // Even with no nonce pending, one is sent (a throwaway), so the server always checks.
        #expect((bodies[0]["requestNonce"] as? String)?.count == 43)
        #expect(bodies[0]["confirmed"] == nil)
        #expect(bodies[1]["confirmed"] as? Bool == true)
        #expect(bodies[1]["token"] as? String == "tok_abcdefghijklmnopqrstuvwxyz")
    }

    @Test("Cancel on \"Sign in as …?\" forgets the link; opening it again asks again")
    func cancelConfirmation() async throws {
        let server = ScriptedServer()
        await server.queue(verifyPath, confirmLink(account: "new", name: "Stranger"))
        await server.queue(verifyPath, confirmLink(account: "new", name: "Stranger"))
        let redeemer = EmailLinkRedeemer(nonces: InMemoryEmailRequestNonceStore())
        let api = client(for: server)
        redeemer.handle(link, isSignedIn: false, isAgeConfirmed: true)
        _ = await redeemer.redeem(with: api)
        #expect(redeemer.state == .needsConfirmation(EmailLinkAccount(isNew: true, displayName: "Stranger")))
        redeemer.dismiss()
        #expect(redeemer.state == .idle)
        redeemer.confirmAccount() // too late: nothing pending
        #expect(redeemer.state == .idle)

        redeemer.handle(link, isSignedIn: false, isAgeConfirmed: true)
        #expect(await redeemer.redeem(with: api) == nil)
        #expect(redeemer.state == .needsConfirmation(EmailLinkAccount(isNew: true, displayName: "Stranger")))
        #expect(await server.bodies(verifyPath).allSatisfy { $0["confirmed"] == nil })
    }

    @Test("Mock backend asks too, for a link asked for with another nonce")
    func mockAsks() async throws {
        let mock = MockAPIClient(latency: .zero)
        try await mock.requestEmailLink(.signUp(email: "x@example.com", displayName: "Stranger", requestNonce: "theirs-theirs-theirs-theirs"))
        let token = try #require(await mock.lastEmailLinkToken)
        await #expect(throws: EmailSignInError.confirmationRequired(EmailLinkAccount(isNew: true, displayName: "Stranger"))) {
            try await mock.verifyEmailLink(token: token, requestNonce: "mine-mine-mine-mine-mine", confirmed: false)
        }
        await #expect(throws: EmailSignInError.invalidCode) {
            try await mock.verifyEmailCode(email: "x@example.com", code: MockAPIClient.emailCode, requestNonce: "mine-mine-mine-mine-mine")
        }
        _ = try await mock.verifyEmailLink(token: token, requestNonce: "theirs-theirs-theirs-theirs", confirmed: false)
    }

    @Test("Nonce store: one nonce per sign-in, reused for an hour after its last email, new after that or a sign-in")
    func nonceStore() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let store = InMemoryEmailRequestNonceStore()
        #expect(store.current(now: start) == nil)
        let first = store.issue(now: start)
        #expect(store.issue(now: start.addingTimeInterval(50 * 60)) == first)
        #expect(store.current(now: start.addingTimeInterval(100 * 60)) == first) // the last email slid the hour on
        #expect(store.current(now: start.addingTimeInterval(111 * 60)) == nil)
        #expect(store.issue(now: start.addingTimeInterval(111 * 60)) != first)
        store.clear()
        #expect(store.current(now: start.addingTimeInterval(111 * 60)) == nil)
        #expect(EmailRequestNonce.random() != EmailRequestNonce.random())
    }

    @Test(
        "Only https links on the app-link host count",
        arguments: [
            ("https://stexx.gay/auth/email?token=abc", "abc"),
            ("https://STEXX.gay/auth/email/?token=abc", "abc"),
            ("http://stexx.gay/auth/email?token=abc", nil),
            ("https://evil.example/auth/email?token=abc", nil),
            ("https://stexx.gay.evil.example/auth/email?token=abc", nil),
            ("https://stexx.gay/evil/auth/email?token=abc", nil),
            ("stexx://stexx.gay/auth/email?token=abc", nil),
            ("https://stexx.gay/auth/email", nil),
            ("https://stexx.gay/auth/email?token=", nil),
        ] as [(String, String?)]
    )
    func linkHost(url: String, expected: String?) throws {
        #expect(EmailSignInLink.token(from: try #require(URL(string: url)), host: "stexx.gay") == expected)
    }
}
