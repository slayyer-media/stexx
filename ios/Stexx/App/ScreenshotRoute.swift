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
/// `paywall` / `paywallPlus` open the app with the Stexx+ paywall sheet up,
/// for a free user and for a subscriber (mock Plus, auto-renew on).
enum ScreenshotRoute: String {
    case profile, chat, reportFromChat, reportPicker, reportSent, liveChat
    case paywall, paywallPlus

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
        if route == .paywall || route == .paywallPlus {
            PaywallRoute(plus: route == .paywallPlus)
        } else {
            stack
        }
    }

    private var stack: some View {
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

/// The app with the paywall sheet up; `plus` grants mock Stexx+ first.
private struct PaywallRoute: View {
    let plus: Bool
    @Environment(AppState.self) private var appState
    @Environment(PurchaseService.self) private var purchases
    @Environment(\.apiClient) private var api

    var body: some View {
        MainTabView()
            .task {
                if plus {
                    try? await api.debugGrantPlus()
                    await purchases.refreshEntitlement()
                    // Sign-in's own status fetch may land after ours; settle on the latest.
                    try? await Task.sleep(for: .seconds(1))
                    await purchases.refreshEntitlement()
                }
                appState.isPaywallPresented = true
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
