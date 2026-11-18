import SwiftUI

/// Welcome → 18+ gate → anonymous sign-up.
struct OnboardingFlow: View {
    enum Step: Hashable {
        case ageGate, signUp
    }

    @Environment(AppState.self) private var appState
    @State private var path: [Step] = []

    var body: some View {
        NavigationStack(path: $path) {
            WelcomeView {
                path.append(appState.isAgeConfirmed ? .signUp : .ageGate)
            }
            .navigationDestination(for: Step.self) { step in
                switch step {
                case .ageGate:
                    AgeGateView { path.append(.signUp) }
                case .signUp:
                    SignUpView()
                }
            }
        }
    }
}

struct WelcomeView: View {
    var onContinue: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: Theme.Spacing.xl)

            VStack(spacing: Theme.Spacing.l) {
                StexxLogoTile(size: 128)
                    .scaleEffect(hasAppeared ? 1 : 0.85)
                Wordmark(size: 56)
                Text("No ads. Just stexx.")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            .opacity(hasAppeared ? 1 : 0)

            Spacer(minLength: Theme.Spacing.xl)

            GlassCard {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    PromiseRow(
                        systemImage: "theatermasks",
                        title: "Anonymous by default",
                        detail: "No real name, no phone number, no contacts upload."
                    )
                    PromiseRow(
                        systemImage: "location.slash",
                        title: "Approximate distance only",
                        detail: "Your location is rounded on your phone before it's sent."
                    )
                    PromiseRow(
                        systemImage: "chevron.left.forwardslash.chevron.right",
                        title: "Open source, AGPL-3.0",
                        detail: "No ads, no trackers, no data sales. Read the code."
                    )
                }
            }
            .offset(y: hasAppeared ? 0 : 24)
            .opacity(hasAppeared ? 1 : 0)

            VStack(spacing: Theme.Spacing.m) {
                Button(action: onContinue) {
                    WideLabel("Get started")
                }
                .stexxPrimaryButton()

                Text("Stexx is for adults 18+ only.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.top, Theme.Spacing.xl)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.bottom, Theme.Spacing.l)
        .background { GlowBackground(intensity: 1.25) }
        .toolbarVisibility(.hidden, for: .navigationBar)
        .onAppear {
            guard !hasAppeared else { return }
            withAnimation(reduceMotion ? nil : .spring(duration: 0.9, bounce: 0.25)) {
                hasAppeared = true
            }
        }
    }
}

private struct PromiseRow: View {
    let systemImage: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.violetBright)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.stexxHeadline)
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("Welcome") {
    NavigationStack {
        WelcomeView {}
    }
    .previewEnvironment(signedIn: false)
}
