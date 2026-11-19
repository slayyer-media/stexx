import AuthenticationServices
import Foundation
import Testing
@testable import Stexx

/// Real SimpleWebAuthn output (server `generateRegistrationOptions` /
/// `generateAuthenticationOptions` with fixed bytes): challenge = 32 × 0x09,
/// user.id = 32 × 0x07.
private enum PasskeyFixtures {
    static let challenge = Data(repeating: 9, count: 32)
    static let userID = Data(repeating: 7, count: 32)

    static let creationJSON = """
    {"challenge":"CQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQk","rp":{"name":"Stexx","id":"stexx.gay"},\
    "user":{"id":"BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc","name":"QuantumOtter","displayName":""},\
    "pubKeyCredParams":[{"alg":-8,"type":"public-key"},{"alg":-7,"type":"public-key"},{"alg":-257,"type":"public-key"}],\
    "timeout":60000,"attestation":"none","excludeCredentials":[],\
    "authenticatorSelection":{"residentKey":"required","userVerification":"required","requireResidentKey":true},\
    "extensions":{"credProps":true},"hints":[]}
    """

    static let requestJSON = """
    {"rpId":"stexx.gay","challenge":"CQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQk","timeout":60000,"userVerification":"required"}
    """

    static func creationOptions() throws -> PasskeyCreationOptions {
        try JSONDecoder.stexx().decode(PasskeyCreationOptions.self, from: Data(creationJSON.utf8))
    }

    static func requestOptions() throws -> PasskeyRequestOptions {
        try JSONDecoder.stexx().decode(PasskeyRequestOptions.self, from: Data(requestJSON.utf8))
    }

    static let registration = PasskeyRegistration(
        credentialID: Data([0xFB, 0xFF, 0x01, 0x02]),
        clientDataJSON: Data(#"{"type":"webauthn.create"}"#.utf8),
        attestationObject: Data([0xA3, 0x63, 0x66, 0x6D, 0x74]),
        isPlatform: true
    )

    static let assertion = PasskeyAssertion(
        credentialID: Data([0xFB, 0xFF, 0x01, 0x02]),
        clientDataJSON: Data(#"{"type":"webauthn.get"}"#.utf8),
        authenticatorData: Data(repeating: 0xAB, count: 37),
        signature: Data([0x30, 0x44, 0xFE]),
        userID: userID,
        isPlatform: true
    )

    static func json(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder.stexx().encode(value)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

// MARK: - base64url

struct Base64URLTests {
    @Test("Encodes without padding using - and _")
    func encode() {
        #expect(Data([0xFB, 0xFF]).base64URLEncodedString() == "-_8")
        #expect(Data([0xFB, 0xFF, 0x01, 0x02]).base64URLEncodedString() == "-_8BAg")
        #expect(Data().base64URLEncodedString() == "")
        #expect(PasskeyFixtures.challenge.base64URLEncodedString() == "CQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQk")
    }

    @Test("Decodes every length, with or without padding, and round-trips")
    func decode() throws {
        for count in 1...40 {
            let bytes = Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 251) })
            let encoded = bytes.base64URLEncodedString()
            #expect(!encoded.contains("="))
            #expect(Data(base64URLEncoded: encoded) == bytes)
            let padded = encoded + String(repeating: "=", count: (4 - encoded.count % 4) % 4)
            #expect(Data(base64URLEncoded: padded) == bytes)
        }
    }

    @Test("Rejects standard base64 characters, whitespace, bad lengths and padding")
    func rejects() {
        for bad in ["", "=", "+_8", "-/8", "-_8 ", "a", "abcde", "-_8==", "-_8===", "ab=c", "é"] {
            #expect(Data(base64URLEncoded: bad) == nil, "\(bad)")
        }
    }
}

// MARK: - Options → system requests

struct PasskeyRequestBuildingTests {
    @Test("Creation options from the server decode into a registration request")
    func registrationRequest() throws {
        let options = try PasskeyFixtures.creationOptions()
        #expect(options.rp.id == "stexx.gay")
        #expect(options.authenticatorSelection?.userVerification == "required")
        let request = try PasskeyWire.registrationRequest(from: options, relyingPartyID: "stexx.gay")
        #expect(request.relyingPartyID == "stexx.gay")
        #expect(request.challenge == PasskeyFixtures.challenge)
        #expect(request.userID == PasskeyFixtures.userID)
        #expect(request.userName == "QuantumOtter")
        #expect(request.excludedCredentialIDs.isEmpty)
    }

