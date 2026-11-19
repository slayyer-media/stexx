import Foundation

// Passkey (WebAuthn) wire models for `/auth/passkey/*` (`docs/api.md`).
// The server uses SimpleWebAuthn, which speaks the WebAuthn JSON forms
// (`PublicKeyCredentialCreationOptionsJSON`, `RegistrationResponseJSON`, …):
// every binary field is base64url without padding.

/// `POST /auth/passkey/register/options` → creation options.
struct PasskeyCreationOptions: Codable, Hashable, Sendable {
    struct RelyingParty: Codable, Hashable, Sendable {
        var id: String
        var name: String?
    }

    struct User: Codable, Hashable, Sendable {
        /// base64url: the opaque WebAuthn user handle (never the Stexx user ID).
        var id: String
        var name: String
        var displayName: String?
    }

    struct AuthenticatorSelection: Codable, Hashable, Sendable {
        var residentKey: String?
        var userVerification: String?
    }

    /// base64url, single use, 5 minutes.
    var challenge: String
    var rp: RelyingParty
    var user: User
    var timeout: Double?
    var attestation: String?
    var excludeCredentials: [PasskeyCredentialDescriptor]?
    var authenticatorSelection: AuthenticatorSelection?
}

/// `POST /auth/passkey/login/options` → request options. Discoverable
/// credentials: `allowCredentials` is empty, so the passkey picks the account.
struct PasskeyRequestOptions: Codable, Hashable, Sendable {
    var challenge: String
    /// Optional in WebAuthn; the server always sends it.
    var rpId: String?
    var timeout: Double?
    var userVerification: String?
    var allowCredentials: [PasskeyCredentialDescriptor]?
}

struct PasskeyCredentialDescriptor: Codable, Hashable, Sendable {
    /// base64url credential ID.
    var id: String
    var type: String
    var transports: [String]?
}

/// `POST /auth/passkey/register/finish` body (`RegistrationResponseJSON`
/// plus `confirmedAdult`).
struct PasskeyRegistrationCredential: Codable, Hashable, Sendable {
    struct Response: Codable, Hashable, Sendable {
        var clientDataJSON: String
        var attestationObject: String
        var transports: [String]?
    }

    var id: String
    var rawId: String
    var type = "public-key"
    var authenticatorAttachment: String?
    /// Always `{}`: the app asks for no extensions.
    var clientExtensionResults: [String: String] = [:]
    var response: Response
    /// The user passed the 18+ gate (also sent with the options).
    var confirmedAdult: Bool
}

/// `POST /auth/passkey/login/finish` body (`AuthenticationResponseJSON`).
struct PasskeyAssertionCredential: Codable, Hashable, Sendable {
    struct Response: Codable, Hashable, Sendable {
        var clientDataJSON: String
        var authenticatorData: String
        var signature: String
        var userHandle: String?
    }

    var id: String
    var rawId: String
    var type = "public-key"
    var authenticatorAttachment: String?
    var clientExtensionResults: [String: String] = [:]
    var response: Response
}

// MARK: - base64url

extension Data {
    /// RFC 4648 §5 base64url, without padding (what WebAuthn JSON uses).
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decodes base64url, with or without padding. `nil` for anything else
    /// (standard `+`/`/`, whitespace, an impossible length, empty input).
    init?(base64URLEncoded string: String) {
        guard !string.isEmpty else { return nil }
        var body = Substring(string)
        while body.hasSuffix("=") { body.removeLast() }
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        guard !body.isEmpty, body.allSatisfy(allowed.contains), body.count % 4 != 1 else { return nil }
        // Padding, if present, must be exactly what the length needs.
        let padding = (4 - body.count % 4) % 4
        guard string.count == body.count || string.count == body.count + padding else { return nil }
        let standard = body
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        self.init(base64Encoded: standard + String(repeating: "=", count: padding))
    }
}
