import Foundation
import Observation

/// Background services tied to the session: location uploads, the realtime
/// socket and Stexx+ purchases. `RootView` reports sign-in and scene phase;
/// location and realtime only run while signed in and in the foreground.
@MainActor
@Observable
final class AppServices {
    let purchases: PurchaseService
    @ObservationIgnored let location: LocationService?
    @ObservationIgnored let realtime: RealtimeClient?
    @ObservationIgnored let e2e: E2EStatus

    @ObservationIgnored private let appState: AppState
    @ObservationIgnored private let chatStore: ChatStore
    @ObservationIgnored private var wasSignedIn = false
    @ObservationIgnored private var events: AsyncStream<RealtimeEvent>.Continuation?
    @ObservationIgnored private var eventTask: Task<Void, Never>?

    init(
        appState: AppState,
        chatStore: ChatStore,
        purchases: PurchaseService,
        location: LocationService?,
        realtime: RealtimeClient?,
        e2e: E2EStatus = E2EStatus(engine: nil)
    ) {
        self.appState = appState
        self.chatStore = chatStore
        self.purchases = purchases
        self.location = location
        self.realtime = realtime
        self.e2e = e2e
        if let realtime {
            // One consumer, so events are decrypted and applied in the order
            // they arrived (a ratchet message decrypts only once, and a
            // conversation update must not overtake its message).
            let (stream, continuation) = AsyncStream.makeStream(of: RealtimeEvent.self)
            events = continuation
            realtime.onEvent = { event in continuation.yield(event) }
            eventTask = Task { [weak appState, weak chatStore, e2e] in
                for await event in stream {
                    let revealed = await e2e.process(event)
                    guard let appState, let chatStore else { return }
                    chatStore.apply(revealed, myID: appState.myID)
                }
            }
        }
        // Events sent while the socket was down are never replayed: refetch
        // the list and any open thread on every (re)connect.
        realtime?.onConnected = { [weak chatStore] in
            chatStore?.resync()
        }
    }

    /// Wires everything for the app. With the mock backend there's no
    /// socket; location still runs (the mock accepts uploads).
    static func live(
        configuration: APIConfiguration,
        api: any APIClient,
        sessions: SessionCoordinator?,
        appState: AppState,
        chatStore: ChatStore,
        e2e: E2EStatus
    ) -> AppServices {
        var realtime: RealtimeClient?
        if !configuration.useMock, let sessions {
            realtime = RealtimeClient(url: configuration.realtimeURL, sessions: sessions) { refreshToken in
                try await api.refreshSession(refreshToken: refreshToken)
            }
        }
        var location: LocationService? = LocationService(api: api)
        #if DEBUG
        // Screenshot route on a live server: no location prompt over the chat.
        if ScreenshotRoute.current == .liveChat { location = nil }
        #endif
        let services = AppServices(
            appState: appState,
            chatStore: chatStore,
            purchases: PurchaseService(api: api, appState: appState),
            location: location,
            realtime: realtime,
            e2e: e2e
        )
        services.purchases.listenForTransactions()
        return services
    }

    /// For previews and tests: no location, no socket.
    static func inert(api: any APIClient, appState: AppState, chatStore: ChatStore) -> AppServices {
        AppServices(
            appState: appState,
            chatStore: chatStore,
            purchases: PurchaseService(api: api, appState: appState),
            location: nil,
            realtime: nil
        )
    }

    /// Call whenever sign-in state or scene phase changes.
    func update(isSignedIn: Bool, isForeground: Bool) {
        if isSignedIn && !wasSignedIn {
            Task { await purchases.signedIn() }
            // Sign-up, sign-in and launch: generate / upload / top up keys.
            e2e.syncKeys()
        } else if !isSignedIn && wasSignedIn {
            location?.reset()
            e2e.signedOut()
        }
        wasSignedIn = isSignedIn

        if isSignedIn && isForeground {
            location?.start()
            realtime?.start()
        } else {
            location?.stop()
            realtime?.stop()
        }
    }

    /// Returning to the foreground: catch up on anything missed while the
    /// socket was closed, and re-check the entitlement.
    func didEnterForeground() {
        guard appState.isSignedIn else { return }
        chatStore.resync()
        e2e.syncKeys()
        Task { await purchases.refreshEntitlement() }
    }
}