    @Test("Excluded credentials are decoded")
    func excluded() throws {
        var options = try PasskeyFixtures.creationOptions()
        options.excludeCredentials = [PasskeyCredentialDescriptor(id: "-_8BAg", type: "public-key", transports: ["internal"])]
        let request = try PasskeyWire.registrationRequest(from: options, relyingPartyID: "stexx.gay")
        #expect(request.excludedCredentialIDs == [Data([0xFB, 0xFF, 0x01, 0x02])])
    }

    @Test("Options for another relying party are refused before any sheet")
    func wrongRelyingParty() throws {
        let options = try PasskeyFixtures.creationOptions()
        #expect(throws: PasskeyError.wrongServer) {
            try PasskeyWire.registrationRequest(from: options, relyingPartyID: "evil.example")
        }
        var request = try PasskeyFixtures.requestOptions()
        request.rpId = "localhost"
        #expect(throws: PasskeyError.wrongServer) {
            try PasskeyWire.assertionRequest(from: request, relyingPartyID: "stexx.gay")
        }
    }

    @Test("Malformed options are refused", arguments: [
        "challenge", "short challenge", "user id", "empty name", "excluded id",
    ])
    func malformed(field: String) throws {
        var options = try PasskeyFixtures.creationOptions()
        switch field {
        case "challenge": options.challenge = "not+base64url"
        case "short challenge": options.challenge = Data(repeating: 1, count: 8).base64URLEncodedString()
        case "user id": options.user.id = ""
        case "empty name": options.user.name = ""
        default: options.excludeCredentials = [PasskeyCredentialDescriptor(id: "a/b", type: "public-key")]
        }
        #expect(throws: PasskeyError.invalidOptions) {
            try PasskeyWire.registrationRequest(from: options, relyingPartyID: "stexx.gay")
        }
    }

    @Test("Request options decode into an assertion request; a missing rpId means ours")
    func assertionRequest() throws {
        var options = try PasskeyFixtures.requestOptions()
        #expect(options.allowCredentials == nil)
        let request = try PasskeyWire.assertionRequest(from: options, relyingPartyID: "stexx.gay")
        #expect(request == PasskeyAssertionRequest(relyingPartyID: "stexx.gay", challenge: PasskeyFixtures.challenge, allowedCredentialIDs: []))

        options.rpId = nil
        options.allowCredentials = [PasskeyCredentialDescriptor(id: "-_8BAg", type: "public-key")]
        let fallback = try PasskeyWire.assertionRequest(from: options, relyingPartyID: "stexx.gay")
        #expect(fallback.relyingPartyID == "stexx.gay")
        #expect(fallback.allowedCredentialIDs == [Data([0xFB, 0xFF, 0x01, 0x02])])

        options.challenge = "!!"
        #expect(throws: PasskeyError.invalidOptions) {
            try PasskeyWire.assertionRequest(from: options, relyingPartyID: "stexx.gay")
        }
    }
}

// MARK: - Finish payloads

