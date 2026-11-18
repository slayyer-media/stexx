#if DEBUG
import SwiftUI

/// Debug/screenshot-only (the whole file is compiled out of Release).
/// `-StexxScreenshotRoute <name>` skips onboarding (mock session) and opens a
/// real screen backed by the mock API, so states can be captured.
enum ScreenshotRoute: String {
    case profile, chat, reportFromChat, reportPicker, reportSent

    static var current: ScreenshotRoute? {
        UserDefaults.standard.string(forKey: "StexxScreenshotRoute").flatMap(ScreenshotRoute.init)
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
            default:
                ChatThreadView(route: ChatRoute(participant: profile))
            }
        }
        .tint(Theme.ice)
    }
}
#endif
