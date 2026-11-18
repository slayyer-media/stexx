import SwiftUI

extension View {
    /// Injects mock dependencies so any screen can be previewed in isolation.
    @MainActor
    func previewEnvironment(signedIn: Bool = true, plus: Bool = false) -> some View {
        let api = MockAPIClient(latency: .milliseconds(150))
        return self
            .environment(AppState.preview(signedIn: signedIn, plus: plus))
            .environment(ChatStore(api: api))
            .environment(\.apiClient, api)
            .preferredColorScheme(.dark)
            .tint(Theme.violet)
    }
}
