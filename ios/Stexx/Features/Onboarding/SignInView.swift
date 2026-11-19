import SwiftUI

/// Back into an existing account: the passkey made at sign-up, or an email
/// with a sign-in link (opened on this iPhone, it lands in `RootView`) and a
/// code to type on the next screen.
struct SignInView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.apiClient) private var api
    @Environment(\.passkeys) private var passkeys

    @State private var email = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    /// After a closed sheet: maybe there is no passkey on this iPhone.
    @State private var showsNoPasskeyHint = false
    @State private var emailFlow: EmailSignInModel?
    @State private var showsCheckEmail = false
    @FocusState private var isEmailFocused: Bool

    private var isEmailValid: Bool { EmailSignInModel.looksLikeEmail(email) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    Text("welcome back")
                        .stexxTitleStyle()
                        .accessibilityAddTraits(.isHeader)
                    Text("Use the passkey you made when you joined. Face ID or Touch ID, nothing to type.")
                        .font(.stexxBody)
                        .foregroundStyle(Theme.steel)
                }

                VStack(spacing: Theme.Spacing.m) {
                    Button(action: signInWithPasskey) {
                        WideLabel("Sign in with a passkey", systemImage: "person.badge.key.fill")
                    }
                    .stexxPrimaryButton()
                    .disabled(isWorking || !passkeys.availability.isAvailable)

                    if let explanation = passkeys.availability.explanation {
                        Text(explanation)
                            .font(.footnote)
                            .foregroundStyle(Theme.slate)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if showsNoPasskeyHint {
                        Text("No Stexx passkey on this iPhone? Pick one from another device in the sheet, get an email link below, or go back and sign up.")
                            .font(.footnote)
                            .foregroundStyle(Theme.steel)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: Theme.Spacing.m) {
                    HairlineDivider()
                    Text("or").stexxLabelStyle(.micro, color: Theme.slate)
                    HairlineDivider()
                }

                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    SectionLabel("Email")
                    TextField("you@example.com", text: $email)
                        .font(.stexxBody)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($isEmailFocused)
                        .submitLabel(.send)
                        .onSubmit(sendLink)
                        .foregroundStyle(Theme.frost)
                        .tint(Theme.ice)
                        .padding(.horizontal, Theme.Spacing.l)
                        .frame(minHeight: 52)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous).fill(Theme.ink1))
                        .hairlineBorder(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous), strong: isEmailFocused)
                    Text("For accounts made with email. We'll send a sign-in link and a code.")
                        .font(.footnote)
                        .foregroundStyle(Theme.slate)
                }

                Button(action: sendLink) {
                    WideLabel("Email me a link", systemImage: "envelope.fill")
                }
                .stexxSecondaryButton()
                .disabled(!isEmailValid || isWorking)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.stexxSub)
                        .foregroundStyle(Theme.danger)
                }
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
                    isEmailFocused = true
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

    private func signInWithPasskey() {
        guard passkeys.availability.isAvailable else { return }
        let flow = PasskeyFlow(api: api, authenticator: passkeys.authenticator, availability: passkeys.availability)
        isEmailFocused = false
        isWorking = true
        errorMessage = nil
        showsNoPasskeyHint = false
        Task {
            defer { isWorking = false }
            do {
                await finishSignIn(try await flow.signIn())
            } catch PasskeyError.canceled {
                // Closed by the user, or iOS had no passkey to offer.
                showsNoPasskeyHint = true
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Same answer whether or not the address has an account (no
    /// enumeration); an address without one finds out from the link.
    private func sendLink() {
        guard isEmailValid, !isWorking else { return }
        let flow = EmailSignInModel(purpose: .signIn, api: api)
        emailFlow = flow
        isEmailFocused = false
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

    private func finishSignIn(_ session: Session) async {
        appState.signIn(session)
        appState.me = try? await api.fetchMe()
    }
}

#Preview {
    NavigationStack {
        SignInView()
    }
    .previewEnvironment(signedIn: false)
}

#Preview("Passkeys unavailable") {
    NavigationStack {
        SignInView()
    }
    .previewEnvironment(signedIn: false)
    .environment(\.passkeys, PasskeySupport(availability: .unavailable(.localServer), authenticator: SimulatedPasskeyAuthenticator()))
}
