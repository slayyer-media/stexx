import SwiftUI

/// Switches between onboarding and the main app, and keeps privacy settings
/// persisted and synced wherever they are changed.
struct RootView: View {
    @Environment(AppState.self) private var appState
    @Environment(ChatStore.self) private var chatStore
    @Environment(\.apiClient) private var api

    var body: some View {
        ZStack {
            if appState.isSignedIn {
                MainTabView()
                    .transition(.opacity)
            } else {
                OnboardingFlow()
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.4), value: appState.isSignedIn)
        .onChange(of: appState.privacy) { _, newValue in
            appState.persistPrivacy()
            Task { _ = try? await api.updatePrivacy(newValue) }
        }
        .onChange(of: appState.isSignedIn) { _, isSignedIn in
            if !isSignedIn { chatStore.reset() }
        }
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
                NearbyView()
            }
            Tab("Chats", systemImage: "bubble.left.and.bubble.right.fill", value: AppTab.chats) {
                ChatListView()
            }
            .badge(chatStore.unreadTotal)
            Tab("You", systemImage: "person.crop.circle.fill", value: AppTab.me) {
                MyProfileView()
            }
        }
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
