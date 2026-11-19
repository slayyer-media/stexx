import SwiftUI

@main
struct StexxApp: App {
    @State private var appState: AppState
    @State private var chatStore: ChatStore
    @State private var services: AppServices
    @State private var e2e: E2EStatus
    private let api: any APIClient
    private let passkeys: PasskeySupport
    /// Debug builds against a dev server: show its `/auth/register` shortcut.
    private let allowsDevSignUpShortcut: Bool

    init() {
        let configuration = APIConfiguration.fromBundle()
        // In memory for this launch, persisted to the Keychain best-effort,
        // so a failed Keychain write can't leave the app signed in without
        // a usable token.
        #if DEBUG
        // `liveChat` screenshots: a dev-server session kept in memory only;
        // the stored (Keychain) session is never read or written.
        let sessionStore = ScreenshotRoute.current == .liveChat
            ? CachedSessionStore(backing: InMemorySessionStore(session: ScreenshotRoute.devSession))
            : CachedSessionStore(backing: KeychainSessionStore())
        let appState = ScreenshotRoute.current?.usesMockData == true ? AppState.preview() : AppState(sessionStore: sessionStore)
        #else
        let sessionStore = CachedSessionStore(backing: KeychainSessionStore())
        let appState = AppState(sessionStore: sessionStore)
        #endif

        // The live client reports rotated/expired sessions and 402s here.
        let hooks = APIClientHooks(
            sessionRefreshed: { session in await appState.sessionDidRefresh(session) },
            sessionExpired: { await appState.sessionDidExpire() },
            requiresPlus: { await appState.handleRequiresPlus() }
        )
        let api: any APIClient
        let sessions: SessionCoordinator?
        let e2e: E2EStatus
        if configuration.useMock {
            // The mock backend is a server with E2E_MODE=off: plaintext chats.
            api = MockAPIClient.shared
            sessions = nil
            e2e = E2EStatus(engine: nil)
        } else {
            let coordinator = SessionCoordinator(store: sessionStore, hooks: hooks)
            let attestation = AttestationService(
                mode: AttestationService.mode(),
                baseURL: configuration.baseURL,
                apiVersion: configuration.apiVersion
            )
            let http = HTTPAPIClient(configuration: configuration, sessions: coordinator, hooks: hooks, attestation: attestation)
            // End-to-end encryption (Signal Protocol): keys in the Keychain,
            // decrypted history in an encrypted file. Follows the session.
            let secrets = KeychainSecretStorage()
            let currentUserID: @Sendable () async -> Profile.ID? = { await coordinator.currentSession?.userID }
            let engine = E2EEngine(
                api: http,
                secrets: secrets,
                history: EncryptedFileHistoryPersistence(secrets: secrets),
                currentUserID: currentUserID
            )
            api = E2EAPIClient(base: http, engine: engine, currentUserID: currentUserID)
            sessions = coordinator
            e2e = E2EStatus(engine: engine)
        }
        appState.revokeSession = { session in
            // Refreshes an expired access token with the session's own
            // refresh token and retries network failures.
            Task { await SessionRevocation.revoke(session, using: api) }
        }

        let chatStore = ChatStore(api: api)
        self.api = api
        // The system passkey sheet, or the simulated one with the mock API.
        // Unavailable (button explained) when the build can't use passkeys
        // with its server, e.g. the Local configuration on 127.0.0.1.
        self.passkeys = PasskeySupport.live(configuration)
        #if DEBUG
        self.allowsDevSignUpShortcut = !configuration.useMock
        #else
        self.allowsDevSignUpShortcut = false
        #endif
        _appState = State(initialValue: appState)
        _chatStore = State(initialValue: chatStore)
        _e2e = State(initialValue: e2e)
        _services = State(initialValue: AppServices.live(
            configuration: configuration,
            api: api,
            sessions: sessions,
            appState: appState,
            chatStore: chatStore,
            e2e: e2e
        ))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .environment(chatStore)
                .environment(services)
                .environment(services.purchases)
                .environment(e2e)
                .environment(\.apiClient, api)
                .environment(\.passkeys, passkeys)
                .environment(\.allowsDevSignUpShortcut, allowsDevSignUpShortcut)
                .preferredColorScheme(.dark)
                .tint(Theme.violet)
        }
    }
}
