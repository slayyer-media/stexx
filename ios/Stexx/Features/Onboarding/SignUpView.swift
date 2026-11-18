import SwiftUI

/// Anonymous sign-up: a nickname plus either a passkey or an email used only
/// for sign-in links. No real name, no phone number.
struct SignUpView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.apiClient) private var api

    @State private var displayName = ""
    @State private var email = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

    private enum Field { case name, email }

    private var trimmedName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isNameValid: Bool { (2...30).contains(trimmedName.count) }

    private var isEmailValid: Bool {
        let value = email.trimmingCharacters(in: .whitespaces)
        guard let at = value.firstIndex(of: "@") else { return false }
        return value[value.index(after: at)...].contains(".") && at != value.startIndex
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    Text("Make it yours")
                        .font(.stexxLargeTitle)
                    Text("Pick a nickname. You can change it anytime, and nobody needs your real name.")
                        .foregroundStyle(Theme.textSecondary)
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        SectionLabel("Nickname")
                        TextField("e.g. QuantumOtter", text: $displayName)
                            .font(.title3.weight(.semibold))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.nickname)
                            .focused($focusedField, equals: .name)
                            .submitLabel(.next)
                            .onSubmit { focusedField = .email }
                    }
                }

                VStack(spacing: Theme.Spacing.m) {
                    Button(action: signUpWithPasskey) {
                        WideLabel("Continue with a passkey", systemImage: "person.badge.key.fill")
                    }
                    .stexxPrimaryButton()
                    .disabled(!isNameValid || isWorking)

                    Text("Recommended. Uses Face ID or Touch ID. Nothing to remember, nothing to leak.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textTertiary)
                        .multilineTextAlignment(.center)
                }

                HStack {
                    Rectangle().fill(Theme.hairline).frame(height: 0.5)
                    Text("or").font(.footnote).foregroundStyle(Theme.textTertiary)
                    Rectangle().fill(Theme.hairline).frame(height: 0.5)
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        SectionLabel("Email for sign-in links")
                        TextField("you@example.com", text: $email)
                            .keyboardType(.emailAddress)
                            .textContentType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .email)
                            .submitLabel(.go)
                            .onSubmit(signUpWithEmail)
                        Text("Never shown on your profile. Use a throwaway or alias if you like.")
                            .font(.footnote)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }

                Button(action: signUpWithEmail) {
                    WideLabel("Continue with email", systemImage: "envelope.fill")
                }
                .stexxSecondaryButton()
                .disabled(!isNameValid || !isEmailValid || isWorking)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(Theme.danger)
                }

                Text("By continuing you agree to our Terms and Community Guidelines.")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.l)
        }
        .scrollDismissesKeyboard(.interactively)
        .stexxBackground()
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if isWorking {
                ProgressView()
                    .controlSize(.large)
                    .padding(Theme.Spacing.xl)
                    .glassEffect(.regular, in: .rect(cornerRadius: Theme.Radius.card))
            }
        }
    }

    private func signUpWithPasskey() {
        // TODO: Real passkey flow with AuthenticationServices:
        // fetch options from POST /v1/auth/passkey/register/options, create
        // an ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: "stexx.gay")
        // registration request, then send the attestation to .../finish.
        // Requires the `webcredentials:stexx.gay` associated domain.
        register(RegistrationRequest(displayName: trimmedName, method: .passkey, email: nil, confirmedAdult: true))
    }

    private func signUpWithEmail() {
        guard isNameValid, isEmailValid else { return }
        register(RegistrationRequest(
            displayName: trimmedName,
            method: .email,
            email: email.trimmingCharacters(in: .whitespaces),
            confirmedAdult: true
        ))
    }

    private func register(_ request: RegistrationRequest) {
        focusedField = nil
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                let session = try await api.register(request)
                appState.signIn(session)
                appState.me = try? await api.fetchMe()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

#Preview {
    NavigationStack {
        SignUpView()
    }
    .previewEnvironment(signedIn: false)
}
