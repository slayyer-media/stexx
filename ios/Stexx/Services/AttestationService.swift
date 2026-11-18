import CryptoKit
import DeviceCheck
import Foundation

/// Proves to the server that a request comes from the genuine Stexx app on
/// a real iPhone (anti-spam, see `docs/security.md`). `HTTPAPIClient` asks
/// for headers on sign-up, sign-in, sending messages, photo uploads and
/// account deletion.
protocol RequestAttesting: Sendable {
    /// Headers for one request. `body` is exactly what will be sent.
    /// `includeDeviceToken` adds a DeviceCheck token (sign-up, sign-in,
    /// account deletion) so the server can read the per-device bits.
    func headers(method: String, path: String, body: Data?, includeDeviceToken: Bool) async -> [String: String]
    /// The server no longer knows our key: forget it so the next request
    /// attests a fresh one.
    func resetKey() async
}

/// App Attest with a DeviceCheck fallback.
///
/// - **App Attest** (iOS devices): once per install it generates a Secure
///   Enclave key, attests it against a one-time server challenge
///   (`POST /v1/attest/challenge`, `POST /v1/attest/key`), and from then on
///   signs each protected request with an assertion over
///   `clientData(method:path:timestamp:body:)`.
/// - **DeviceCheck** token when App Attest isn't supported.
/// - **Dev bypass** (`X-Stexx-Attestation: dev-bypass`) in the Local build
///   and the simulator, which has neither. Only a server in
///   `ATTESTATION_MODE=dev` accepts it.
///
/// The key ID lives in UserDefaults, not the Keychain: App Attest keys
/// don't survive a reinstall, and neither should the ID pointing at one.
actor AttestationService: RequestAttesting {
    enum Mode: String, Sendable {
        /// Real App Attest / DeviceCheck.
        case attest
        /// Always send the dev bypass (Local builds against a dev server).
        case devBypass = "dev-bypass"
        /// Send nothing.
        case off
    }

    let mode: Mode
    private let endpoint: URL
    private let session: URLSession
    private let defaults: UserDefaults
    private var pendingKey: Task<String, any Error>?

    static let keyIDDefaultsKey = "stexx.attestation.keyID"

    init(mode: Mode, baseURL: URL, apiVersion: String = "v1", session: URLSession = .stexxAPI, defaults: UserDefaults = .standard) {
        self.mode = mode
        self.endpoint = baseURL.appending(path: apiVersion)
        self.session = session
        self.defaults = defaults
    }

    /// `StexxAttestationMode` in Info.plist (from `STEXX_ATTESTATION_MODE`).
    static func mode(from bundle: Bundle = .main) -> Mode {
        (bundle.object(forInfoDictionaryKey: "StexxAttestationMode") as? String).flatMap(Mode.init(rawValue:)) ?? .attest
    }

    // MARK: RequestAttesting

    func headers(method: String, path: String, body: Data?, includeDeviceToken: Bool) async -> [String: String] {
        switch mode {
        case .off:
            return [:]
        case .devBypass:
            return ["X-Stexx-Attestation": "dev-bypass"]
        case .attest:
            var headers: [String: String] = [:]
            if includeDeviceToken, let token = await Self.deviceCheckToken() {
                headers["X-Stexx-Device-Token"] = token
            }
            if Self.appAttestSupported {
                do {
                    let keyID = try await attestedKeyID()
                    let timestamp = Int64(Date.now.timeIntervalSince1970 * 1000)
                    let clientData = Self.clientData(method: method, path: path, timestamp: timestamp, body: body ?? Data())
                    let assertion = try await Self.generateAssertion(keyID, clientDataHash: Data(SHA256.hash(data: clientData)))
                    headers["X-Stexx-Key-Id"] = keyID
                    headers["X-Stexx-Assertion"] = assertion.base64EncodedString()
                    headers["X-Stexx-Timestamp"] = String(timestamp)
                } catch let error as DCError where error.code == .invalidKey || error.code == .invalidInput {
                    // The key is gone (e.g. restored from a backup onto a new phone): start over next time.
                    forgetKey()
                } catch {
                    // Network or server trouble: send what we have; the server explains what's missing.
                }
            } else if headers["X-Stexx-Device-Token"] == nil, let token = await Self.deviceCheckToken() {
                headers["X-Stexx-Device-Token"] = token
            }
            #if DEBUG
            if headers.isEmpty { headers["X-Stexx-Attestation"] = "dev-bypass" } // simulator
            #endif
            return headers
        }
    }

    func resetKey() {
        forgetKey()
    }

    // MARK: Key lifecycle

    private func forgetKey() {
        defaults.removeObject(forKey: Self.keyIDDefaultsKey)
        pendingKey?.cancel()
        pendingKey = nil
    }

    /// The attested key's ID, creating and attesting one on first use
    /// (single flight across concurrent requests).
    private func attestedKeyID() async throws -> String {
        if let keyID = defaults.string(forKey: Self.keyIDDefaultsKey) { return keyID }
        if let pendingKey { return try await pendingKey.value }
        let endpoint = endpoint
        let session = session
        let task = Task { () throws -> String in
            let keyID = try await Self.generateKey()
            let challenge = try await Self.fetchChallenge(endpoint: endpoint, session: session)
            let attestation = try await Self.attestKey(keyID, clientDataHash: Data(SHA256.hash(data: Data(challenge.utf8))))
            try await Self.registerKey(
                endpoint: endpoint,
                session: session,
                keyID: keyID,
                attestation: attestation,
                challenge: challenge
            )
            return keyID
        }
        pendingKey = task
        do {
            let keyID = try await task.value
            defaults.set(keyID, forKey: Self.keyIDDefaultsKey)
            pendingKey = nil
            return keyID
        } catch {
            pendingKey = nil
            throw error
        }
    }

    /// The bytes an assertion signs. Must match `assertionClientData` in
    /// `server/src/lib/abuse/appattest.ts` exactly.
    static func clientData(method: String, path: String, timestamp: Int64, body: Data) -> Data {
        let bodyHash = Data(SHA256.hash(data: body)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return Data("stexx-assert-v1\n\(method.uppercased())\n\(path)\n\(timestamp)\n\(bodyHash)".utf8)
    }

    // MARK: Apple APIs (nonisolated: the services aren't Sendable)

    private nonisolated static var appAttestSupported: Bool { DCAppAttestService.shared.isSupported }

    private nonisolated static func generateKey() async throws -> String {
        try await DCAppAttestService.shared.generateKey()
    }

    private nonisolated static func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.attestKey(keyID, clientDataHash: clientDataHash)
    }

    private nonisolated static func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.generateAssertion(keyID, clientDataHash: clientDataHash)
    }

    private nonisolated static func deviceCheckToken() async -> String? {
        guard DCDevice.current.isSupported else { return nil }
        return try? await DCDevice.current.generateToken().base64EncodedString()
    }

    // MARK: Server calls (no session, no attestation)

    private struct ChallengeResponse: Decodable { let challenge: String }
    private struct KeyBody: Encodable { let keyID: String; let attestation: String; let challenge: String }
    struct RegistrationFailed: Error { let status: Int }

    private nonisolated static func fetchChallenge(endpoint: URL, session: URLSession) async throws -> String {
        var request = URLRequest(url: endpoint.appending(path: "attest/challenge"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw RegistrationFailed(status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder().decode(ChallengeResponse.self, from: data).challenge
    }

    private nonisolated static func registerKey(
        endpoint: URL,
        session: URLSession,
        keyID: String,
        attestation: Data,
        challenge: String
    ) async throws {
        var request = URLRequest(url: endpoint.appending(path: "attest/key"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            KeyBody(keyID: keyID, attestation: attestation.base64EncodedString(), challenge: challenge)
        )
        let (_, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 204 else { throw RegistrationFailed(status: status) }
    }
}
