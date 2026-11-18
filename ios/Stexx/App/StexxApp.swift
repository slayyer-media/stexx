import SwiftUI

@main
struct StexxApp: App {
    @State private var appState: AppState
    @State private var chatStore: ChatStore
    private let api: any APIClient

    init() {
        let api = APIConfiguration.fromBundle().makeClient()
        self.api = api
        _appState = State(initialValue: AppState())
        _chatStore = State(initialValue: ChatStore(api: api))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .environment(chatStore)
                .environment(\.apiClient, api)
                .preferredColorScheme(.dark)
                .tint(Theme.violet)
        }
    }
}
