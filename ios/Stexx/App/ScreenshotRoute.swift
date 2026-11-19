#if DEBUG
import SwiftUI
import UIKit

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
/// once the thread has loaded. `-StexxScreenshotSendPhoto viewOnce` sends a
/// generated test photo as view-once (through the normal photo path, so
/// encrypted when the chat is). `-StexxScreenshotViewOnce open` opens the
/// newest incoming view-once photo in the viewer (`openAndClose` closes it
/// again once it counts as opened). `-StexxShowPrivacyCover YES` keeps the
/// app-switcher cover up (`PrivacyCover`). See `ios/README.md`.
///
/// `app` opens the whole signed-in app (tabs) on the mock backend.
/// `-StexxScreenshotPlus YES` starts any mock route with Stexx+.
///
/// `me` opens the You tab with no profile loaded yet, so it shows the real
/// fetch (pair it with `-StexxMockFail fetchMe=offline` or `fetchMe=hang`);
/// `filters` opens the filter sheet over Nearby with filters already applied.
///
/// `paywall` / `paywallPlus` open the app with the Stexx+ paywall sheet up,
/// for a free user and for a subscriber (mock Plus, auto-renew on).
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
    /// Chats tab alone on the shared mock backend (chat-polish screenshots:
    /// muted rows and the badge).
    case chats
    /// Taps inbox: the tab bar (Chats badge counts new taps), the chat list
    /// with its Taps row, the list failing with nothing cached / with cached
    /// chats, and the taps screen with and without taps. Each gets its own
    /// fresh mock backend. `chatListOffline` fails chats and taps both, as
    /// on a cold launch with the server down.
    case tabs, chatList, chatListError, chatListStale, chatListOffline, taps, tapsEmpty
    case me, filters
    case paywall, paywallPlus

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
    /// `-StexxScreenshotScrollToTop YES`: a thread jumps to its oldest loaded
    /// message once loaded, so the next older page starts loading.
    static var scrollsToTop: Bool { UserDefaults.standard.bool(forKey: "StexxScreenshotScrollToTop") }
    /// `-StexxScreenshotPhotoTimer <PhotoTimer raw value>`: the thread's photo timer.
    static var photoTimer: PhotoTimer? {
        UserDefaults.standard.string(forKey: "StexxScreenshotPhotoTimer").flatMap(PhotoTimer.init(rawValue:))
    }
    /// `-StexxMockSendFailure <kind>`: the mock refuses every send the way the
    /// server would (`rateLimited`, `newAccountLimit`, `linksNotAllowed`,
    /// `underReview`, `offline`), so failed bubbles can be captured.
    static var mockSendFailure: String? { UserDefaults.standard.string(forKey: "StexxMockSendFailure") }
    /// `-StexxMockOlderPageDelay <seconds>`: the mock takes this long for an
    /// older page, so the loading row can be captured.
    static var mockOlderPageDelay: Double { UserDefaults.standard.double(forKey: "StexxMockOlderPageDelay") }
    static var draft: String? { UserDefaults.standard.string(forKey: "StexxScreenshotDraft") }
    /// `viewOnce`: send a generated photo as view-once once the thread loads.
    static var sendsViewOncePhoto: Bool { UserDefaults.standard.string(forKey: "StexxScreenshotSendPhoto") == "viewOnce" }

    enum ViewOnceAction: String {
        case open, openAndClose
    }

    static var viewOnceAction: ViewOnceAction? {
        UserDefaults.standard.string(forKey: "StexxScreenshotViewOnce").flatMap(ViewOnceAction.init)
    }

    /// A harmless generated test photo (no real image).
    static func samplePhotoJPEG() -> Data? {
        let size = CGSize(width: 900, height: 1200)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let colors = [UIColor(red: 0.29, green: 0.18, blue: 0.62, alpha: 1).cgColor,
                          UIColor(red: 0.07, green: 0.55, blue: 0.68, alpha: 1).cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            UIColor.white.withAlphaComponent(0.85).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 250, y: 360, width: 400, height: 400))
        }
        return image.jpegData(compressionQuality: 0.85)
    }

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
    /// `-StexxScreenshotPeer` picks the mock profile for mock routes too.
    private var profile: Profile {
        ScreenshotRoute.peerID.flatMap { id in MockData.profiles.first { $0.id == id } } ?? MockData.profiles[0]
    }

    var body: some View {
        switch route {
        case .tabs:
            MockChatsRoute { MainTabView() }
        case .chatList:
            MockChatsRoute { ChatListView() }
        case .chatListError:
            MockChatsRoute(setup: { api, _ in await api.setFailsConversationList(true) }) { ChatListView() }
        case .chatListOffline:
            MockChatsRoute(setup: { api, _ in
                await api.setFailsConversationList(true)
                await api.setFailsTaps(true)
            }) { ChatListView() }
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
        case .chats:
            // The Chats tab has its own NavigationStack.
            ChatListView().tint(Theme.ice)
        case .me:
            // Has its own NavigationStack.
            MyProfileView().tint(Theme.ice)
        case .filters:
            FiltersRoute().tint(Theme.ice)
        case .paywall, .paywallPlus:
            PaywallRoute(plus: route == .paywallPlus)
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
            case .settings, .liveSettings:
                SettingsView()
            default:
                ChatThreadView(route: ChatRoute(participant: profile))
            }
        }
        .tint(Theme.ice)
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
