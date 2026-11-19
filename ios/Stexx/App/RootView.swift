import SwiftUI

/// Switches between onboarding and the main app, and keeps privacy settings
/// persisted and synced wherever they are changed.
struct RootView: View {
    @Environment(AppState.self) private var appState
    @Environment(ChatStore.self) private var chatStore
    @Environment(AppServices.self) private var services
    @Environment(\.apiClient) private var api
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            #if DEBUG
            if let route = ScreenshotRoute.current, route.replacesRoot {
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
        .onOpenURL { url in
            Task { await signIn(fromEmailLink: url) }
        }
    }

    private struct SessionPhase: Equatable {
        var isSignedIn: Bool
        var isForeground: Bool
    }

    /// Email sign-in links (`…/auth/email?token=…`, universal links through
    /// the `applinks:` associated domain) exchange their token for a session.
    private func signIn(fromEmailLink url: URL) async {
        guard !appState.isSignedIn, let token = EmailSignInLink.token(from: url) else { return }
        guard let session = try? await api.verifyEmailLink(token: token) else { return }
        // The link proves the email, not age: the 18+ gate still applies.
        appState.signIn(session)
        appState.me = try? await api.fetchMe()
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
