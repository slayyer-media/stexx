import SwiftUI

/// Switches between onboarding and the main app, and keeps privacy settings
/// persisted and synced wherever they are changed.
struct RootView: View {
    @Environment(AppState.self) private var appState
    @Environment(ChatStore.self) private var chatStore
    @Environment(AppServices.self) private var services
    @Environment(\.apiClient) private var api
    @Environment(\.scenePhase) private var scenePhase
    @State private var linkRedeemer = EmailLinkRedeemer()

    var body: some View {
        ZStack {
            #if DEBUG
            if let route = ScreenshotRoute.current {
                ScreenshotRouteView(route: route)
            } else if appState.isSignedIn {
                MainTabView()
                    .transition(.opacity)
            } else {
                OnboardingFlow()
                    .transition(.opacity)
            }
            #else
            if appState.isSignedIn {
                MainTabView()
                    .transition(.opacity)
            } else {
                OnboardingFlow()
                    .transition(.opacity)
            }
            #endif
        }
        .environment(linkRedeemer)
        .animation(.smooth(duration: 0.4), value: appState.isSignedIn)
        .onChange(of: appState.privacy) { _, newValue in
            appState.persistPrivacy()
            guard appState.isSignedIn else { return }
            Task { _ = try? await api.updatePrivacy(newValue) }
        }
        .onChange(of: appState.isSignedIn) { _, isSignedIn in
            if !isSignedIn { chatStore.reset() }
        }
        // Location and the realtime socket only run while signed in and in
        // the foreground.
        .onChange(of: SessionPhase(isSignedIn: appState.isSignedIn, isForeground: scenePhase == .active), initial: true) { old, new in
            services.update(isSignedIn: new.isSignedIn, isForeground: new.isForeground)
            if new.isForeground && !old.isForeground { services.didEnterForeground() }
        }
        // Universal links (`applinks:`) arrive here too in the SwiftUI life cycle.
        .onOpenURL(perform: open)
        .overlay {
            if linkRedeemer.state == .verifying {
                EmailLinkVerifyingOverlay()
                    .transition(.opacity)
            }
        }
        .sheet(isPresented: needsAgeConfirmation) {
            NavigationStack {
                AgeGateView {
                    linkRedeemer.ageConfirmed()
                    redeemLink()
                }
            }
            .tint(Theme.ice)
        }
        .sheet(isPresented: linkFailed) {
            if case .failed(let problem) = linkRedeemer.state {
                EmailLinkProblemView(
                    problem: problem,
                    isSignedIn: appState.isSignedIn,
                    onRetry: linkRedeemer.canRetry && !appState.isSignedIn ? {
                        linkRedeemer.retry()
                        redeemLink()
                    } : nil
                ) { followUp in
                    linkRedeemer.dismiss(followUp: followUp)
                }
                .presentationDetents([.medium])
            }
        }
        .alert("You're already signed in", isPresented: alreadySignedIn) {
            Button("OK") { linkRedeemer.dismiss() }
        } message: {
            Text("Sign-in links are for getting into your account on a new iPhone. To switch accounts, sign out in Settings first, then open the link again.")
        }
        #if DEBUG
        // Screenshots and UI checks: `-StexxOpenURL <url>` opens a link at launch, like a tap in Mail would.
        .task {
            if let string = UserDefaults.standard.string(forKey: "StexxOpenURL"), let url = URL(string: string) {
                open(url)
            }
        }
        #endif
    }

    private struct SessionPhase: Equatable {
        var isSignedIn: Bool
        var isForeground: Bool
    }

    /// Email sign-in links (`…/auth/email?token=…`, universal links through
    /// the `applinks:` associated domain) exchange their token for a session,
    /// after the 18+ gate on a new iPhone. Never while signed in.
    private func open(_ url: URL) {
        guard linkRedeemer.handle(url, isSignedIn: appState.isSignedIn, isAgeConfirmed: appState.isAgeConfirmed) else { return }
        redeemLink()
    }

    private func redeemLink() {
        guard linkRedeemer.state == .verifying else { return }
        Task {
            guard let session = await linkRedeemer.redeem(with: api) else { return }
            appState.signIn(session)
            appState.me = try? await api.fetchMe()
        }
    }

    private var needsAgeConfirmation: Binding<Bool> {
        Binding(
            get: { linkRedeemer.state == .needsAgeConfirmation },
            set: { if !$0, linkRedeemer.state == .needsAgeConfirmation { linkRedeemer.dismiss() } }
        )
    }

    private var linkFailed: Binding<Bool> {
        Binding(
            get: { if case .failed = linkRedeemer.state { true } else { false } },
            set: { if !$0, case .failed = linkRedeemer.state { linkRedeemer.dismiss() } }
        )
    }

    private var alreadySignedIn: Binding<Bool> {
        Binding(
            get: { linkRedeemer.state == .alreadySignedIn },
            set: { if !$0, linkRedeemer.state == .alreadySignedIn { linkRedeemer.dismiss() } }
        )
    }
}

/// The three main tabs, on the system Liquid Glass tab bar.
struct MainTabView: View {
    enum AppTab: Hashable {
        case nearby, chats, me
    }

    @Environment(AppState.self) private var appState
    @Environment(ChatStore.self) private var chatStore
    @Environment(\.apiClient) private var api
    @State private var selection: AppTab = .nearby

    var body: some View {
        @Bindable var bindable = appState

        TabView(selection: $selection) {
            Tab("Nearby", systemImage: "square.grid.3x3.fill", value: AppTab.nearby) {
                NearbyView().tint(Theme.ice)
            }
            Tab("Chats", systemImage: "bubble.left.and.bubble.right.fill", value: AppTab.chats) {
                ChatListView().tint(Theme.ice)
            }
            .badge(chatStore.unreadTotal)
            Tab("You", systemImage: "person.crop.circle.fill", value: AppTab.me) {
                MyProfileView().tint(Theme.ice)
            }
        }
        // Selected tab in frost (violet is lighting only); tab content keeps
        // the app-wide cool ice tint.
        .tint(Theme.frost)
        .tabBarMinimizeBehavior(.onScrollDown)
        .sheet(isPresented: $bindable.isPaywallPresented) {
            PaywallView()
        }
        .task {
            await chatStore.loadIfNeeded()
            if appState.me == nil {
                appState.me = try? await api.fetchMe()
            }
        }
    }
}

#Preview("Main") {
    MainTabView()
        .previewEnvironment()
}

#Preview("Onboarding") {
    RootView()
        .previewEnvironment(signedIn: false)
}