struct PasskeyPayloadTests {
    @Test("Registration finish body matches the server's RegistrationResponseJSON schema")
    func registrationPayload() throws {
        let credential = PasskeyWire.registrationCredential(from: PasskeyFixtures.registration, confirmedAdult: true)
        let json = try PasskeyFixtures.json(credential)
        #expect(Set(json.keys) == ["id", "rawId", "type", "authenticatorAttachment", "clientExtensionResults", "response", "confirmedAdult"])
        #expect(json["id"] as? String == "-_8BAg")
        #expect(json["rawId"] as? String == "-_8BAg")
        #expect(json["type"] as? String == "public-key")
        #expect(json["authenticatorAttachment"] as? String == "platform")
        #expect((json["clientExtensionResults"] as? [String: Any])?.isEmpty == true)
        #expect(json["confirmedAdult"] as? Bool == true)
        let response = try #require(json["response"] as? [String: Any])
        #expect(Set(response.keys) == ["clientDataJSON", "attestationObject", "transports"])
        #expect(response["attestationObject"] as? String == "o2NmbXQ")
        #expect(response["transports"] as? [String] == ["hybrid", "internal"])
        let clientData = try #require(response["clientDataJSON"] as? String)
        #expect(Data(base64URLEncoded: clientData) == PasskeyFixtures.registration.clientDataJSON)
        // base64url only: the server rejects anything else.
        for value in [json["id"], response["clientDataJSON"], response["attestationObject"]] {
            let string = try #require(value as? String)
            #expect(string.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        }
    }

    @Test("A security key or unknown attachment sends no platform transports")
    func crossPlatform() throws {
        var registration = PasskeyFixtures.registration
        registration.isPlatform = false
        let json = try PasskeyFixtures.json(PasskeyWire.registrationCredential(from: registration, confirmedAdult: true))
        #expect(json["authenticatorAttachment"] as? String == "cross-platform")
        #expect((json["response"] as? [String: Any])?["transports"] == nil)
        registration.isPlatform = nil
        let unknown = try PasskeyFixtures.json(PasskeyWire.registrationCredential(from: registration, confirmedAdult: true))
        #expect(unknown["authenticatorAttachment"] == nil)
    }

    @Test("Login finish body matches AuthenticationResponseJSON, userHandle base64url")
    func assertionPayload() throws {
        let json = try PasskeyFixtures.json(PasskeyWire.assertionCredential(from: PasskeyFixtures.assertion))
        #expect(Set(json.keys) == ["id", "rawId", "type", "authenticatorAttachment", "clientExtensionResults", "response"])
        #expect(json["id"] as? String == "-_8BAg")
        let response = try #require(json["response"] as? [String: Any])
        #expect(Set(response.keys) == ["clientDataJSON", "authenticatorData", "signature", "userHandle"])
        #expect(response["signature"] as? String == "MET-")
        #expect(response["userHandle"] as? String == "BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc")
        #expect(Data(base64URLEncoded: try #require(response["authenticatorData"] as? String))?.count == 37)

        var noHandle = PasskeyFixtures.assertion
        noHandle.userID = Data()
        let omitted = try PasskeyFixtures.json(PasskeyWire.assertionCredential(from: noHandle))
        #expect((omitted["response"] as? [String: Any])?["userHandle"] == nil)
    }
}

// MARK: - Errors

struct PasskeyErrorTests {
    private func authorizationError(_ code: ASAuthorizationError.Code) -> NSError {
        NSError(domain: ASAuthorizationError.errorDomain, code: code.rawValue)
    }

    @Test("System sheet errors map to friendly cases")
    func mapping() {
        #expect(PasskeyError.from(authorizationError: authorizationError(.canceled)) == .canceled)
        #expect(PasskeyError.from(authorizationError: ASAuthorizationError(.canceled)) == .canceled)
        #expect(PasskeyError.from(authorizationError: authorizationError(.matchedExcludedCredential)) == .alreadyRegistered)
        #expect(PasskeyError.from(authorizationError: authorizationError(.deviceNotConfiguredForPasskeyCreation)) == .deviceNotSetUp)
        for code: ASAuthorizationError.Code in [.failed, .unknown, .invalidResponse, .notHandled, .notInteractive] {
            #expect(PasskeyError.from(authorizationError: authorizationError(code)) == .failed)
        }
        #expect(PasskeyError.from(authorizationError: URLError(.notConnectedToInternet)) == .failed)
        #expect(PasskeyError.from(authorizationError: PasskeyError.notRecognized) == .notRecognized)
    }

