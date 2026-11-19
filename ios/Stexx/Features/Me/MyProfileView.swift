import SwiftUI

/// The "You" tab: your profile at a glance, Stexx+, and quick privacy.
struct MyProfileView: View {
    enum Route: Hashable {
        case settings, blocked
    }

    @Environment(AppState.self) private var appState
    @Environment(PurchaseService.self) private var purchases
    @Environment(\.apiClient) private var api

    /// Why the last `fetchMe` failed, shown until a retry succeeds.
    @State private var loadError: String?
    @State private var isLoading = false
    /// The profile being edited (a snapshot of the loaded one).
    @State private var editing: Profile?

    private var loadState: MyProfileLoadState {
        MyProfileLoadState(me: appState.me, loadError: loadError)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.xxl) {
                    header
                    plusRow
                    VStack(spacing: 0) {
                        SectionLabel("Quick privacy")
                            .padding(.bottom, Theme.Spacing.s)
                        MeRow { Toggle("Hide my distance", isOn: appState.privacyBinding(\.hideDistance)) }
                        HairlineDivider()
                        MeRow { Toggle("Show when I'm online", isOn: appState.privacyBinding(\.showOnlineStatus)) }
                        HairlineDivider()
                        MeRow { PlusToggle("Incognito", isOn: appState.privacyBinding(\.incognito)) }
                        if let privacyError = appState.privacyError {
                            Text(privacyError)
                                .font(.stexxSub)
                                .foregroundStyle(Theme.danger)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, Theme.Spacing.s)
                        }
                    }
                    .disabled(!appState.isPrivacyEditable)
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
                case .settings:
                    SettingsView()
                case .blocked:
                    BlockedProfilesView()
                }
            }
            .sheet(item: $editing) { profile in
                NavigationStack {
                    EditProfileView(profile: profile)
                }
            }
            .task {
                // Also when only the privacy settings failed to load: setting
                // `me` adopts them (`AppState.adoptServerPrivacy`).
                if appState.me == nil || appState.privacyStatus == .unavailable { await loadMe() }
            }
        }
    }

    /// Fetches your profile. Never falls back to sample data: until the real
    /// profile arrives the tab shows a skeleton, or an error with Retry.
    private func loadMe() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        switch await Self.load(api: api, appState: appState, purchases: purchases) {
        case .loaded:
            loadError = nil
        case .failed(let message):
            loadError = message
        case .unchanged:
            break
        }
    }

    enum LoadOutcome: Equatable {
        case loaded
        case failed(String)
        /// Cancelled, or another fetch (the tab bar's) won meanwhile.
        case unchanged
    }

    /// Fetches `me` and, once it arrives, re-checks Stexx+. `hasPlus` isn't
    /// persisted and is otherwise only re-checked at sign-in and on
    /// foreground, so after a launch while offline a subscriber would stay
    /// "free" even once Retry brought the profile back.
    static func load(api: any APIClient, appState: AppState, purchases: PurchaseService) async -> LoadOutcome {
        do {
            appState.me = try await api.fetchMe()
        } catch {
            // The heading already says "Couldn't load your profile".
            guard let message = UserFacingError.message(for: error) else { return .unchanged }
            return appState.me == nil ? .failed(message) : .unchanged
        }
        await purchases.refreshEntitlement()
        return .loaded
    }

    @ViewBuilder
    private var header: some View {
        switch loadState {
        case .loaded(let me):
            loadedHeader(me)
        case .loading:
            MyProfileSkeleton(editButton: editButton)
        case .failed(let message):
            loadFailed(message)
        }
    }

    private var editButton: some View {
        Button {
            editing = appState.me
        } label: {
            Label("Edit profile", systemImage: "pencil")
        }
        .buttonStyle(.stexxSecondary)
        .fixedSize()
        .disabled(!loadState.canEdit)
    }

    private func loadFailed(_ message: String) -> some View {
        VStack(spacing: Theme.Spacing.l) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(Theme.steel)
                .frame(width: 136, height: 136)
                .background(Theme.ink1, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                .hairlineBorder(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                .cellCorners(outset: 6)
                .padding(.top, Theme.Spacing.xl)
                .padding(.bottom, Theme.Spacing.xs)
                .accessibilityHidden(true)
            VStack(spacing: Theme.Spacing.s) {
                Text("Couldn't load your profile")
                    .stexxTitleStyle(.title)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(message)
                    .font(.stexxSub)
                    .foregroundStyle(Theme.steel)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: Theme.Spacing.s) {
                Button {
                    Task { await loadMe() }
                } label: {
                    if isLoading {
                        ProgressView().tint(Theme.ink)
                    } else {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.stexxPrimary)
                .fixedSize()
                .disabled(isLoading)
                editButton
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func loadedHeader(_ me: Profile) -> some View {
        let photoShape = RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
        VStack(spacing: Theme.Spacing.l) {
            // The photo others see first (an explicit one is hidden from them).
            ProfilePhotoView(profile: me, photoIndex: me.photos.firstIndex { !$0.isExplicit } ?? 0)
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
            editButton
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

/// What the header of the You tab shows. Editing needs the real profile:
/// there is no sample-data fallback that could be saved over the account.
enum MyProfileLoadState: Equatable {
    case loading
    case failed(String)
    case loaded(Profile)

    init(me: Profile?, loadError: String?) {
        if let me {
            self = .loaded(me)
        } else if let loadError {
            self = .failed(loadError)
        } else {
            self = .loading
        }
    }

    /// Edit is enabled only once the real profile has loaded.
    var canEdit: Bool {
        if case .loaded = self { return true }
        return false
    }
}

/// Placeholder shapes in the header's layout while the profile loads.
/// Static (no shimmer: the design language has no pulsing).
private struct MyProfileSkeleton<EditButton: View>: View {
    let editButton: EditButton

    var body: some View {
        let photoShape = RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
        VStack(spacing: Theme.Spacing.l) {
            photoShape
                .fill(Theme.ink1)
                .frame(width: 136, height: 136)
                .hairlineBorder(photoShape)
                .overlay { ProgressView().tint(Theme.steel) }
                .cellCorners(outset: 6)
                .padding(.top, Theme.Spacing.xl)
                .padding(.bottom, Theme.Spacing.xs)
            VStack(spacing: Theme.Spacing.s) {
                Capsule().fill(Theme.ink2).frame(width: 150, height: 30)
                Capsule().fill(Theme.ink1).frame(width: 200, height: 14)
            }
            .accessibilityHidden(true)
            editButton
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Loading your profile")
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
extension AppState {
    /// A toggle binding for one privacy setting: reads the current value and
    /// saves changes through `setPrivacy` (rolled back if the save fails).
    func privacyBinding(_ setting: WritableKeyPath<PrivacySettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { self.privacy[keyPath: setting] },
            set: { self.setPrivacy(setting, to: $0) }
        )
    }
}

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
