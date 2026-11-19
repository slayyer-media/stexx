import SwiftUI

/// Welcome → 18+ gate → anonymous sign-up, or → 18+ gate → sign-in for an
/// existing account (the gate is per device: `AppState.isSignedIn` needs it).
struct OnboardingFlow: View {
    enum Step: Hashable {
        case ageGate(then: Destination)
        case signUp
        case signIn
    }

    enum Destination: Hashable {
        case signUp, signIn

        var step: Step { self == .signUp ? .signUp : .signIn }
    }

    @Environment(AppState.self) private var appState
    @State private var path: [Step] = []

    var body: some View {
        NavigationStack(path: $path) {
            WelcomeView(
                onContinue: { go(to: .signUp) },
                onSignIn: { go(to: .signIn) }
            )
            .navigationDestination(for: Step.self) { step in
                switch step {
                case .ageGate(let destination):
                    AgeGateView { path.append(destination.step) }
                case .signUp:
                    SignUpView()
                case .signIn:
                    SignInView()
                }
            }
        }
    }

    private func go(to destination: Destination) {
        path.append(appState.isAgeConfirmed ? destination.step : .ageGate(then: destination))
    }
}

struct WelcomeView: View {
    var onContinue: () -> Void
    var onSignIn: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: Theme.Spacing.xl)

            VStack(spacing: Theme.Spacing.xl) {
                StexxLogoTile(size: 112)
                    .scaleEffect(hasAppeared || reduceMotion ? 1 : 0.96)
                VStack(spacing: Theme.Spacing.m) {
                    Wordmark(size: 56)
                    Tagline()
                }
            }
            .opacity(hasAppeared ? 1 : 0)

            Spacer(minLength: Theme.Spacing.xl)

            VStack(alignment: .leading, spacing: 0) {
                PromiseRow(
                    systemImage: "theatermasks",
                    title: "Anonymous by default",
                    detail: "No real name, no phone number, no contacts upload."
                )
                HairlineDivider(leadingInset: PromiseRow.textInset)
                PromiseRow(
                    systemImage: "location.slash",
                    title: "Approximate distance only",
                    detail: "Your location is rounded on your phone before it's sent."
                )
                HairlineDivider(leadingInset: PromiseRow.textInset)
                PromiseRow(
                    systemImage: "chevron.left.forwardslash.chevron.right",
                    title: "Open source, AGPL-3.0",
                    detail: "No ads, no trackers, no data sales. Read the code."
                )
            }
            .offset(y: hasAppeared || reduceMotion ? 0 : 8)
            .opacity(hasAppeared ? 1 : 0)

            VStack(spacing: Theme.Spacing.m) {
                Button(action: onContinue) {
                    WideLabel("Get started")
                }
                .stexxPrimaryButton()

                Button(action: onSignIn) {
                    WideLabel("I already have an account")
                }
                .stexxSecondaryButton()

                Text("Stexx is for adults 18+ only.")
                    .stexxLabelStyle(.micro, color: Theme.slate)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, Theme.Spacing.xl)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.bottom, Theme.Spacing.l)
        .background { GlowBackground() }
        .toolbarVisibility(.hidden, for: .navigationBar)
        .onAppear {
            guard !hasAppeared else { return }
            withAnimation(reduceMotion ? Motion.fade : .easeOut(duration: 0.28)) {
                hasAppeared = true
            }
        }
    }
}

private struct PromiseRow: View {
    static let iconWidth: CGFloat = 24
    static let textInset: CGFloat = iconWidth + Theme.Spacing.m

    let systemImage: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.m) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(Theme.steel)
                .frame(width: Self.iconWidth)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.stexxHeadline)
                    .foregroundStyle(Theme.frost)
                Text(detail)
                    .font(.stexxSub)
                    .foregroundStyle(Theme.steel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Spacing.m)
        .accessibilityElement(children: .combine)
    }
}

#Preview("Welcome") {
    NavigationStack {
        WelcomeView(onContinue: {}, onSignIn: {})
    }
    .previewEnvironment(signedIn: false)
}
