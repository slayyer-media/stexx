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
/// `app` opens the whole signed-in app (tabs) on the mock backend.
/// `-StexxScreenshotPlus YES` starts any mock route with Stexx+.
///
/// `settings` opens Settings on the mock backend; `liveSettings` opens it on
/// the dev server with `-StexxDevSession` (like `liveChat`), so the privacy
/// toggles show what that server stores. `-StexxScreenshotAction` then
/// does one thing once the settings have loaded: `hideDistance` (flips that
/// toggle), `export` (Download my data), `signOut` or `delete` (opens the
/// confirmation). `-StexxMockMeDelay <seconds>` slows the mock's `GET /me`
/// (the loading state); `-StexxMockFailPrivacy YES` makes its
/// `PUT /me/privacy` fail (the rollback).
enum ScreenshotRoute: String {
    case profile, chat, reportFromChat, reportPicker, reportSent, liveChat, app, settings, liveSettings

    static var current: ScreenshotRoute? {
        UserDefaults.standard.string(forKey: "StexxScreenshotRoute").flatMap(ScreenshotRoute.init)
    }

    /// Mock routes swap in a preview `AppState`; live routes use the real one.
    var usesMockData: Bool { !isLive }

    /// On the configured dev server with an in-memory `-StexxDevSession`.
    var isLive: Bool { self == .liveChat || self == .liveSettings }

    /// Shown in place of the normal root (`app` is the normal root).
    var replacesRoot: Bool { self != .app }

    enum Action: String {
        case hideDistance, export, signOut, delete
    }

    static var action: Action? {
        UserDefaults.standard.string(forKey: "StexxScreenshotAction").flatMap(Action.init)
    }

    static var mockMeDelay: Duration {
        .seconds(max(0, UserDefaults.standard.double(forKey: "StexxMockMeDelay")))
    }

    static var mockFailsPrivacySaves: Bool { UserDefaults.standard.bool(forKey: "StexxMockFailPrivacy") }

    /// Mock routes start with Stexx+ (`-StexxScreenshotPlus YES`).
    static var startsWithPlus: Bool {
        current?.usesMockData == true && UserDefaults.standard.bool(forKey: "StexxScreenshotPlus")
    }

    static var peerID: Profile.ID? { UserDefaults.standard.string(forKey: "StexxScreenshotPeer") }
    static var draft: String? { UserDefaults.standard.string(forKey: "StexxScreenshotDraft") }

    /// A dev-server session for the live routes.
    static var devSession: Session? {
        guard current?.isLive == true,
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
        NavigationStack {
            switch route {
            case .profile:
                ProfileDetailView(profile: profile)
            case .liveChat:
                LiveChatRoute()
            case .settings, .liveSettings:
                SettingsView()
            default:
                ChatThreadView(route: ChatRoute(participant: profile))
            }
        }
        .tint(Theme.ice)
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