    @Test("Every error a person can see has a message")
    func messages() {
        let all: [PasskeyError] = [.canceled, .unavailable, .wrongServer, .invalidOptions, .deviceNotSetUp, .alreadyRegistered, .notRecognized, .failed]
        for error in all {
            #expect(error.errorDescription?.isEmpty == false, "\(error)")
        }
    }
}

// MARK: - Degrade logic

struct PasskeyAvailabilityTests {
    private func resolve(_ url: String, rp: String? = "stexx.gay", mock: Bool = false) -> PasskeyAvailability {
        PasskeyAvailability.resolve(baseURL: URL(string: url)!, relyingPartyID: rp, useMock: mock)
    }

    @Test("The production API under the relying party can use passkeys")
    func production() {
        #expect(resolve("https://api.stexx.gay") == .available(relyingPartyID: "stexx.gay"))
        #expect(resolve("https://stexx.gay") == .available(relyingPartyID: "stexx.gay"))
        #expect(resolve("https://API.Stexx.Gay/", rp: " Stexx.gay ") == .available(relyingPartyID: "stexx.gay"))
        #expect(resolve("https://staging.api.stexx.gay") == .available(relyingPartyID: "stexx.gay"))
    }

    @Test("Local servers degrade: HTTP, localhost, IP literals, .local")
    func local() {
        for url in [
            "http://127.0.0.1:8787", "http://localhost:8787", "https://localhost", "https://127.0.0.1",
            "https://[::1]:8787", "https://192.168.1.20", "https://my-mac.local", "http://api.stexx.gay",
        ] {
            #expect(resolve(url) == .unavailable(.localServer), "\(url)")
        }
    }

    @Test("No relying party in the build (Local configuration) degrades")
    func notConfigured() {
        #expect(resolve("http://127.0.0.1:8787", rp: "") == .unavailable(.notConfigured))
        #expect(resolve("https://api.stexx.gay", rp: nil) == .unavailable(.notConfigured))
        #expect(resolve("https://api.stexx.gay", rp: "localhost") == .unavailable(.notConfigured))
    }

    @Test("A server outside the relying party degrades (no suffix tricks)")
    func otherDomain() {
        #expect(resolve("https://api.example.com") == .unavailable(.otherDomain))
        #expect(resolve("https://notstexx.gay") == .unavailable(.otherDomain))
        #expect(resolve("https://stexx.gay.evil.example") == .unavailable(.otherDomain))
    }

    @Test("The mock backend is always available (simulated sheet)")
    func mock() {
        #expect(resolve("http://127.0.0.1:8787", rp: "", mock: true) == .available(relyingPartyID: "stexx.gay"))
        #expect(resolve("https://api.stexx.gay", mock: true) == .available(relyingPartyID: "stexx.gay"))
    }

    @Test("Only unavailable states carry an explanation")
    func explanation() {
        #expect(PasskeyAvailability.available(relyingPartyID: "stexx.gay").explanation == nil)
        #expect(PasskeyAvailability.unavailable(.localServer).explanation?.contains("email") == true)
        #expect(PasskeyAvailability.unavailable(.otherDomain).explanation?.contains("email") == true)
    }

    @Test("APIConfiguration reads the relying party and resolves availability")
    func configuration() {
        let local = APIConfiguration(baseURL: URL(string: "http://127.0.0.1:8787")!, useMock: false, passkeyRelyingPartyID: "")
        #expect(local.passkeyAvailability == .unavailable(.notConfigured))
        #expect(PasskeySupport.live(local).availability == .unavailable(.notConfigured))
        let release = APIConfiguration(baseURL: URL(string: "https://api.stexx.gay")!, useMock: false, passkeyRelyingPartyID: "stexx.gay")
        #expect(release.passkeyAvailability == .available(relyingPartyID: "stexx.gay"))
        let mock = APIConfiguration(baseURL: URL(string: "https://api.stexx.gay")!, useMock: true)
        #expect(PasskeySupport.live(mock).availability == .available(relyingPartyID: "stexx.gay"))
    }
}

// MARK: - Flow

/// Records calls; answers with the fixtures.
private actor FakePasskeyAPI: PasskeyAPI {
    var calls: [String] = []
    var registered: PasskeyRegistrationCredential?
    var asserted: PasskeyAssertionCredential?
    var registrationOptions: PasskeyCreationOptions
    var finishError: (any Error)?

    init(registrationOptions: PasskeyCreationOptions, finishError: (any Error)? = nil) {
        self.registrationOptions = registrationOptions
        self.finishError = finishError
    }

    func passkeyRegistrationOptions(displayName: String) async throws -> PasskeyCreationOptions {
        calls.append("register/options \(displayName)")
        return registrationOptions
    }

    func finishPasskeyRegistration(_ credential: PasskeyRegistrationCredential) async throws -> Session {
        calls.append("register/finish")
        registered = credential
        if let finishError { throw finishError }
        return MockData.session
    }

    func passkeyLoginOptions() async throws -> PasskeyRequestOptions {
        calls.append("login/options")
        return try PasskeyFixtures.requestOptions()
    }

    func finishPasskeyLogin(_ credential: PasskeyAssertionCredential) async throws -> Session {
        calls.append("login/finish")
        asserted = credential
        if let finishError { throw finishError }
        return MockData.session
    }
}

/// Stands in for the system sheet.
@MainActor
private final class FakeAuthenticator: PasskeyAuthenticating {
    var error: (any Error)?
    private(set) var registrationRequests: [PasskeyRegistrationRequest] = []
    private(set) var assertionRequests: [PasskeyAssertionRequest] = []

