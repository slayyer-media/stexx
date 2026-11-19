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
/// (`POST /v1/subscriptions/apple`); see `PurchaseService`. Subscribers see
/// when Stexx+ renews or ends and can manage the subscription; everyone sees
/// the Terms of Use and Privacy Policy (App Store Guideline 3.1.2).
struct PaywallView: View {
    @Environment(AppState.self) private var appState
    @Environment(PurchaseService.self) private var purchases
    @Environment(\.purchase) private var purchase
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var hasAppeared = false
    @State private var purchaseTaps = 0
    @State private var isManagingSubscription = false

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.xxl) {
                hero
                    .padding(.top, Theme.Spacing.xxxl)
                features
                if !appState.hasPlus {
                    plan
                }
                safetyNote
            }
            .padding(.horizontal, Theme.Spacing.screen)
            .padding(.bottom, Theme.Spacing.xl)
        }
        .stexxBackground()
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
        .task {
            await purchases.loadProducts()
            // Subscribers: pick up a renewal-status change made elsewhere.
            if appState.hasPlus { await purchases.refreshEntitlement() }
        }
        .manageSubscriptionsSheet(isPresented: $isManagingSubscription)
        .onChange(of: isManagingSubscription) { _, isShowing in
            // Back from the App Store sheet: the user may have cancelled or
            // resubscribed, so re-read the server's view.
            if !isShowing { Task { await purchases.refreshEntitlement() } }
        }
        .onAppear { hasAppeared = true }
        .sensoryFeedback(.impact(weight: .medium), trigger: purchaseTaps)
        .sensoryFeedback(.success, trigger: appState.hasPlus) { old, new in !old && new }
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: Theme.Spacing.l) {
            StexxLogoTile(size: 96)
                .accessibilityHidden(true)
                .padding(.bottom, Theme.Spacing.m)

            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Wordmark(size: 52)
                Text(verbatim: "+")
                    .font(.stexxDisplay(52))
                    .foregroundStyle(Theme.frost)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "Stexx+"))
            .accessibilityAddTraits(.isHeader)

            Tagline()

            Text("Extras for you.\nServers for everyone.")
                .font(.stexxSub)
                .foregroundStyle(Theme.steel)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Features

    private var features: some View {
        GlassCard(padding: 0, rimLit: true) {
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel("What you get")
                    .padding(.horizontal, Theme.Spacing.l)
                    .padding(.top, Theme.Spacing.l)
                    .padding(.bottom, Theme.Spacing.s)
                ForEach(Array(PlusFeature.allCases.enumerated()), id: \.element) { index, feature in
                    if index > 0 {
                        HairlineDivider(leadingInset: Theme.Spacing.l + FeatureRow.iconWidth + Theme.Spacing.m)
                    }
                    FeatureRow(feature: feature)
                        .padding(.horizontal, Theme.Spacing.l)
                        .opacity(hasAppeared ? 1 : 0)
                        .offset(y: hasAppeared || reduceMotion ? 0 : 6)
                        .animation(
                            reduceMotion
                                ? Motion.fade
                                : Motion.standard.delay(0.08 + Double(index) * 0.04),
                            value: hasAppeared
                        )
                }
            }
            .padding(.bottom, Theme.Spacing.s)
        }
    }

    // MARK: Plan

    /// The single monthly plan, shown as a flat, selected row.
    private var plan: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
        return VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            SectionLabel("Plan")
            HStack(spacing: Theme.Spacing.m) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(Theme.ice)
                Text("Monthly")
                    .font(.stexxHeadline)
                    .foregroundStyle(Theme.frost)
                Spacer(minLength: Theme.Spacing.s)
                Text(verbatim: purchases.displayPrice)
                    .stexxLabelStyle(color: Theme.frost)
            }
            .padding(.horizontal, Theme.Spacing.l)
            .frame(minHeight: 52)
            .background(shape.fill(Theme.ink2))
            .overlay(shape.strokeBorder(Theme.frost.opacity(0.6), lineWidth: 0.5))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isSelected)
        }
    }

    // MARK: Safety

    private var safetyNote: some View {
        VStack(alignment: .leading, spacing: 0) {
            HairlineDivider()
            HStack(alignment: .top, spacing: Theme.Spacing.m) {
                Image(systemName: "checkmark.shield")
                    .font(.body)
                    .foregroundStyle(Theme.steel)
                    .frame(width: FeatureRow.iconWidth)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Safety is always free")
                        .font(.stexxHeadline)
                        .foregroundStyle(Theme.frost)
                    Text("Blocking, reporting, hiding your distance and expiring photos never cost a thing.")
                        .font(.stexxSub)
                        .foregroundStyle(Theme.steel)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, Theme.Spacing.l)
            HairlineDivider()
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Purchase

    private var purchaseBar: some View {
        VStack(spacing: Theme.Spacing.m) {
            if appState.hasPlus {
                VStack(spacing: Theme.Spacing.xs) {
                    Label("You have Stexx+. Thank you!", systemImage: "heart.fill")
                        .font(.stexxHeadline)
                        .foregroundStyle(Theme.frost)
                    if let renewal = appState.plusRenewal {
                        Text(verbatim: renewal.label())
                            .font(.stexxSub)
                            .foregroundStyle(Theme.steel)
                    }
                }
                .multilineTextAlignment(.center)
                .accessibilityElement(children: .combine)

                Button {
                    isManagingSubscription = true
                } label: {
                    WideLabel("Manage subscription")
                }
                .stexxSecondaryButton()

                legalLinks
            } else {
                Button {
                    purchaseTaps += 1
                    Task { await purchases.purchase(using: purchase) }
                } label: {
                    HStack(spacing: Theme.Spacing.s) {
                        if purchases.isPurchasing {
                            ProgressView()
                                .tint(Theme.ink)
                        }
                        Text("Get Stexx+ for \(purchases.displayPrice)/month")
                    }
                    .frame(maxWidth: .infinity)
                }
                .stexxPrimaryButton()
                .disabled(purchases.isPurchasing || purchases.isRestoring)

                Button("Restore purchases") {
                    Task { await purchases.restore() }
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.steel)
                .disabled(purchases.isPurchasing || purchases.isRestoring)

                #if DEBUG
                Button("Simulate purchase (debug)") {
                    Task { await purchases.debugGrantPlus() }
                }
                .font(.footnote)
                .foregroundStyle(Theme.slate)
                #endif

                Text("Billed monthly through the App Store. Renews automatically until you cancel in Settings, at least 24 hours before the renewal date.")
                    .font(.caption)
                    .foregroundStyle(Theme.slate)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                legalLinks
            }
        }
        .padding(.horizontal, Theme.Spacing.screen)
        .padding(.top, Theme.Spacing.l)
        .padding(.bottom, Theme.Spacing.s)
        // The bar sits in a safe-area inset over the scroll view: black
        // frosted glass keeps scrolled content from showing through.
        .background {
            Color.clear
                .blackGlass(in: Rectangle())
                .ignoresSafeArea(edges: .bottom)
        }
    }
}

extension PaywallView {
    /// Terms of Use and Privacy Policy, opened in the browser.
    fileprivate var legalLinks: some View {
        HStack(spacing: Theme.Spacing.s) {
            Link("Terms of Use", destination: LegalLinks.terms)
            Text(verbatim: "·")
                .foregroundStyle(Theme.slate)
                .accessibilityHidden(true)
            Link("Privacy Policy", destination: LegalLinks.privacy)
        }
        .font(.caption.weight(.medium))
        .tint(Theme.steel)
        .underline()
    }
}

private struct FeatureRow: View {
    static let iconWidth: CGFloat = 24

    let feature: PlusFeature

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.m) {
            Image(systemName: feature.systemImage)
                .font(.body)
                .foregroundStyle(Theme.steel)
                .frame(width: Self.iconWidth)
            VStack(alignment: .leading, spacing: 2) {
                Text(feature.title)
                    .font(.stexxHeadline)
                    .foregroundStyle(Theme.frost)
                Text(feature.detail)
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
