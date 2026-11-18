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

    @ObservationIgnored private let appState: AppState
    @ObservationIgnored private let chatStore: ChatStore
    @ObservationIgnored private var wasSignedIn = false

    init(
        appState: AppState,
        chatStore: ChatStore,
        purchases: PurchaseService,
        location: LocationService?,
        realtime: RealtimeClient?
    ) {
        self.appState = appState
        self.chatStore = chatStore
        self.purchases = purchases
        self.location = location
        self.realtime = realtime
        realtime?.onEvent = { [weak appState, weak chatStore] event in
            guard let appState, let chatStore else { return }
            chatStore.apply(event, myID: appState.myID)
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
        chatStore: ChatStore
    ) -> AppServices {
        var realtime: RealtimeClient?
        if !configuration.useMock, let sessions {
            realtime = RealtimeClient(url: configuration.realtimeURL, sessions: sessions) { refreshToken in
                try await api.refreshSession(refreshToken: refreshToken)
            }
        }
        let services = AppServices(
            appState: appState,
            chatStore: chatStore,
            purchases: PurchaseService(api: api, appState: appState),
            location: LocationService(api: api),
            realtime: realtime
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
        } else if !isSignedIn && wasSignedIn {
            location?.reset()
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
        Task { await purchases.refreshEntitlement() }
    }
}
