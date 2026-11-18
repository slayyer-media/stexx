import SwiftUI

/// The "You" tab: your profile at a glance, Stexx+, and quick privacy.
struct MyProfileView: View {
    enum Route: Hashable {
        case edit, settings, blocked
    }

    @Environment(AppState.self) private var appState
    @Environment(\.apiClient) private var api

    var body: some View {
        @Bindable var bindable = appState

        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.l) {
                    header
                    plusCard
                    GlassCard {
                        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                            SectionLabel("Quick privacy")
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
            .stexxBackground()
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
                .frame(width: 128, height: 128)
                .clipShape(.circle)
                .overlay(Circle().strokeBorder(Theme.violet.opacity(0.5), lineWidth: 1.5))
                .shadow(color: Theme.violet.opacity(0.45), radius: 24)
            VStack(spacing: 4) {
                Text(me.nameAndAge)
                    .font(.stexxTitle)
                if let headline = me.headline {
                    Text(headline)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
            }
            NavigationLink(value: Route.edit) {
                Label("Edit profile", systemImage: "pencil")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.glass)
        }
        .padding(.top, Theme.Spacing.l)
    }

    private var plusCard: some View {
        Button {
            appState.isPaywallPresented = true
        } label: {
            GlassCard(tint: Theme.violet.opacity(0.22)) {
                HStack(spacing: Theme.Spacing.m) {
                    StexxMark(size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(appState.hasPlus ? "You have Stexx+" : "Get Stexx+")
                            .font(.stexxHeadline)
                            .foregroundStyle(Theme.textPrimary)
                        Text(appState.hasPlus
                             ? "Thanks for keeping Stexx ad-free."
                             : "Incognito, travel mode, who viewed you & more. $10/mo.")
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .buttonStyle(.plain)
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
                .foregroundStyle(Theme.violetBright)
                .frame(width: 24)
            Text(title)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Image(systemName: trailing)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, 14)
        .contentShape(.rect)
    }
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
