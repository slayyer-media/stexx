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
                VStack(spacing: Theme.Spacing.xxl) {
                    header
                    plusRow
                    VStack(spacing: 0) {
                        SectionLabel("Quick privacy")
                            .padding(.bottom, Theme.Spacing.s)
                        MeRow { Toggle("Hide my distance", isOn: $bindable.privacy.hideDistance) }
                        HairlineDivider()
                        MeRow { Toggle("Show when I'm online", isOn: $bindable.privacy.showOnlineStatus) }
                        HairlineDivider()
                        MeRow { PlusToggle("Incognito", isOn: $bindable.privacy.incognito) }
                    }
                    .font(.stexxBody)
                    .foregroundStyle(Theme.frost)
                    .tint(Theme.ice)
                    VStack(spacing: 0) {
                        SectionLabel("More")
                            .padding(.bottom, Theme.Spacing.s)
                        linkRow("Settings", systemImage: "gearshape", route: .settings)
                        HairlineDivider(leadingInset: MeRowMetrics.iconInset)
                        linkRow("Blocked", systemImage: "hand.raised", route: .blocked)
                        HairlineDivider(leadingInset: MeRowMetrics.iconInset)
                        Link(destination: URL(string: "https://github.com/stexxapp/stexx")!) {
                            rowLabel("Source code", systemImage: "chevron.left.forwardslash.chevron.right", trailing: "arrow.up.right")
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Theme.Spacing.screen)
                .padding(.bottom, Theme.Spacing.xxl)
            }
            .collapsesTabHeaderLogo()
            .tabHeader {
                TabHeaderTitle(String(localized: "You"))
            } trailing: {
                NavigationLink(value: Route.settings) {
                    TabHeaderIconLabel(title: "Settings", systemImage: "gearshape")
                }
                .buttonStyle(.pressable)
                .padding(.trailing, -Theme.Spacing.s)
            }
            .stexxBackground()
            .navigationTitle("You")
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
        let photoShape = RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
        VStack(spacing: Theme.Spacing.l) {
            ProfilePhotoView(profile: me)
                .frame(width: 136, height: 136)
                .clipShape(photoShape)
                .hairlineBorder(photoShape)
                .rimLight(photoShape)
                .overlay(alignment: .bottomTrailing) {
                    if appState.privacy.showOnlineStatus {
                        OnlineDot()
                            .padding(Theme.Spacing.s)
                    }
                }
                .cellCorners(outset: 6)
                .padding(.top, Theme.Spacing.xl)
                .padding(.bottom, Theme.Spacing.xs)
            VStack(spacing: Theme.Spacing.s) {
                Text(me.nameAndAge)
                    .stexxTitleStyle(.display)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                if appState.hasPlus {
                    PlusBadge()
                }
                if let headline = me.headline {
                    Text(headline)
                        .font(.stexxSub)
                        .foregroundStyle(Theme.steel)
                        .multilineTextAlignment(.center)
                }
            }
            NavigationLink(value: Route.edit) {
                Label("Edit profile", systemImage: "pencil")
            }
            .buttonStyle(.stexxSecondary)
            .fixedSize()
        }
        .frame(maxWidth: .infinity)
    }

    private var plusRow: some View {
        Button {
            appState.isPaywallPresented = true
        } label: {
            VStack(spacing: 0) {
                HairlineDivider()
                HStack(spacing: Theme.Spacing.m) {
                    StexxMark(size: 28, glows: false)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: Theme.Spacing.s) {
                            Text(appState.hasPlus ? "You have Stexx+" : "Get Stexx+")
                                .font(.stexxHeadline)
                                .foregroundStyle(Theme.frost)
                            if appState.hasPlus {
                                Text("Active")
                                    .stexxLabelStyle(.micro, color: Theme.ice)
                            }
                        }
                        Text(appState.hasPlus
                             ? "Thanks for keeping Stexx ad-free."
                             : "Incognito, travel mode, who viewed you & more. $10/mo.")
                            .font(.stexxSub)
                            .foregroundStyle(Theme.steel)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.slate)
                }
                .padding(.vertical, Theme.Spacing.l)
                HairlineDivider()
            }
            .contentShape(.rect)
        }
        .buttonStyle(.pressable)
        .accessibilityHint("Opens Stexx+")
    }

    private func linkRow(_ title: LocalizedStringKey, systemImage: String, route: Route) -> some View {
        NavigationLink(value: route) {
            rowLabel(title, systemImage: systemImage, trailing: "chevron.right")
        }
        .buttonStyle(.plain)
    }

    private func rowLabel(_ title: LocalizedStringKey, systemImage: String, trailing: String) -> some View {
        MeRow {
            HStack(spacing: Theme.Spacing.m) {
                Image(systemName: systemImage)
                    .font(.body)
                    .foregroundStyle(Theme.steel)
                    .frame(width: MeRowMetrics.iconWidth)
                Text(title)
                    .font(.stexxBody)
                    .foregroundStyle(Theme.frost)
                Spacer()
                Image(systemName: trailing)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.slate)
            }
        }
        .contentShape(.rect)
    }
}

private enum MeRowMetrics {
    static let iconWidth: CGFloat = 24
    static let iconInset: CGFloat = iconWidth + Theme.Spacing.m
}

/// One row of a hairline-divided list on the plain background.
private struct MeRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
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