    init(error: (any Error)? = nil) { self.error = error }

    func createPasskey(_ request: PasskeyRegistrationRequest) async throws -> PasskeyRegistration {
        registrationRequests.append(request)
        if let error { throw error }
        return PasskeyFixtures.registration
    }

    func assertPasskey(_ request: PasskeyAssertionRequest) async throws -> PasskeyAssertion {
        assertionRequests.append(request)
        if let error { throw error }
        return PasskeyFixtures.assertion
    }
}

@MainActor
struct PasskeyFlowTests {
    private let available = PasskeyAvailability.available(relyingPartyID: "stexx.gay")

    @Test("Sign-up: options with the nickname → sheet with the decoded request → finish with the attestation")
    func signUp() async throws {
        let api = FakePasskeyAPI(registrationOptions: try PasskeyFixtures.creationOptions())
        let sheet = FakeAuthenticator()
        let session = try await PasskeyFlow(api: api, authenticator: sheet, availability: available).signUp(displayName: "QuantumOtter")
        #expect(session == MockData.session)
        #expect(await api.calls == ["register/options QuantumOtter", "register/finish"])
        #expect(sheet.registrationRequests.first?.challenge == PasskeyFixtures.challenge)
        let sent = try #require(await api.registered)
        #expect(sent == PasskeyWire.registrationCredential(from: PasskeyFixtures.registration, confirmedAdult: true))
    }

    @Test("Sign-in: options → sheet → finish with the assertion")
    func signIn() async throws {
        let api = FakePasskeyAPI(registrationOptions: try PasskeyFixtures.creationOptions())
        let sheet = FakeAuthenticator()
        let session = try await PasskeyFlow(api: api, authenticator: sheet, availability: available).signIn()
        #expect(session == MockData.session)
        #expect(await api.calls == ["login/options", "login/finish"])
        #expect(sheet.assertionRequests == [PasskeyAssertionRequest(relyingPartyID: "stexx.gay", challenge: PasskeyFixtures.challenge, allowedCredentialIDs: [])])
        #expect(await api.asserted == PasskeyWire.assertionCredential(from: PasskeyFixtures.assertion))
    }

    @Test("Closing the sheet cancels without calling finish", arguments: [true, false])
    func canceled(signUp: Bool) async throws {
        let api = FakePasskeyAPI(registrationOptions: try PasskeyFixtures.creationOptions())
        let sheet = FakeAuthenticator(error: NSError(domain: ASAuthorizationError.errorDomain, code: ASAuthorizationError.Code.canceled.rawValue))
        let flow = PasskeyFlow(api: api, authenticator: sheet, availability: available)
        await #expect(throws: PasskeyError.canceled) {
            if signUp { _ = try await flow.signUp(displayName: "Q") } else { _ = try await flow.signIn() }
        }
        #expect(await api.calls.count == 1)
    }

