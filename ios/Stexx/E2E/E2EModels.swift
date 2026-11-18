import Foundation

// Wire models for end-to-end encryption (`docs/api.md`, "End-to-end
// encryption"). Keys, signatures and ciphertext are standard base64 with
// padding of libsignal's serialized forms. v1 is one device per account,
// device id 1.

/// `GET /e2e/config`. Always answers, also when the server has E2E off.
struct E2EConfig: Codable, Hashable, Sendable {
    enum Mode: String, Codable, Sendable {
        /// Plaintext only: `/keys` routes are 404 and envelopes are refused.
        case off
        /// Plaintext and envelopes both work, per message.
        case optional
        /// Plaintext `text` is refused (400 `encryption_required`).
        case required

        /// An unknown future mode is treated like `off` (safe: the server
        /// answers plaintext with `encryption_required` if it must).
        init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Mode(rawValue: raw) ?? .off
        }
    }

    /// The trust-ramp text rules the app enforces before encrypting, because
    /// the server can't read ciphertext (`docs/security.md` section 4).
    struct ContentRules: Codable, Hashable, Sendable {
        var restricted: Bool
        var noLinks: Bool
        var duplicateRecipients: Int
        var duplicateMinLength: Int

        static let unrestricted = ContentRules(restricted: false, noLinks: false, duplicateRecipients: 3, duplicateMinLength: 16)
    }

    var mode: Mode
    var deviceID: UInt32 = 1
    var maxPreKeys: Int = 100
    var maxPqPreKeys: Int = 25
    var preKeyLowWatermark: Int = 20
    var pqPreKeyLowWatermark: Int = 5
    var envelopeMaxBytes: Int = 32_768
    var contentRules: ContentRules = .unrestricted

    static let off = E2EConfig(mode: .off)
}

/// An encrypted message on the wire: `{ "type": "prekey" | "signal", "body": "<base64>" }`.
struct MessageEnvelope: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// libsignal `PreKeySignalMessage` (`CiphertextMessage.MessageType.preKey`):
        /// sent until the recipient has replied.
        case prekey
        /// libsignal `SignalMessage` (`.whisper`).
        case signal
    }

    var type: Kind
    /// `CiphertextMessage.serialize()`, base64.
    var body: String
}

/// `{ keyID, publicKey }`: a one-time EC prekey.
struct PreKeyUpload: Codable, Hashable, Sendable {
    var keyID: UInt32
    var publicKey: String
}

/// `{ keyID, publicKey, signature }`: the signed prekey, or a Kyber prekey
/// (one-time or last resort), signed by the identity key.
struct SignedPreKeyUpload: Codable, Hashable, Sendable {
    var keyID: UInt32
    var publicKey: String
    var signature: String
}

/// `PUT /keys`: the device's full key state.
struct KeyRegistration: Codable, Hashable, Sendable {
    var registrationID: UInt32
    var deviceID: UInt32 = 1
    var identityKey: String
    var signedPreKey: SignedPreKeyUpload
    var pqLastResortPreKey: SignedPreKeyUpload
    var preKeys: [PreKeyUpload]
    var pqPreKeys: [SignedPreKeyUpload]
}

/// `POST /keys/prekeys`: more one-time prekeys.
struct PreKeyReplenishment: Codable, Hashable, Sendable {
    var preKeys: [PreKeyUpload]?
    var pqPreKeys: [SignedPreKeyUpload]?
}

/// `PUT /keys/signed`: a rotated signed prekey and/or Kyber last-resort key.
struct SignedPreKeyRotation: Codable, Hashable, Sendable {
    var signedPreKey: SignedPreKeyUpload?
    var pqLastResortPreKey: SignedPreKeyUpload?
}

/// `KeyStatus`: this account's key state on the server.
struct KeyStatus: Codable, Hashable, Sendable {
    var registered: Bool
    var deviceID: UInt32?
    var registrationID: UInt32?
    var identityKey: String?
    var identityKeyChangedAt: Date?
    var preKeyCount: Int
    var pqPreKeyCount: Int
    var signedPreKeyID: UInt32?
    var signedPreKeyUpdatedAt: Date?
    var pqLastResortPreKeyID: UInt32?
    var pqLastResortPreKeyUpdatedAt: Date?
}

/// `GET /keys/bundle/{profileID}`: what's needed to start a session (PQXDH).
struct PreKeyBundleResponse: Codable, Hashable, Sendable {
    struct Device: Codable, Hashable, Sendable {
        var deviceID: UInt32
        var registrationID: UInt32
        var signedPreKey: SignedPreKeyUpload
        /// `nil` when none are left or the fetch was over budget.
        var preKey: PreKeyUpload?
        /// A one-time Kyber prekey, or the last-resort one.
        var pqPreKey: SignedPreKeyUpload
    }

    var userID: Profile.ID
    var identityKey: String
    var identityKeyChangedAt: Date?
    var devices: [Device]
}

/// `GET /keys/identity/{profileID}`.
struct IdentityKeyResponse: Codable, Hashable, Sendable {
    var userID: Profile.ID
    var identityKey: String
    var identityKeyChangedAt: Date?
}

/// Error codes the E2E routes answer with (`docs/security.md`, "Error codes
/// the app handles").
enum E2EErrorCode {
    /// 400/404: the server has E2E off. Send plaintext.
    static let disabled = "e2e_disabled"
    /// 404: the recipient has no keys. Plaintext while the mode is `optional`.
    static let keysUnavailable = "keys_unavailable"
    /// 400: plaintext refused, the server requires encryption.
    static let encryptionRequired = "encryption_required"
    /// 409: replenish/rotate before `PUT /keys`.
    static let keysNotRegistered = "keys_not_registered"
    static let prekeyLimit = "prekey_limit"
    static let invalidKey = "invalid_key"
    static let invalidSignature = "invalid_signature"
    static let invalidEnvelope = "invalid_envelope"

    static let all: Set<String> = [
        disabled, keysUnavailable, encryptionRequired, keysNotRegistered,
        prekeyLimit, invalidKey, invalidSignature, invalidEnvelope,
    ]
}
