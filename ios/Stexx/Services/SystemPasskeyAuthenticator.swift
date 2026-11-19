import AuthenticationServices
import UIKit

/// The system passkey sheet (AuthenticationServices, iCloud Keychain).
///
/// Needs the `webcredentials:<relying party>` associated domain (see
/// `project.yml`) and the relying party serving an
/// `apple-app-site-association` that lists this app; without them iOS fails
/// the request (`PasskeyError.failed`). Only covered by the passkey tests
/// through `PasskeyAuthenticating` fakes: the sheet can't run in unit tests.
struct SystemPasskeyAuthenticator: PasskeyAuthenticating {
    @MainActor func createPasskey(_ request: PasskeyRegistrationRequest) async throws -> PasskeyRegistration {
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: request.relyingPartyID)
        let registration = provider.createCredentialRegistrationRequest(
            challenge: request.challenge,
            name: request.userName,
            userID: request.userID
        )
        registration.userVerificationPreference = .required
        registration.attestationPreference = .none
        if !request.excludedCredentialIDs.isEmpty {
            registration.excludedCredentials = request.excludedCredentialIDs.map {
                ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0)
            }
        }

        let credential = try await PasskeyAuthorizationSession.perform(registration)
        guard let created = credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration,
              let attestationObject = created.rawAttestationObject
        else { throw PasskeyError.failed }
        return PasskeyRegistration(
            credentialID: created.credentialID,
            clientDataJSON: created.rawClientDataJSON,
            attestationObject: attestationObject,
            isPlatform: Self.isPlatform(created.attachment)
        )
    }

    @MainActor func assertPasskey(_ request: PasskeyAssertionRequest) async throws -> PasskeyAssertion {
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: request.relyingPartyID)
        let assertion = provider.createCredentialAssertionRequest(challenge: request.challenge)
        assertion.userVerificationPreference = .required
        if !request.allowedCredentialIDs.isEmpty {
            assertion.allowedCredentials = request.allowedCredentialIDs.map {
                ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0)
            }
        }

        let credential = try await PasskeyAuthorizationSession.perform(assertion)
        guard let signed = credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion else { throw PasskeyError.failed }
        return PasskeyAssertion(
            credentialID: signed.credentialID,
            clientDataJSON: signed.rawClientDataJSON,
            authenticatorData: signed.rawAuthenticatorData,
            signature: signed.signature,
            userID: signed.userID,
            isPlatform: Self.isPlatform(signed.attachment)
        )
    }

    private static func isPlatform(_ attachment: ASAuthorizationPublicKeyCredentialAttachment) -> Bool? {
        switch attachment {
        case .platform: true
        case .crossPlatform: false
        @unknown default: nil
        }
    }
}

/// One `ASAuthorizationController` run, bridged to async. The controller
/// only holds its delegate weakly; `perform` keeps `self` alive until the
/// delegate has answered.
@MainActor
private final class PasskeyAuthorizationSession: NSObject,
    ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding {
    private let anchor: ASPresentationAnchor
    private var continuation: CheckedContinuation<any ASAuthorizationCredential, any Error>?

    private init(anchor: ASPresentationAnchor) {
        self.anchor = anchor
    }

    /// Runs `request` on the system sheet, attached to the app's window.
    static func perform(_ request: ASAuthorizationRequest) async throws -> any ASAuthorizationCredential {
        // The app always has a window while one of its buttons can be tapped.
        guard let window = currentWindow() else { throw PasskeyError.failed }
        return try await PasskeyAuthorizationSession(anchor: window).run(request)
    }

    private func run(_ request: ASAuthorizationRequest) async throws -> any ASAuthorizationCredential {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            // No `.preferImmediatelyAvailableCredentials`: when this iPhone
            // has no Stexx passkey, the sheet still offers one from a nearby
            // device (QR code), and closing it reports `.canceled`.
            controller.performRequests()
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        continuation?.resume(returning: authorization.credential)
        continuation = nil
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: any Error) {
        continuation?.resume(throwing: PasskeyError.from(authorizationError: error))
        continuation = nil
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        anchor
    }

    private static func currentWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return scene?.keyWindow ?? scene?.windows.first
    }
}
