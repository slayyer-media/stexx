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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var hasAppeared = false
    @State private var purchaseTaps = 0

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.xl) {
                hero
                    .padding(.top, Theme.Spacing.xxl)
                features
                GlassCard(tint: Theme.online.opacity(0.08)) {
                    HStack(alignment: .top, spacing: Theme.Spacing.m) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.title3)
                            .foregroundStyle(Theme.online)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Safety is always free")
                                .font(.headline.weight(.heavy))
                                .tracking(Theme.Tracking.tight)
                            Text("Blocking, reporting, hiding your distance and expiring photos never cost a thing.")
                                .font(.footnote)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
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
        .onAppear { hasAppeared = true }
        .sensoryFeedback(.impact(weight: .medium), trigger: purchaseTaps)
        .sensoryFeedback(.success, trigger: appState.hasPlus) { old, new in !old && new }
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: Theme.Spacing.m) {
            PaywallLogo()
                .padding(.bottom, Theme.Spacing.s)

            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Wordmark(size: 52)
                Text(verbatim: "+")
                    .font(.stexxDisplay(52))
                    .foregroundStyle(Theme.violetBright)
                    .shadow(color: Theme.edgeGlow.opacity(0.7), radius: 10)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "Stexx+"))
            .accessibilityAddTraits(.isHeader)

            Text("Extras for you.\nServers for everyone.")
                .font(.system(.title, weight: .black))
                .tracking(Theme.Tracking.tight)
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)

            HStack(spacing: Theme.Spacing.s) {
                XXBadge("No ads, ever")
                XXBadge("Cancel anytime")
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Features

    private var features: some View {
        GlassCard(tint: Theme.violet.opacity(0.10), padding: Theme.Spacing.l) {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                Text("What you get")
                    .font(.headline.weight(.heavy))
                    .tracking(Theme.Tracking.tight)
                    .foregroundStyle(Theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                ForEach(Array(PlusFeature.allCases.enumerated()), id: \.element) { index, feature in
                    FeatureRow(feature: feature)
                        .opacity(hasAppeared ? 1 : 0)
                        .offset(x: hasAppeared || reduceMotion ? 0 : 18)
                        .animation(
                            reduceMotion
                                ? .easeOut(duration: 0.2)
                                : Motion.cardSpring.delay(0.12 + Double(index) * 0.05),
                            value: hasAppeared
                        )
                }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .strokeBorder(
                    LinearGradient(
                        colors: [Theme.violetBright.opacity(0.55), Theme.edgeGlow.opacity(0.08), Theme.violet.opacity(0.35)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
                .allowsHitTesting(false)
        }
    }

    // MARK: Purchase

    private var purchaseBar: some View {
        VStack(spacing: Theme.Spacing.s) {
            if appState.hasPlus {
                Label("You have Stexx+. Thank you!", systemImage: "heart.fill")
                    .font(.headline.weight(.heavy))
                    .foregroundStyle(Theme.violetBright)
                    .padding(.vertical, Theme.Spacing.m)
            } else {
                Button {
                    purchaseTaps += 1
                    Task { await purchases.purchase(using: purchase) }
                } label: {
                    HStack(spacing: Theme.Spacing.s) {
                        if purchases.isPurchasing {
                            ProgressView()
                                .tint(.white)
                        }
                        Text("Get Stexx+ for \(purchases.displayPrice)/month")
                    }
                    .font(.headline.weight(.heavy))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.violet)
                .controlSize(.extraLarge)
                .background {
                    // Soft violet light pooling under the button.
                    Capsule()
                        .fill(Theme.edgeGlow)
                        .blur(radius: 18)
                        .opacity(0.45)
                        .padding(.horizontal, Theme.Spacing.xl)
                        .offset(y: 8)
                        .allowsHitTesting(false)
                }
                .disabled(purchases.isPurchasing || purchases.isRestoring)

                Button("Restore purchases") {
                    Task { await purchases.restore() }
                }
                .font(.footnote.weight(.semibold))
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

/// The glass logo tile on a softly breathing violet glow (static under
/// Reduce Motion).
private struct PaywallLogo: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isBreathing = false

    var body: some View {
        StexxLogoTile(size: 128)
            .background {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Theme.edgeGlow.opacity(0.6), Theme.violet.opacity(0.18), Theme.violet.opacity(0)],
                            center: .center,
                            startRadius: 8,
                            endRadius: 130
                        )
                    )
                    .frame(width: 270, height: 270)
                    .scaleEffect(isBreathing ? 1.08 : 0.94)
                    .opacity(isBreathing ? 1 : 0.75)
                    .allowsHitTesting(false)
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 2.8).repeatForever(autoreverses: true)) {
                    isBreathing = true
                }
            }
            .accessibilityHidden(true)
    }
}

private struct FeatureRow: View {
    let feature: PlusFeature

    @ScaledMetric(relativeTo: .body) private var glyphSize: CGFloat = 40

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: feature.systemImage)
                .font(.body.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: glyphSize, height: glyphSize)
                .background(Theme.accentGradient, in: .rect(cornerRadius: glyphSize * 0.3))
                .overlay(
                    RoundedRectangle(cornerRadius: glyphSize * 0.3)
                        .strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5)
                )
                .shadow(color: Theme.edgeGlow.opacity(0.5), radius: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(feature.title)
                    .font(.headline.weight(.heavy))
                    .tracking(Theme.Tracking.tight)
                    .foregroundStyle(Theme.textPrimary)
                Text(feature.detail)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
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
