import SwiftUI

/// Anonymous sign-up: a nickname plus either a passkey or an email used only
/// for sign-in links. No real name, no phone number. The email path sends a
/// link and a code (`EmailSignInModel`); the account exists once one of
/// them comes back.
struct SignUpView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.apiClient) private var api
    @Environment(\.passkeys) private var passkeys
    @Environment(\.allowsDevSignUpShortcut) private var allowsDevSignUpShortcut

    @State private var displayName = ""
    @State private var email = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var emailFlow: EmailSignInModel?
    @State private var showsCheckEmail = false
    @FocusState private var focusedField: Field?

    private enum Field { case name, email }

    private var trimmedName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isNameValid: Bool { (2...30).contains(trimmedName.count) }

    private var isEmailValid: Bool { EmailSignInModel.looksLikeEmail(email) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    Text("make it yours")
                        .stexxTitleStyle()
                        .accessibilityAddTraits(.isHeader)
                    Text("Pick a nickname. You can change it anytime, and nobody needs your real name.")
                        .font(.stexxBody)
                        .foregroundStyle(Theme.steel)
                }

                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    SectionLabel("Nickname")
                    SignUpField(isFocused: focusedField == .name) {
                        TextField("e.g. QuantumOtter", text: $displayName)
                            .font(.stexxHeadline)
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
                    .disabled(!isNameValid || isWorking || !passkeys.availability.isAvailable)

                    Text(passkeys.availability.explanation
                        ?? String(localized: "Recommended. Uses Face ID or Touch ID. Nothing to remember, nothing to leak."))
                        .font(.footnote)
                        .foregroundStyle(Theme.slate)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: Theme.Spacing.m) {
                    HairlineDivider()
                    Text("or").stexxLabelStyle(.micro, color: Theme.slate)
                    HairlineDivider()
                }

                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    SectionLabel("Email for sign-in links")
                    SignUpField(isFocused: focusedField == .email) {
                        TextField("you@example.com", text: $email)
                            .font(.stexxBody)
                            .keyboardType(.emailAddress)
                            .textContentType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .email)
                            .submitLabel(.go)
                            .onSubmit(signUpWithEmail)
                    }
                    Text("Never shown on your profile. An alias like Hide My Email works; temporary inboxes don't.")
                        .font(.footnote)
                        .foregroundStyle(Theme.slate)
                }

                Button(action: signUpWithEmail) {
                    WideLabel("Continue with email", systemImage: "envelope.fill")
                }
                .stexxSecondaryButton()
                .disabled(!isNameValid || !isEmailValid || isWorking)

                #if DEBUG
                if allowsDevSignUpShortcut {
                    // Local builds only: the dev server's no-email shortcut.
                    Button("Dev server: sign up without the email", action: signUpWithDevShortcut)
                        .font(.footnote)
                        .foregroundStyle(Theme.slate)
                        .frame(maxWidth: .infinity)
                        .disabled(!isNameValid || !isEmailValid || isWorking)
                }
                #endif

                if let errorMessage {
                    Text(errorMessage)
                        .font(.stexxSub)
                        .foregroundStyle(Theme.danger)
                }

                Text("By continuing you agree to our Terms and Community Guidelines.")
                    .font(.caption)
                    .foregroundStyle(Theme.slate)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.l)
        }
        .scrollDismissesKeyboard(.interactively)
        .stexxBackground()
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showsCheckEmail) {
            if let emailFlow {
                CheckEmailView(model: emailFlow, onSignedIn: finishSignIn, onChangeAddress: {
                    showsCheckEmail = false
                    focusedField = .email
                })
            }
        }
        .overlay {
            if isWorking {
                ProgressView()
                    .controlSize(.large)
                    .padding(Theme.Spacing.xl)
                    .tint(Theme.frost)
                    .blackGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
            }
        }
    }

    /// Options → system passkey sheet → finish (`PasskeyFlow`). Closing the
    /// sheet just returns here, without an error.
    private func signUpWithPasskey() {
        guard isNameValid, passkeys.availability.isAvailable else { return }
        let flow = PasskeyFlow(api: api, authenticator: passkeys.authenticator, availability: passkeys.availability)
        let name = trimmedName
        start { try await flow.signUp(displayName: name) }
    }

    /// Emails a link and a code; the nickname and the 18+ confirmation
    /// travel with the request and become the account when one comes back.
    private func signUpWithEmail() {
        guard isNameValid, isEmailValid, !isWorking else { return }
        let flow = EmailSignInModel(purpose: .signUp(displayName: trimmedName), api: api)
        emailFlow = flow
        focusedField = nil
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            if await flow.send(to: email) {
                showsCheckEmail = true
            } else {
                errorMessage = flow.problem?.message()
            }
        }
    }

    #if DEBUG
    /// `POST /auth/register` on a dev server (`config.devAuth`); production
    /// refuses it with `use_email_link`.
    private func signUpWithDevShortcut() {
        guard isNameValid, isEmailValid else { return }
        let request = RegistrationRequest(
            displayName: trimmedName,
            method: .email,
            email: EmailSignInModel.normalize(email),
            confirmedAdult: true
        )
        start { [api] in try await api.register(request) }
    }
    #endif

    private func finishSignIn(_ session: Session) async {
        appState.signIn(session)
        appState.me = try? await api.fetchMe()
    }

    private func start(_ makeSession: @escaping @MainActor () async throws -> Session) {
        focusedField = nil
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                await finishSignIn(try await makeSession())
            } catch PasskeyError.canceled {
                // The user closed the passkey sheet: nothing to report.
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// A flat ink1 field with a 0.5pt line, lineStrong while focused.
private struct SignUpField<Content: View>: View {
    var isFocused: Bool
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
        content
            .foregroundStyle(Theme.frost)
            .tint(Theme.ice)
            .padding(.horizontal, Theme.Spacing.l)
            .frame(minHeight: 52)
            .background(shape.fill(Theme.ink1))
            .hairlineBorder(shape, strong: isFocused)
            .animation(Motion.quick, value: isFocused)
    }
}

#Preview {
    NavigationStack {
        SignUpView()
    }
    .previewEnvironment(signedIn: false)
}

#Preview("Passkeys unavailable") {
    NavigationStack {
        SignUpView()
    }
    .previewEnvironment(signedIn: false)
    .environment(\.passkeys, PasskeySupport(availability: .unavailable(.localServer), authenticator: SimulatedPasskeyAuthenticator()))
}
