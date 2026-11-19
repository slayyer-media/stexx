import AuthenticationServices
import Foundation
import SwiftUI

// Passkey sign-up and sign-in (WebAuthn, `docs/api.md`, `ios/README.md#passkeys`).
//
//   options (server) → system passkey sheet (`PasskeyAuthenticating`) → finish (server) → Session
//
// The system part sits behind `PasskeyAuthenticating` so everything else
// (decoding, request building, payloads, error mapping) is unit tested with
// a fake. `SystemPasskeyAuthenticator` is the AuthenticationServices one;
// `SimulatedPasskeyAuthenticator` backs the mock API.

/// Server calls the passkey flow needs. `APIClient` refines it.
protocol PasskeyAPI: Sendable {
    /// `POST /auth/passkey/register/options` with the nickname (and the
    /// 18+ confirmation from the age gate).
    func passkeyRegistrationOptions(displayName: String) async throws -> PasskeyCreationOptions
    /// `POST /auth/passkey/register/finish` (attested). Creates the account.
    func finishPasskeyRegistration(_ credential: PasskeyRegistrationCredential) async throws -> Session
    /// `POST /auth/passkey/login/options`.
    func passkeyLoginOptions() async throws -> PasskeyRequestOptions
    /// `POST /auth/passkey/login/finish` (attested). 401 when the server
    /// doesn't know the passkey.
    func finishPasskeyLogin(_ credential: PasskeyAssertionCredential) async throws -> Session
}

// MARK: - Availability

/// Whether this build can use passkeys with the server it talks to.
///
/// iOS only creates or uses a passkey for a domain that lists the app in its
/// `apple-app-site-association` file (`webcredentials`), and only if the app
/// has the matching associated-domain entitlement. So a build talking to a
/// dev server on `127.0.0.1` can never use them: the button explains that
/// and email sign-in stays available.
enum PasskeyAvailability: Hashable, Sendable {
    case available(relyingPartyID: String)
    case unavailable(Reason)

    enum Reason: Hashable, Sendable {
        /// The build has no relying party (`STEXX_PASSKEY_RP_ID` empty,
        /// e.g. the Local configuration, which has no associated domain).
        case notConfigured
        /// The API is plain HTTP, `localhost`, an IP address or a `.local` name.
        case localServer
        /// The API host is not the relying party or one of its subdomains.
        case otherDomain
    }

    static let defaultRelyingPartyID = "stexx.gay"

    /// Pure: decides from the build's API base URL and relying party. The
    /// mock backend fakes the system sheet, so it is always available.
    static func resolve(baseURL: URL, relyingPartyID: String?, useMock: Bool) -> PasskeyAvailability {
        let rp = (relyingPartyID ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if useMock { return .available(relyingPartyID: rp.isEmpty ? defaultRelyingPartyID : rp) }
        guard !rp.isEmpty, !isLocalHost(rp) else { return .unavailable(.notConfigured) }
        guard baseURL.scheme?.lowercased() == "https",
              let host = baseURL.host()?.lowercased(), !host.isEmpty,
              !isLocalHost(host)
        else { return .unavailable(.localServer) }
        guard host == rp || host.hasSuffix("." + rp) else { return .unavailable(.otherDomain) }
        return .available(relyingPartyID: rp)
    }

    private static func isLocalHost(_ host: String) -> Bool {
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if bare == "localhost" || bare.hasSuffix(".localhost") || bare.hasSuffix(".local") { return true }
        if bare.contains(":") { return true } // IPv6 literal
        let parts = bare.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil } // IPv4 literal
    }

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    var relyingPartyID: String? {
        if case .available(let id) = self { return id }
        return nil
    }

    /// Shown under the disabled passkey button.
    var explanation: String? {
        switch self {
        case .available: nil
        case .unavailable(.notConfigured), .unavailable(.localServer):
            String(localized: "Passkeys only work with the Stexx server at stexx.gay. This build talks to a local server, so use email instead.")
        case .unavailable(.otherDomain):
            String(localized: "Passkeys aren't set up for this server, so use email instead.")
        }
    }
}

