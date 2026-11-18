import StoreKit
import SwiftUI

/// Stexx+ features, in one place so the paywall, settings and docs agree.
enum PlusFeature: CaseIterable, Identifiable {
    case advancedFilters, incognito, viewers, travelMode, boosts

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .advancedFilters: "Advanced filters"
        case .incognito: "Incognito"
        case .viewers: "Who viewed you"
        case .travelMode: "Travel mode"
        case .boosts: "Boosts"
        }
    }

    var detail: LocalizedStringKey {
        switch self {
        case .advancedFilters: "Age, distance, position, tags and more."
        case .incognito: "Browse without showing up in the grid."
        case .viewers: "See who checked out your profile."
        case .travelMode: "Set your location before you land."
        case .boosts: "Get seen first nearby for an hour."
        }
    }

    var systemImage: String {
        switch self {
        case .advancedFilters: "line.3.horizontal.decrease.circle"
        case .incognito: "eye.slash"
        case .viewers: "eyes"
        case .travelMode: "airplane"
        case .boosts: "bolt.fill"
        }
    }
}

enum PlusProduct {
    /// App Store product ID for the monthly subscription.
    static let monthlyID = "gay.stexx.app.plus.monthly"
    /// Shown until StoreKit's localized `Product.displayPrice` has loaded.
    static let placeholderPrice = "$9.99"
}

/// Stexx+ paywall. Purchases use StoreKit 2 with server-side verification
/// (`POST /v1/subscriptions/apple`); see `PurchaseService`.
struct PaywallView: View {
    @Environment(AppState.self) private var appState
    @Environment(PurchaseService.self) private var purchases
    @Environment(\.purchase) private var purchase
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.xl) {
                VStack(spacing: Theme.Spacing.m) {
                    StexxLogoTile(size: 96)
                    HStack(spacing: 0) {
                        Wordmark(size: 44)
                        Text(verbatim: "+")
                            .font(.stexxDisplay(44))
                            .foregroundStyle(Theme.violetBright)
                    }
                    Text("Extras for you. Servers for everyone.\nNo ads, ever.")
                        .font(.body)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, Theme.Spacing.xxl)

                VStack(spacing: Theme.Spacing.s) {
                    ForEach(PlusFeature.allCases) { feature in
                        FeatureRow(feature: feature)
                    }
                }

                GlassCard(tint: Theme.online.opacity(0.08)) {
                    HStack(alignment: .top, spacing: Theme.Spacing.m) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.title3)
                            .foregroundStyle(Theme.online)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Safety is always free")
                                .font(.stexxHeadline)
                            Text("Blocking, reporting, hiding your distance and expiring photos never cost a thing.")
                                .font(.footnote)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.bottom, Theme.Spacing.l)
        }
        .stexxBackground(intensity: 1.2)
        .safeAreaInset(edge: .bottom) { purchaseBar }
        .overlay(alignment: .topTrailing) {
            GlassIconButton("Close", systemImage: "xmark") { dismiss() }
                .padding(Theme.Spacing.l)
        }
        .alert("Stexx+", isPresented: Binding(
            get: { purchases.errorMessage != nil },
            set: { if !$0 { purchases.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(purchases.errorMessage ?? "")
        }
        .task { await purchases.loadProducts() }
    }

    private var purchaseBar: some View {
        VStack(spacing: Theme.Spacing.s) {
            if appState.hasPlus {
                Label("You have Stexx+. Thank you!", systemImage: "heart.fill")
                    .font(.headline)
                    .foregroundStyle(Theme.violetBright)
                    .padding(.vertical, Theme.Spacing.m)
            } else {
                Button {
                    Task { await purchases.purchase(using: purchase) }
                } label: {
                    WideLabel("Get Stexx+ for \(purchases.displayPrice)/month")
                }
                .stexxPrimaryButton()
                .disabled(purchases.isPurchasing || purchases.isRestoring)

                Button("Restore purchases") {
                    Task { await purchases.restore() }
                }
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .disabled(purchases.isPurchasing || purchases.isRestoring)

                #if DEBUG
                Button("Simulate purchase (debug)") {
                    Task { await purchases.debugGrantPlus() }
                }
                .font(.footnote)
                .foregroundStyle(Theme.textTertiary)
                #endif

                Text("Cancel anytime in Settings. Billed monthly through the App Store.")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, Theme.Spacing.l)
        .padding(.bottom, Theme.Spacing.s)
        // The bar sits in a safe-area inset over the scroll view; without a
        // backdrop, scrolled cards showed through behind the buttons.
        .background {
            LinearGradient(
                stops: [
                    .init(color: Theme.background.opacity(0), location: 0),
                    .init(color: Theme.background.opacity(0.92), location: 0.25),
                    .init(color: Theme.background, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        }
    }
}

private struct FeatureRow: View {
    let feature: PlusFeature

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: feature.systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.violetBright)
                .frame(width: 40, height: 40)
                .background(Theme.violet.opacity(0.18), in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(feature.title)
                    .font(.stexxHeadline)
                    .foregroundStyle(Theme.textPrimary)
                Text(feature.detail)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.m)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            PaywallView()
        }
        .previewEnvironment()
}

#Preview("Has Plus") {
    PaywallView()
        .previewEnvironment(plus: true)
}