    @Test("A sheet failure becomes a friendly error")
    func sheetFailure() async throws {
        let api = FakePasskeyAPI(registrationOptions: try PasskeyFixtures.creationOptions())
        let sheet = FakeAuthenticator(error: NSError(domain: ASAuthorizationError.errorDomain, code: ASAuthorizationError.Code.failed.rawValue))
        await #expect(throws: PasskeyError.failed) {
            _ = try await PasskeyFlow(api: api, authenticator: sheet, availability: available).signUp(displayName: "Q")
        }
    }

    @Test("Sign-in finish 401 means an unknown passkey, not an expired session")
    func notRecognized() async throws {
        let api = FakePasskeyAPI(registrationOptions: try PasskeyFixtures.creationOptions(), finishError: APIError.unauthorized)
        await #expect(throws: PasskeyError.notRecognized) {
            _ = try await PasskeyFlow(api: api, authenticator: FakeAuthenticator(), availability: available).signIn()
        }
    }

    @Test("Server errors pass through with the server's message")
    func serverError() async throws {
        let expired = APIError.server(status: 400, message: "This sign-up expired. Please start again.")
        let api = FakePasskeyAPI(registrationOptions: try PasskeyFixtures.creationOptions(), finishError: expired)
        do {
            _ = try await PasskeyFlow(api: api, authenticator: FakeAuthenticator(), availability: available).signUp(displayName: "Q")
            Issue.record("expected an error")
        } catch let error as APIError {
            #expect(error == expired)
            #expect(error.localizedDescription == "This sign-up expired. Please start again.")
        }
        let limited = FakePasskeyAPI(registrationOptions: try PasskeyFixtures.creationOptions(), finishError: APIError.rateLimited(retryAfter: 120))
        await #expect(throws: APIError.rateLimited(retryAfter: 120)) {
            _ = try await PasskeyFlow(api: limited, authenticator: FakeAuthenticator(), availability: available).signIn()
        }
    }

    @Test("Unavailable builds never call the server or the sheet")
    func unavailable() async throws {
        let api = FakePasskeyAPI(registrationOptions: try PasskeyFixtures.creationOptions())
        let sheet = FakeAuthenticator()
        let flow = PasskeyFlow(api: api, authenticator: sheet, availability: .unavailable(.localServer))
        await #expect(throws: PasskeyError.unavailable) { _ = try await flow.signUp(displayName: "Q") }
        await #expect(throws: PasskeyError.unavailable) { _ = try await flow.signIn() }
        #expect(await api.calls.isEmpty)
        #expect(sheet.registrationRequests.isEmpty && sheet.assertionRequests.isEmpty)
    }

    @Test("Options for another relying party never reach the sheet")
    func wrongServer() async throws {
        var options = try PasskeyFixtures.creationOptions()
        options.rp.id = "localhost"
        let api = FakePasskeyAPI(registrationOptions: options)
        let sheet = FakeAuthenticator()
        await #expect(throws: PasskeyError.wrongServer) {
            _ = try await PasskeyFlow(api: api, authenticator: sheet, availability: available).signUp(displayName: "Q")
        }
        #expect(sheet.registrationRequests.isEmpty)
        #expect(await api.calls == ["register/options Q"])
    }

    @Test("Mock backend: the simulated sheet signs up (nickname kept) and signs in")
    func mockBackend() async throws {
        let mock = MockAPIClient(latency: .zero)
        let support = PasskeySupport.simulated
        let flow = PasskeyFlow(api: mock, authenticator: support.authenticator, availability: support.availability)
        let session = try await flow.signUp(displayName: "PasskeyOtter")
        #expect(session == MockData.session)
        #expect(try await mock.fetchMe().displayName == "PasskeyOtter")
        #expect(try await flow.signIn() == MockData.session)
    }

    @Test("Mock backend refuses a replayed or foreign challenge")
    func mockReplay() async throws {
        let mock = MockAPIClient(latency: .zero)
        let options = try await mock.passkeyRegistrationOptions(displayName: "Q")
        let request = try PasskeyWire.registrationRequest(from: options, relyingPartyID: "stexx.gay")
        let created = try await SimulatedPasskeyAuthenticator().createPasskey(request)
        let credential = PasskeyWire.registrationCredential(from: created, confirmedAdult: true)
        _ = try await mock.finishPasskeyRegistration(credential)
        await #expect(throws: APIError.self) { _ = try await mock.finishPasskeyRegistration(credential) }

        let login = try await mock.passkeyLoginOptions()
        let assertion = try await SimulatedPasskeyAuthenticator().assertPasskey(
            PasskeyWire.assertionRequest(from: login, relyingPartyID: "stexx.gay")
        )
        let signed = PasskeyWire.assertionCredential(from: assertion)
        _ = try await mock.finishPasskeyLogin(signed)
        await #expect(throws: APIError.unauthorized) { _ = try await mock.finishPasskeyLogin(signed) }
    }
}

