#if DEBUG
import SwiftUI

/// Debug/screenshot-only (the whole file is compiled out of Release).
/// `-StexxScreenshotRoute <name>` skips onboarding (mock session) and opens a
/// real screen backed by the mock API, so states can be captured.
///
/// `liveChat` is the exception: it opens a real chat on the configured dev
/// server (Local scheme), for end-to-end encryption screenshots. It needs
/// `-StexxDevSession <base64 of the Session JSON>` (base64 because launch
/// arguments are parsed as property lists; kept in memory only, never
/// written to the Keychain), `-StexxScreenshotPeer <profileID>` and
/// `-stexx.ageConfirmed YES`; `-StexxScreenshotDraft <text>` sends that text
/// once the thread has loaded. See `ios/README.md`.
enum ScreenshotRoute: String {
    case profile, chat, reportFromChat, reportPicker, reportSent, liveChat
    /// Taps inbox: the tab bar (Chats badge counts new taps), the chat list
    /// with its Taps row, the list failing with nothing cached / with cached
    /// chats, and the taps screen with and without taps. Each gets its own
    /// fresh mock backend.
    case tabs, chatList, chatListError, chatListStale, taps, tapsEmpty

    static var current: ScreenshotRoute? {
        UserDefaults.standard.string(forKey: "StexxScreenshotRoute").flatMap(ScreenshotRoute.init)
    }

    /// Mock routes swap in a preview `AppState`; `liveChat` uses the real one.
    var usesMockData: Bool { self != .liveChat }

    static var peerID: Profile.ID? { UserDefaults.standard.string(forKey: "StexxScreenshotPeer") }
    static var draft: String? { UserDefaults.standard.string(forKey: "StexxScreenshotDraft") }

    /// A dev-server session for `liveChat`.
    static var devSession: Session? {
        guard current == .liveChat,
              let encoded = UserDefaults.standard.string(forKey: "StexxDevSession"),
              let json = Data(base64Encoded: encoded)
        else { return nil }
        return try? JSONDecoder.stexx().decode(Session.self, from: json)
    }
}

struct ScreenshotRouteView: View {
    let route: ScreenshotRoute
    private let profile = MockData.profiles[0]

    var body: some View {
        switch route {
        case .tabs:
            MockChatsRoute { MainTabView() }
        case .chatList:
            MockChatsRoute { ChatListView() }
        case .chatListError:
            MockChatsRoute(setup: { api, _ in await api.setFailsConversationList(true) }) { ChatListView() }
        case .chatListStale:
            MockChatsRoute(setup: { api, store in
                await store.load()
                await api.setFailsConversationList(true)
                await store.load()
            }) { ChatListView() }
        case .taps, .tapsEmpty:
            MockChatsRoute(setup: { api, _ in
                if route == .tapsEmpty { await api.removeAllTaps() }
            }) {
                NavigationStack {
                    TapsView()
                        .navigationDestination(for: Profile.self) { ProfileDetailView(profile: $0) }
                }
                .tint(Theme.ice)
            }
        default:
            legacyRoutes
        }
    }

    private var legacyRoutes: some View {
        NavigationStack {
            switch route {
            case .profile:
                ProfileDetailView(profile: profile)
            case .liveChat:
                LiveChatRoute()
            default:
                ChatThreadView(route: ChatRoute(participant: profile))
            }
        }
        .tint(Theme.ice)
    }
}

/// A fresh mock backend and chat store for one screenshot: `setup` runs
/// before the screen appears (and before its first load).
private struct MockChatsRoute<Content: View>: View {
    var setup: @MainActor (MockAPIClient, ChatStore) async -> Void = { _, _ in }
    @ViewBuilder let content: () -> Content

    @State private var api = MockAPIClient(latency: .milliseconds(100))
    @State private var store: ChatStore?

    var body: some View {
        if let store {
            content()
                .environment(store)
                .environment(\.apiClient, api)
        } else {
            Color.clear
                .task {
                    let store = ChatStore(api: api)
                    await setup(api, store)
                    self.store = store
                }
        }
    }
}

/// Opens the chat with `-StexxScreenshotPeer` on the real (dev) server.
private struct LiveChatRoute: View {
    @Environment(\.apiClient) private var api
    @State private var conversation: Conversation?

    var body: some View {
        if let conversation {
            ChatThreadView(route: ChatRoute(participant: conversation.participant, conversationID: conversation.id))
        } else {
            ProgressView()
                .task {
                    guard let peer = ScreenshotRoute.peerID else { return }
                    conversation = try? await api.openConversation(with: peer)
                }
        }
    }
}
#endif