// MARK: - Errors

enum PasskeyError: LocalizedError, Hashable, Sendable {
    /// The user closed the system sheet. On sign-in this is also what iOS
    /// reports when there is no passkey to offer.
    case canceled
    /// This build or server can't use passkeys (see `PasskeyAvailability`).
    case unavailable
    /// The server's options are for another relying party than this build's.
    case wrongServer
    /// The server's options couldn't be read (bad base64url, empty challenge).
    case invalidOptions
    /// iOS can't make passkeys yet: no passcode, or iCloud Keychain is off.
    case deviceNotSetUp
    /// This iPhone already has a Stexx passkey the server excluded.
    case alreadyRegistered
    /// Sign-in: the server doesn't know this passkey (e.g. the account was deleted).
    case notRecognized
    /// The system sheet failed (no associated domain, an iOS error, …).
    case failed

    var errorDescription: String? {
        switch self {
        case .canceled:
            String(localized: "No passkey was used.")
        case .unavailable:
            PasskeyAvailability.unavailable(.notConfigured).explanation
        case .wrongServer, .invalidOptions:
            String(localized: "Passkeys aren't set up correctly on this server. Use email for now.")
        case .deviceNotSetUp:
            String(localized: "To use a passkey, set a passcode on this iPhone and turn on iCloud Keychain, or use email instead.")
        case .alreadyRegistered:
            String(localized: "This iPhone already has a Stexx passkey. Sign in with it instead.")
        case .notRecognized:
            String(localized: "That passkey isn't linked to a Stexx account. If you deleted your account, sign up again.")
        case .failed:
            String(localized: "Your passkey couldn't be used right now. Try again, or use email.")
        }
    }

    /// Maps an AuthenticationServices error (or anything else the system
    /// sheet throws) to a friendly case.
    static func from(authorizationError error: any Error) -> PasskeyError {
        if let passkeyError = error as? PasskeyError { return passkeyError }
        let nsError = error as NSError
        guard nsError.domain == ASAuthorizationError.errorDomain else { return .failed }
        switch ASAuthorizationError.Code(rawValue: nsError.code) {
        case .canceled: return .canceled
        case .matchedExcludedCredential: return .alreadyRegistered
        case .deviceNotConfiguredForPasskeyCreation: return .deviceNotSetUp
        default: return .failed
        }
    }
}

// MARK: - System sheet abstraction

/// What the system sheet needs to create a passkey (decoded options).
struct PasskeyRegistrationRequest: Hashable, Sendable {
    var relyingPartyID: String
    var challenge: Data
    /// Shown in the passkey list (the nickname).
    var userName: String
    var userID: Data
    var excludedCredentialIDs: [Data]
}

/// What the system sheet needs to sign in.
struct PasskeyAssertionRequest: Hashable, Sendable {
    var relyingPartyID: String
    var challenge: Data
    /// Empty: any Stexx passkey (discoverable credentials).
    var allowedCredentialIDs: [Data]
}

/// A new passkey, raw bytes from the authenticator.
struct PasskeyRegistration: Hashable, Sendable {
    var credentialID: Data
    var clientDataJSON: Data
    var attestationObject: Data
    /// `true` for this iPhone's iCloud Keychain, `false` for a security key
    /// or another device, `nil` when unknown.
    var isPlatform: Bool?
}

/// A signed sign-in challenge, raw bytes from the authenticator.
struct PasskeyAssertion: Hashable, Sendable {
    var credentialID: Data
    var clientDataJSON: Data
    var authenticatorData: Data
    var signature: Data
    var userID: Data?
    var isPlatform: Bool?
}

/// The system passkey sheet. Throws `PasskeyError` (already mapped).
protocol PasskeyAuthenticating: Sendable {
    @MainActor func createPasskey(_ request: PasskeyRegistrationRequest) async throws -> PasskeyRegistration
    @MainActor func assertPasskey(_ request: PasskeyAssertionRequest) async throws -> PasskeyAssertion
}

