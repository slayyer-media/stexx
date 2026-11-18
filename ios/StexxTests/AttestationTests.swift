import Foundation
import Testing
@testable import Stexx

/// Records calls and hands out fixed headers.
actor FakeAttestation: RequestAttesting {
    private(set) var calls: [String] = []
    private(set) var resets = 0

    func headers(method: String, path: String, body: Data?, includeDeviceToken: Bool) async -> [String: String] {
        calls.append("\(method) \(path) token=\(includeDeviceToken)")
        return ["X-Stexx-Key-Id": "key-\(resets)", "X-Stexx-Assertion": "sig"]
    }

    func resetKey() async {
        resets += 1
    }
}

struct AttestationTests {
    private func client(_ baseURL: URL, attestation: FakeAttestation) async -> HTTPAPIClient {
        let store = InMemorySessionStore(session: Session(userID: "u1", accessToken: "tok", refreshToken: "r", expiresAt: nil))
        return HTTPAPIClient(
            configuration: APIConfiguration(baseURL: baseURL, useMock: false),
            session: StubURLProtocol.session(),
            sessions: SessionCoordinator(store: store),
            attestation: attestation
        )
    }

    @Test("Client data matches the server's assertionClientData byte for byte")
    func clientDataVector() {
        let data = AttestationService.clientData(method: "post", path: "/v1/auth/register", timestamp: 1_700_000_000_000, body: Data("{}".utf8))
        #expect(String(decoding: data, as: UTF8.self)
            == "stexx-assert-v1\nPOST\n/v1/auth/register\n1700000000000\nRBNvo1WzZ4oRRq0W9-hknpT7T8If536DEMBg9hyq_4o")
    }

    @Test("Only sign-up, sign-in, messages, photo uploads and account deletion are attested")
    func protectedRoutes() {
        #expect(HTTPAPIClient.attestedRoute("POST", "auth/register") == .account)
        #expect(HTTPAPIClient.attestedRoute("POST", "auth/email/verify") == .account)
        #expect(HTTPAPIClient.attestedRoute("DELETE", "me") == .account)
        #expect(HTTPAPIClient.attestedRoute("POST", "conversations/c_1/messages") == .content)
        #expect(HTTPAPIClient.attestedRoute("POST", "me/photos") == .content)
        #expect(HTTPAPIClient.attestedRoute("GET", "conversations/c_1/messages") == nil)
        #expect(HTTPAPIClient.attestedRoute("GET", "me") == nil)
        #expect(HTTPAPIClient.attestedRoute("POST", "auth/refresh") == nil)
    }

    @Test("Protected requests carry the attestation headers; others don't")
    func headersAttached() async throws {
        let log = CallLog()
        let baseURL = StubURLProtocol.register { request in
            await log.record("\(request.url?.path() ?? "") \(request.value(forHTTPHeaderField: "X-Stexx-Key-Id") ?? "-")")
            if request.url?.path().hasSuffix("/tap") == true { return (204, [:], Data()) }
            return (403, [:], Fixtures.json(["code": "new_account_limit", "message": "New accounts can start 10 new chats a day."]))
        }
        let fake = FakeAttestation()
        let api = await client(baseURL, attestation: fake)
        try await api.sendTap(to: "p1")
        do {
            _ = try await api.send(MessageDraft(clientID: "x", text: "hi"), in: "c1")
            Issue.record("expected a 403")
        } catch let error as APIError {
            // The server's message is what the chat shows.
            #expect(error.errorDescription == "New accounts can start 10 new chats a day.")
        }
        #expect(await log.entries == ["/v1/profiles/p1/tap -", "/v1/conversations/c1/messages key-0"])
        #expect(await fake.calls == ["POST /v1/conversations/c1/messages token=false"])
    }

    @Test("A forgotten key is re-attested once and the request retried")
    func reattestOnUnknownKey() async throws {
        let baseURL = StubURLProtocol.register { request in
            if request.value(forHTTPHeaderField: "X-Stexx-Key-Id") == "key-0" {
                return (403, [:], Fixtures.error("attestation_key_unknown"))
            }
            return (200, [:], Fixtures.json(Fixtures.session("a", refresh: "r")))
        }
        let fake = FakeAttestation()
        let api = await client(baseURL, attestation: fake)
        let session = try await api.register(RegistrationRequest(displayName: "N", method: .passkey, email: nil, confirmedAdult: true))
        #expect(session.accessToken == "a")
        #expect(await fake.resets == 1)
        #expect(await fake.calls == ["POST /v1/auth/register token=true", "POST /v1/auth/register token=true"])
    }

    @Test("429 messages say roughly how long to wait")
    func friendlyRateLimit() {
        #expect(APIError.rateLimited(retryAfter: nil).errorDescription == "Slow down a little and try again in a moment.")
        #expect(APIError.rateLimited(retryAfter: 30).errorDescription == "Slow down a little and try again in a moment.")
        #expect(APIError.rateLimited(retryAfter: 600).errorDescription == "You're doing that a lot. Try again in about 10 min.")
        #expect(APIError.rateLimited(retryAfter: 5400).errorDescription == "You've reached the limit for now. Try again in about 2 h.")
    }

    @Test("The dev bypass mode sends only the bypass header")
    func devBypass() async {
        let service = AttestationService(mode: .devBypass, baseURL: URL(string: "https://example.test")!)
        let headers = await service.headers(method: "POST", path: "/v1/auth/register", body: nil, includeDeviceToken: true)
        #expect(headers == ["X-Stexx-Attestation": "dev-bypass"])
        let off = AttestationService(mode: .off, baseURL: URL(string: "https://example.test")!)
        #expect(await off.headers(method: "POST", path: "/x", body: nil, includeDeviceToken: false).isEmpty)
    }
}