// MARK: - HTTP

@MainActor
struct PasskeyHTTPTests {
    @Test("Endpoints, bodies and attestation: options unauthenticated, finish attested")
    func endpoints() async throws {
        let log = CallLog()
        let creation = PasskeyFixtures.creationJSON
        let requestJSON = PasskeyFixtures.requestJSON
        let baseURL = StubURLProtocol.register { request in
            let path = request.url?.path() ?? ""
            let body = request.httpBodyStream.map { stream -> Data in
                stream.open()
                defer { stream.close() }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let read = stream.read(&buffer, maxLength: buffer.count)
                    if read <= 0 { break }
                    data.append(buffer, count: read)
                }
                return data
            } ?? request.httpBody ?? Data()
            let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            await log.record("\(request.httpMethod ?? "") \(path) auth=\(request.value(forHTTPHeaderField: "Authorization") ?? "-") attest=\(request.value(forHTTPHeaderField: "X-Stexx-Attestation") ?? "-")")
            switch path {
            case "/v1/auth/passkey/register/options":
                #expect(json?["displayName"] as? String == "QuantumOtter")
                #expect(json?["confirmedAdult"] as? Bool == true)
                return (200, [:], Data(creation.utf8))
            case "/v1/auth/passkey/register/finish":
                #expect(json?["rawId"] as? String == "-_8BAg")
                #expect(json?["confirmedAdult"] as? Bool == true)
                return (200, [:], Fixtures.json(Fixtures.session("a1", refresh: "r1")))
            case "/v1/auth/passkey/login/options":
                #expect(json?.isEmpty == true)
                return (200, [:], Data(requestJSON.utf8))
            case "/v1/auth/passkey/login/finish":
                #expect((json?["response"] as? [String: Any])?["userHandle"] as? String != nil)
                return (401, [:], Fixtures.error("invalid_credential"))
            default:
                return (404, [:], Fixtures.error("not_found"))
            }
        }
        let configuration = APIConfiguration(baseURL: baseURL, useMock: false, passkeyRelyingPartyID: "stexx.gay")
        let client = HTTPAPIClient(
            configuration: configuration,
            session: StubURLProtocol.session(),
            sessions: SessionCoordinator(store: InMemorySessionStore(), hooks: APIClientHooks()),
            attestation: AttestationService(mode: .devBypass, baseURL: baseURL)
        )
        // The stub host isn't under stexx.gay, so drive the flow with the
        // relying party the options name.
        let flow = PasskeyFlow(api: client, authenticator: FakeAuthenticator(), availability: .available(relyingPartyID: "stexx.gay"))
        let session = try await flow.signUp(displayName: "QuantumOtter")
        #expect(session.accessToken == "a1")
        await #expect(throws: PasskeyError.notRecognized) { _ = try await flow.signIn() }

        let entries = await log.entries
        #expect(entries.count == 4)
        #expect(entries[0].hasPrefix("POST /v1/auth/passkey/register/options auth=- attest=-"))
        #expect(entries[1].hasPrefix("POST /v1/auth/passkey/register/finish auth=- attest=dev-bypass"))
        #expect(entries[2].hasPrefix("POST /v1/auth/passkey/login/options auth=- attest=-"))
        #expect(entries[3].hasPrefix("POST /v1/auth/passkey/login/finish auth=- attest=dev-bypass"))
    }
}
