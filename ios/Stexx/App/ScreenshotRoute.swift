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
///
/// `me` opens the You tab with no profile loaded yet, so it shows the real
/// fetch (pair it with `-StexxMockFail fetchMe=offline` or `fetchMe=hang`);
/// `filters` opens the filter sheet over Nearby with filters already applied.
enum ScreenshotRoute: String {
    case profile, chat, reportFromChat, reportPicker, reportSent, liveChat
    case me, filters

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
        case .me:
            // Has its own NavigationStack.
            MyProfileView().tint(Theme.ice)
        case .filters:
            FiltersRoute().tint(Theme.ice)
        default:
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
}

/// The filter sheet over Nearby, with ages 21–35 and Vers applied.
private struct FiltersRoute: View {
    @State private var query: NearbyQuery = {
        var query = NearbyQuery()
        query.minAge = 21
        query.maxAge = 35
        query.positions = [.versatile]
        return query
    }()
    @State private var isPresented = true

    var body: some View {
        NearbyView()
            .sheet(isPresented: $isPresented) {
                FilterSheet(query: $query)
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
