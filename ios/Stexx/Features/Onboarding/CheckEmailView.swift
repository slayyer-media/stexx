import SwiftUI

/// "Check your email": after a sign-up or sign-in email went out. The link
/// in it opens the app (`EmailLinkRedeemer`); the 8-digit code works here
/// on any device. Resending follows the server's limit.
struct CheckEmailView: View {
    @Bindable var model: EmailSignInModel
    /// Called with the session from a correct code.
    var onSignedIn: (Session) async -> Void
    /// "Use a different email": back to the form.
    var onChangeAddress: () -> Void

    @FocusState private var isCodeFocused: Bool

    private var explanation: String {
        switch model.purpose {
        case .signUp:
            String(localized: "Open the link on this iPhone to finish signing up, or type the code from the email. If this address already has an account, you'll be signed in to it.")
        case .signIn:
            String(localized: "Open the link on this iPhone, or type the code from the email. Reading it on another device? The code works there too.")
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    Image(systemName: "envelope.badge")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(Theme.steel)
                        .accessibilityHidden(true)
                        .padding(.bottom, Theme.Spacing.xs)
                    Text("check your email")
                        .stexxTitleStyle()
                        .accessibilityAddTraits(.isHeader)
                    Text("We sent a link and a code to \(Text(model.address).foregroundStyle(Theme.frost).bold()).")
                        .font(.stexxBody)
                        .foregroundStyle(Theme.steel)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(explanation)
                        .font(.stexxSub)
                        .foregroundStyle(Theme.steel)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    SectionLabel("Code")
                    CodeField(code: $model.code, isFocused: $isCodeFocused, onSubmit: submit)
                }

                VStack(spacing: Theme.Spacing.m) {
                    Button(action: submit) {
                        WideLabel(model.purpose == .signIn ? "Sign in" : "Finish signing up")
                    }
                    .stexxPrimaryButton()
                    .disabled(!model.isCodeComplete || model.isBusy)

                    if let problem = model.problem {
                        ProblemText(problem: problem)
                    }
                }

                HStack(spacing: Theme.Spacing.m) {
                    HairlineDivider()
                    Text("no email?").stexxLabelStyle(.micro, color: Theme.slate)
                    HairlineDivider()
                }

                VStack(spacing: Theme.Spacing.m) {
                    ResendButton(model: model)
                    Button("Use a different email", action: onChangeAddress)
                        .font(.stexxSub)
                        .foregroundStyle(Theme.ice)
                        .disabled(model.isBusy)
                    Text("The link and the code work once, for 15 minutes. Nothing there after a minute? Check your spam folder.")
                        .font(.footnote)
                        .foregroundStyle(Theme.slate)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.l)
        }
        .scrollDismissesKeyboard(.interactively)
        .stexxBackground()
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if model.phase == .verifying {
                ProgressView()
                    .controlSize(.large)
                    .padding(Theme.Spacing.xl)
                    .tint(Theme.frost)
                    .blackGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
            }
        }
    }

    private func submit() {
        guard model.isCodeComplete, !model.isBusy else { return }
        isCodeFocused = false
        Task {
            if let session = await model.submitCode() {
                await onSignedIn(session)
            }
        }
    }
}

/// Eight digits in mono, one field (paste and Mail's AutoFill fill it).
private struct CodeField: View {
    @Binding var code: String
    var isFocused: FocusState<Bool>.Binding
    var onSubmit: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
        TextField("8-digit code", text: $code)
            .font(.system(.title2, design: .monospaced).weight(.semibold))
            .tracking(6)
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
            .focused(isFocused)
            .submitLabel(.go)
            .onSubmit(onSubmit)
            .onChange(of: code) { _, new in
                if new.count == EmailSignInModel.codeLength { onSubmit() }
            }
            .foregroundStyle(Theme.frost)
            .tint(Theme.ice)
            .padding(.horizontal, Theme.Spacing.l)
            .frame(minHeight: 56)
            .background(shape.fill(Theme.ink1))
            .hairlineBorder(shape, strong: isFocused.wrappedValue)
            .accessibilityLabel("Code from the email")
    }
}

