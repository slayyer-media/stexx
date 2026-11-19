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
enum ScreenshotRoute: String {
    case profile, chat, chats, reportFromChat, reportPicker, reportSent, liveChat, settings

    static var current: ScreenshotRoute? {
        UserDefaults.standard.string(forKey: "StexxScreenshotRoute").flatMap(ScreenshotRoute.init)
    }

    /// Mock routes swap in a preview `AppState`; `liveChat` uses the real one.
    var usesMockData: Bool { self != .liveChat }

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
    /// `-StexxScreenshotPeer` picks the mock profile for mock routes too.
    private var profile: Profile {
        ScreenshotRoute.peerID.flatMap { id in MockData.profiles.first { $0.id == id } } ?? MockData.profiles[0]
    }

    var body: some View {
        if route == .chats {
            // The Chats tab has its own NavigationStack.
            ChatListView()
                .tint(Theme.ice)
        } else {
            NavigationStack {
                switch route {
                case .profile:
                    ProfileDetailView(profile: profile)
                case .liveChat:
                    LiveChatRoute()
                case .settings:
                    SettingsView()
                default:
                    ChatThreadView(route: ChatRoute(participant: profile))
                }
            }
            .tint(Theme.ice)
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