// MARK: - Wire conversion (pure)

enum PasskeyWire {
    /// Decodes creation options into a system request. Refuses options for
    /// another relying party than the one this build is associated with.
    static func registrationRequest(from options: PasskeyCreationOptions, relyingPartyID: String) throws -> PasskeyRegistrationRequest {
        guard options.rp.id.lowercased() == relyingPartyID.lowercased() else { throw PasskeyError.wrongServer }
        guard let challenge = Data(base64URLEncoded: options.challenge), challenge.count >= 16,
              let userID = Data(base64URLEncoded: options.user.id), (1...64).contains(userID.count),
              !options.user.name.isEmpty
        else { throw PasskeyError.invalidOptions }
        let excluded = try (options.excludeCredentials ?? []).map { descriptor in
            guard let id = Data(base64URLEncoded: descriptor.id) else { throw PasskeyError.invalidOptions }
            return id
        }
        return PasskeyRegistrationRequest(
            relyingPartyID: options.rp.id,
            challenge: challenge,
            userName: options.user.name,
            userID: userID,
            excludedCredentialIDs: excluded
        )
    }

    /// Decodes request options into a system request. A missing `rpId`
    /// means the build's own relying party (WebAuthn default).
    static func assertionRequest(from options: PasskeyRequestOptions, relyingPartyID: String) throws -> PasskeyAssertionRequest {
        let rp = options.rpId ?? relyingPartyID
        guard rp.lowercased() == relyingPartyID.lowercased() else { throw PasskeyError.wrongServer }
        guard let challenge = Data(base64URLEncoded: options.challenge), challenge.count >= 16 else {
            throw PasskeyError.invalidOptions
        }
        let allowed = try (options.allowCredentials ?? []).map { descriptor in
            guard let id = Data(base64URLEncoded: descriptor.id) else { throw PasskeyError.invalidOptions }
            return id
        }
        return PasskeyAssertionRequest(relyingPartyID: rp, challenge: challenge, allowedCredentialIDs: allowed)
    }

    /// iCloud Keychain passkeys work on this device and, through the QR
    /// code flow, from a nearby one; that's what Safari reports for them.
    static let platformTransports = ["hybrid", "internal"]

    static func registrationCredential(from registration: PasskeyRegistration, confirmedAdult: Bool) -> PasskeyRegistrationCredential {
        let id = registration.credentialID.base64URLEncodedString()
        return PasskeyRegistrationCredential(
            id: id,
            rawId: id,
            authenticatorAttachment: attachment(registration.isPlatform),
            response: .init(
                clientDataJSON: registration.clientDataJSON.base64URLEncodedString(),
                attestationObject: registration.attestationObject.base64URLEncodedString(),
                transports: registration.isPlatform == false ? nil : platformTransports
            ),
            confirmedAdult: confirmedAdult
        )
    }

    static func assertionCredential(from assertion: PasskeyAssertion) -> PasskeyAssertionCredential {
        let id = assertion.credentialID.base64URLEncodedString()
        return PasskeyAssertionCredential(
            id: id,
            rawId: id,
            authenticatorAttachment: attachment(assertion.isPlatform),
            response: .init(
                clientDataJSON: assertion.clientDataJSON.base64URLEncodedString(),
                authenticatorData: assertion.authenticatorData.base64URLEncodedString(),
                signature: assertion.signature.base64URLEncodedString(),
                userHandle: assertion.userID.flatMap { $0.isEmpty ? nil : $0.base64URLEncodedString() }
            )
        )
    }

    private static func attachment(_ isPlatform: Bool?) -> String? {
        isPlatform.map { $0 ? "platform" : "cross-platform" }
    }
}

// MARK: - Flow

/// Sign up or sign in with a passkey: options → system sheet → finish.
/// Throws `PasskeyError` for anything passkey-specific and passes server
/// errors (`APIError`, with the server's message) through.
@MainActor
struct PasskeyFlow {
    let api: any PasskeyAPI
    let authenticator: any PasskeyAuthenticating
    let availability: PasskeyAvailability