/// "Send another email", with a live countdown while the server (or the
/// cooldown) says to wait.
private struct ResendButton: View {
    let model: EmailSignInModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let wait = model.resendWait(at: context.date)
            Button {
                Task { await model.resend() }
            } label: {
                if model.phase == .sending {
                    WideLabel("Sending…")
                } else if wait > 0 {
                    WideLabel("Send another email in \(EmailSignInProblem.countdown(wait))")
                        .monospacedDigit()
                } else {
                    WideLabel("Send another email", systemImage: "arrow.clockwise")
                }
            }
            .stexxSecondaryButton()
            .disabled(!model.canResend(at: context.date))
            .accessibilityHint(wait > 0 ? Text("Available in \(Int(wait.rounded(.up))) seconds") : Text(""))
        }
    }
}

/// A problem as one line of friendly copy; a 429 counts down live.
private struct ProblemText: View {
    let problem: EmailSignInProblem

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Label(problem.message(now: context.date), systemImage: icon)
                .font(.stexxSub)
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var icon: String {
        switch problem {
        case .rateLimited: "hourglass"
        case .offline: "wifi.slash"
        default: "exclamationmark.circle"
        }
    }

    private var color: Color {
        if case .rateLimited = problem { return Theme.warning }
        return Theme.danger
    }
}

/// A sign-in link that opened the app but couldn't be used.
struct EmailLinkProblemView: View {
    let problem: EmailSignInProblem
    let isSignedIn: Bool
    var onFollowUp: (EmailLinkRedeemer.FollowUp?) -> Void

    private var followUp: (title: LocalizedStringKey, target: EmailLinkRedeemer.FollowUp)? {
        guard !isSignedIn else { return nil }
        switch problem {
        case .expiredLink: return ("Get a new link", .signIn)
        case .noAccount: return ("Sign up", .signUp)
        default: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            Image(systemName: problem == .offline ? "wifi.slash" : "envelope.open")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.steel)
                .accessibilityHidden(true)
            Text(problem.title)
                .stexxTitleStyle(.title)
                .accessibilityAddTraits(.isHeader)
            Text(problem.message())
                .font(.stexxBody)
                .foregroundStyle(Theme.steel)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            VStack(spacing: Theme.Spacing.m) {
                if let followUp {
                    Button { onFollowUp(followUp.target) } label: { WideLabel(followUp.title) }
                        .stexxPrimaryButton()
                    Button { onFollowUp(nil) } label: { WideLabel("Not now") }
                        .stexxSecondaryButton()
                } else {
                    Button { onFollowUp(nil) } label: { WideLabel("OK") }
                        .stexxPrimaryButton()
                }
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .stexxBackground()
    }
}

/// Over everything while a link is being used.
struct EmailLinkVerifyingOverlay: View {
    var body: some View {
        ZStack {
            Theme.ink.opacity(0.6).ignoresSafeArea()
            VStack(spacing: Theme.Spacing.m) {
                ProgressView()
                    .controlSize(.large)
                    .tint(Theme.frost)
                Text("Signing you in…")
                    .font(.stexxSub)
                    .foregroundStyle(Theme.frost)
            }
            .padding(Theme.Spacing.xl)
            .blackGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("Sign-up, sent") {
    @Previewable @State var model = EmailSignInModel(purpose: .signUp(displayName: "QuantumOtter"), api: MockAPIClient(latency: .zero))
    NavigationStack {
        CheckEmailView(model: model, onSignedIn: { _ in }, onChangeAddress: {})
    }
    .previewEnvironment(signedIn: false)
    .task { await model.send(to: "otter@example.com") }
}

#Preview("Expired link") {
    EmailLinkProblemView(problem: .expiredLink, isSignedIn: false) { _ in }
        .previewEnvironment(signedIn: false)
}
