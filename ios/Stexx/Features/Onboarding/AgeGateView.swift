import SwiftUI

/// 18+ gate. The birth date stays on the device and is discarded; only the
/// fact that the user confirmed they're an adult is remembered.
struct AgeGateView: View {
    var onConfirmed: () -> Void

    @Environment(AppState.self) private var appState
    @State private var birthDate = Date.now
    @State private var hasPickedDate = false

    private var age: Int {
        Calendar.current.dateComponents([.year], from: birthDate, to: .now).year ?? 0
    }

    private var isAdult: Bool { hasPickedDate && age >= 18 }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.xl) {
                VStack(spacing: Theme.Spacing.m) {
                    Image(systemName: "18.circle")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(Theme.steel)
                        .accessibilityHidden(true)
                    Text("adults only")
                        .stexxTitleStyle()
                        .accessibilityAddTraits(.isHeader)
                    Text("Stexx is for people 18 and older. Your birth date isn't stored or shown to anyone.")
                        .font(.stexxBody)
                        .foregroundStyle(Theme.steel)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, Theme.Spacing.xl)

                VStack(spacing: Theme.Spacing.s) {
                    SectionLabel("Birth date")
                    HairlineDivider()
                    DatePicker(
                        "Birth date",
                        selection: $birthDate,
                        in: ...Date.now,
                        displayedComponents: .date
                    )
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .onChange(of: birthDate) { hasPickedDate = true }
                    HairlineDivider()
                }

                if hasPickedDate && !isAdult {
                    Label("Sorry, you need to be 18 or older to use Stexx.", systemImage: "hand.raised.fill")
                        .font(.stexxSub)
                        .foregroundStyle(Theme.warning)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .animation(Motion.standard, value: isAdult)
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                appState.confirmAge()
                onConfirmed()
            } label: {
                WideLabel("I'm 18 or older")
            }
            .stexxPrimaryButton()
            .disabled(!isAdult)
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.bottom, Theme.Spacing.s)
        }
        .stexxBackground()
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        AgeGateView {}
    }
    .previewEnvironment(signedIn: false)
}
