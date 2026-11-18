import SwiftUI

@main
struct StexxApp: App {
    @State private var appState: AppState
    @State private var chatStore: ChatStore
    @State private var services: AppServices
    private let api: any APIClient

    init() {
        let configuration = APIConfiguration.fromBundle()
        // In memory for this launch, persisted to the Keychain best-effort,
        // so a failed Keychain write can't leave the app signed in without
        // a usable token.
        let sessionStore = CachedSessionStore(backing: KeychainSessionStore())
        let appState = AppState(sessionStore: sessionStore)

        // The live client reports rotated/expired sessions and 402s here.
        let hooks = APIClientHooks(
            sessionRefreshed: { session in await appState.sessionDidRefresh(session) },
            sessionExpired: { await appState.sessionDidExpire() },
            requiresPlus: { await appState.handleRequiresPlus() }
        )
        let api: any APIClient
        let sessions: SessionCoordinator?
        if configuration.useMock {
            api = MockAPIClient.shared
            sessions = nil
        } else {
            let coordinator = SessionCoordinator(store: sessionStore, hooks: hooks)
            let attestation = AttestationService(
                mode: AttestationService.mode(),
                baseURL: configuration.baseURL,
                apiVersion: configuration.apiVersion
            )
            api = HTTPAPIClient(configuration: configuration, sessions: coordinator, hooks: hooks, attestation: attestation)
            sessions = coordinator
        }
        appState.revokeSession = { session in
            // Refreshes an expired access token with the session's own
            // refresh token and retries network failures.
            Task { await SessionRevocation.revoke(session, using: api) }
        }

        let chatStore = ChatStore(api: api)
        self.api = api
        _appState = State(initialValue: appState)
        _chatStore = State(initialValue: chatStore)
        _services = State(initialValue: AppServices.live(
            configuration: configuration,
            api: api,
            sessions: sessions,
            appState: appState,
            chatStore: chatStore
        ))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .environment(chatStore)
                .environment(services)
                .environment(services.purchases)
                .environment(\.apiClient, api)
                .preferredColorScheme(.dark)
                .tint(Theme.violet)
        }
    }
}