    /// Creates the account. The caller has already passed the 18+ gate.
    func signUp(displayName: String) async throws -> Session {
        guard let rp = availability.relyingPartyID else { throw PasskeyError.unavailable }
        let options = try await api.passkeyRegistrationOptions(displayName: displayName)
        let request = try PasskeyWire.registrationRequest(from: options, relyingPartyID: rp)
        let registration: PasskeyRegistration
        do {
            registration = try await authenticator.createPasskey(request)
        } catch {
            throw PasskeyError.from(authorizationError: error)
        }
        return try await api.finishPasskeyRegistration(
            PasskeyWire.registrationCredential(from: registration, confirmedAdult: true)
        )
    }

    func signIn() async throws -> Session {
        guard let rp = availability.relyingPartyID else { throw PasskeyError.unavailable }
        let options = try await api.passkeyLoginOptions()
        let request = try PasskeyWire.assertionRequest(from: options, relyingPartyID: rp)
        let assertion: PasskeyAssertion
        do {
            assertion = try await authenticator.assertPasskey(request)
        } catch {
            throw PasskeyError.from(authorizationError: error)
        }
        do {
            return try await api.finishPasskeyLogin(PasskeyWire.assertionCredential(from: assertion))
        } catch APIError.unauthorized {
            // 401 `invalid_credential`: unknown passkey, bad signature or an
            // expired challenge. Not a session problem, so not "sign in again".
            throw PasskeyError.notRecognized
        }
    }
}

// MARK: - Environment

/// What the onboarding screens need: whether passkeys work in this build and
/// the system sheet (or the mock's simulated one).
struct PasskeySupport: Sendable {
    var availability: PasskeyAvailability
    var authenticator: any PasskeyAuthenticating

    /// The mock backend: no system sheet, always succeeds.
    static let simulated = PasskeySupport(
        availability: .available(relyingPartyID: PasskeyAvailability.defaultRelyingPartyID),
        authenticator: SimulatedPasskeyAuthenticator()
    )

    static func live(_ configuration: APIConfiguration) -> PasskeySupport {
        if configuration.useMock { return .simulated }
        return PasskeySupport(availability: configuration.passkeyAvailability, authenticator: SystemPasskeyAuthenticator())
    }
}

private struct PasskeySupportKey: EnvironmentKey {
    static let defaultValue = PasskeySupport.simulated
}

extension EnvironmentValues {
    var passkeys: PasskeySupport {
        get { self[PasskeySupportKey.self] }
        set { self[PasskeySupportKey.self] = newValue }
    }
}

/// Mock backend: returns well-formed fake bytes without any system UI, so
/// the Debug build walks the whole flow (and `MockAPIClient` checks it).
struct SimulatedPasskeyAuthenticator: PasskeyAuthenticating {
    @MainActor func createPasskey(_ request: PasskeyRegistrationRequest) async throws -> PasskeyRegistration {
        PasskeyRegistration(
            credentialID: Self.randomBytes(16),
            clientDataJSON: Self.clientData(type: "webauthn.create", request.challenge, rp: request.relyingPartyID),
            attestationObject: Data([0xA0]), // CBOR empty map
            isPlatform: true
        )
    }

    @MainActor func assertPasskey(_ request: PasskeyAssertionRequest) async throws -> PasskeyAssertion {
        PasskeyAssertion(
            credentialID: Self.randomBytes(16),
            clientDataJSON: Self.clientData(type: "webauthn.get", request.challenge, rp: request.relyingPartyID),
            authenticatorData: Self.randomBytes(37),
            signature: Self.randomBytes(64),
            userID: Self.randomBytes(32),
            isPlatform: true
        )
    }

    private static func randomBytes(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: .min ... .max) })
    }

    private static func clientData(type: String, _ challenge: Data, rp: String) -> Data {
        let json = #"{"type":"\#(type)","challenge":"\#(challenge.base64URLEncodedString())","origin":"https://\#(rp)"}"#
        return Data(json.utf8)
    }
}
