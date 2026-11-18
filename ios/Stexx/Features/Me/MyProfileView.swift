import SwiftUI

/// The "You" tab: your profile at a glance, Stexx+, and quick privacy.
struct MyProfileView: View {
    enum Route: Hashable {
        case edit, settings, blocked
    }

    @Environment(AppState.self) private var appState
    @Environment(\.apiClient) private var api

    @State private var scroll = MeScrollTracker()

    var body: some View {
        @Bindable var bindable = appState

        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.l) {
                    header
                    plusCard
                    GlassCard {
                        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                            MeCardTitle("Quick privacy", systemImage: "lock.shield.fill")
                            Toggle("Hide my distance", isOn: $bindable.privacy.hideDistance)
                            Toggle("Show when I'm online", isOn: $bindable.privacy.showOnlineStatus)
                            PlusToggle("Incognito", isOn: $bindable.privacy.incognito)
                        }
                        .tint(Theme.violet)
                    }
                    GlassCard(padding: Theme.Spacing.s) {
                        VStack(spacing: 0) {
                            linkRow("Settings", systemImage: "gearshape", route: .settings)
                            Divider().overlay(Theme.hairline)
                            linkRow("Blocked", systemImage: "hand.raised", route: .blocked)
                            Divider().overlay(Theme.hairline)
                            Link(destination: URL(string: "https://github.com/stexxapp/stexx")!) {
                                rowLabel("Source code", systemImage: "chevron.left.forwardslash.chevron.right", trailing: "arrow.up.right")
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.bottom, Theme.Spacing.xxl)
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, offset in
                scroll.offset = offset
            }
            .scrollContentBackground(.hidden)
            .background { MeGlow(scroll: scroll) }
            .navigationTitle("You")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: Route.settings) {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .edit:
                    EditProfileView(profile: appState.me ?? MockData.me)
                case .settings:
                    SettingsView()
                case .blocked:
                    BlockedProfilesView()
                }
            }
            .task {
                if appState.me == nil { appState.me = try? await api.fetchMe() }
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        let me = appState.me ?? MockData.me
        VStack(spacing: Theme.Spacing.m) {
            ProfilePhotoView(profile: me)
                .frame(width: 136, height: 136)
                .glowFrame(cornerRadius: 68, glow: 1.6)
                .overlay(alignment: .bottomTrailing) {
                    if appState.privacy.showOnlineStatus {
                        OnlineGlow(size: 16)
                            .padding(3)
                            .background(Theme.background, in: .circle)
                            .offset(x: -6, y: -6)
                    }
                }
                .padding(.bottom, Theme.Spacing.xs)
            VStack(spacing: 6) {
                Text(me.nameAndAge)
                    .font(.stexxHero)
                    .tracking(Theme.Tracking.display)
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                if appState.hasPlus {
                    XXBadge(verbatim: "STEXX+")
                }
                if let headline = me.headline {
                    Text(headline)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
            }
            NavigationLink(value: Route.edit) {
                Label("Edit profile", systemImage: "pencil")
                    .font(.subheadline.weight(.bold))
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.violet)
        }
        .padding(.top, Theme.Spacing.l)
    }

    private var plusCard: some View {
        Button {
            appState.isPaywallPresented = true
        } label: {
            GlassCard(tint: Theme.violet.opacity(0.26)) {
                HStack(spacing: Theme.Spacing.m) {
                    StexxMark(size: 42)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: Theme.Spacing.s) {
                            Text(appState.hasPlus ? "You have Stexx+" : "Get Stexx+")
                                .font(.title3.weight(.heavy))
                                .tracking(Theme.Tracking.tight)
                                .foregroundStyle(Theme.textPrimary)
                            if appState.hasPlus {
                                XXBadge("Active")
                            }
                        }
                        Text(appState.hasPlus
                             ? "Thanks for keeping Stexx ad-free."
                             : "Incognito, travel mode, who viewed you & more. $10/mo.")
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Theme.violetBright)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Theme.violetBright.opacity(0.7), Theme.edgeGlow.opacity(0.15), Theme.violet.opacity(0.5)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .shadow(color: Theme.edgeGlow.opacity(0.3), radius: 18, y: 6)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens Stexx+")
    }

    private func linkRow(_ title: LocalizedStringKey, systemImage: String, route: Route) -> some View {
        NavigationLink(value: route) {
            rowLabel(title, systemImage: systemImage, trailing: "chevron.right")
        }
        .buttonStyle(.plain)
    }

    private func rowLabel(_ title: LocalizedStringKey, systemImage: String, trailing: String) -> some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.violetBright)
                .frame(width: 32, height: 32)
                .background(Theme.violet.opacity(0.18), in: .circle)
            Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Image(systemName: trailing)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, 10)
        .contentShape(.rect)
    }
}

/// Heavy card title with a violet glyph.
private struct MeCardTitle: View {
    let title: LocalizedStringKey
    let systemImage: String

    init(_ title: LocalizedStringKey, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Label {
            Text(title)
                .font(.headline.weight(.heavy))
                .tracking(Theme.Tracking.tight)
                .foregroundStyle(Theme.textPrimary)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(Theme.violetBright)
        }
        .accessibilityAddTraits(.isHeader)
    }
}

/// The glow behind the tab, nudged by scrolling. Reads the offset itself so
/// scrolling doesn't re-render the whole screen.
private struct MeGlow: View {
    let scroll: MeScrollTracker

    var body: some View {
        GlowBackground(intensity: 1, scrollOffset: scroll.offset)
    }
}

@MainActor @Observable
private final class MeScrollTracker {
    var offset: CGFloat = 0
}

/// A toggle for a Stexx+ feature: works normally with Stexx+, otherwise
/// shows the badge and opens the paywall instead of flipping.
struct PlusToggle: View {
    let title: LocalizedStringKey
    @Binding var isOn: Bool
    @Environment(AppState.self) private var appState

    init(_ title: LocalizedStringKey, isOn: Binding<Bool>) {
        self.title = title
        self._isOn = isOn
    }

    var body: some View {
        Toggle(isOn: Binding(
            get: { appState.hasPlus && isOn },
            set: { newValue in
                if appState.requirePlus() { isOn = newValue }
            }
        )) {
            HStack(spacing: Theme.Spacing.s) {
                Text(title)
                if !appState.hasPlus { PlusBadge() }
            }
        }
    }
}

#Preview {
    MyProfileView()
        .previewEnvironment()
}
