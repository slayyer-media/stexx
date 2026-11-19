import SwiftUI

extension View {
    /// Injects mock dependencies so any screen can be previewed in isolation.
    @MainActor
    func previewEnvironment(signedIn: Bool = true, plus: Bool = false) -> some View {
        let api = MockAPIClient(latency: .milliseconds(150), plusActive: plus)
        let appState = AppState.preview(signedIn: signedIn, plus: plus)
        let chatStore = ChatStore(api: api)
        let services = AppServices.inert(api: api, appState: appState, chatStore: chatStore)
        return self
            .environment(appState)
            .environment(chatStore)
            .environment(services)
            .environment(services.purchases)
            .environment(services.e2e)
            .environment(\.apiClient, api)
            .environment(EmailLinkRedeemer())
            .preferredColorScheme(.dark)
            .tint(Theme.violet)
    }
}
