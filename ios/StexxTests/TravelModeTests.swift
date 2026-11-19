import Foundation
import Testing
@testable import Stexx

/// Records `PUT /me/travel` bodies and fails on demand.
private actor TravelSpy {
    private(set) var sent: [FuzzedLocation?] = []
    var failure: (any Error)?

    func fail(with error: (any Error)?) { failure = error }

    func send(_ location: FuzzedLocation?) throws {
        if let failure { throw failure }
        sent.append(location)
    }
}

/// Names cells without MapKit, recording what it was asked.
private final class FakeNaming: TravelPlaceNaming, @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [FuzzedLocation] = []
    let answer: TravelPlaceName?

    init(answer: TravelPlaceName? = TravelPlaceName(city: "Lisbon, Portugal", region: "Portugal")) { self.answer = answer }

    var cells: [FuzzedLocation] { lock.withLock { asked } }

    @MainActor
    func name(for cell: FuzzedLocation) async -> TravelPlaceName? {
        lock.withLock { asked.append(cell) }
        return answer
    }
}

@MainActor
struct TravelModeTests {
    /// A precise point well inside a cell (Lisbon).
    private let precise = TravelModeModel.Point(latitude: 38.7223456, longitude: -9.1393456)

    private func makeState(plus: Bool, suite: String = "stexx.tests.travel.\(UUID().uuidString)") -> AppState {
        let state = AppState(
            defaults: UserDefaults(suiteName: suite)!,
            sessionStore: InMemorySessionStore(),
            travelStore: InMemoryTravelPlaceStore()
        )
        state.signIn(MockData.session)
        state.me = MockData.me
        state.hasPlus = plus
        return state
    }

    /// A file store in a fresh temporary directory.
    private func makeFileStore() -> FileTravelPlaceStore {
        FileTravelPlaceStore(directory: URL.temporaryDirectory.appending(path: "stexx-travel-\(UUID().uuidString)", directoryHint: .isDirectory))
    }

    private func makeModel(_ state: AppState, spy: TravelSpy, naming: FakeNaming = FakeNaming()) -> TravelModeModel {
        TravelModeModel(appState: state, setTravelLocation: { try await spy.send($0) }, naming: naming)
    }

    // MARK: Fuzzing

    @Test("Turning it on sends the 500 m cell around the map center, never the center itself")
    func fuzzesBeforeSending() async throws {
        let state = makeState(plus: true)
        let spy = TravelSpy()
        let model = makeModel(state, spy: spy)
        model.centerChanged(to: precise)
        await model.nameSelection(after: .zero)
        let revision = state.travelRevision

        #expect(await model.browseFromSelection())

        let expected = LocationFuzzer.fuzz(latitude: precise.latitude, longitude: precise.longitude)
        let sent = try #require(await spy.sent.first ?? nil)
        #expect(await spy.sent.count == 1)
        #expect(sent == expected)
        #expect(sent.precisionMeters == LocationFuzzer.defaultCellMeters)
        #expect(sent.latitude != precise.latitude)
        #expect(sent.longitude != precise.longitude)
        // The app remembers the sent cell and the on-device name, not the center.
        #expect(state.travel == TravelPlace(location: expected, name: "Lisbon, Portugal"))
        #expect(state.isTravelActive)
        #expect(state.travelRevision > revision)
        #expect(state.me?.travel == TravelStatus(isActive: true))
        #expect(model.isCurrentPlace)
    }

    @Test("Place names are looked up for the fuzzed cell only")
    func namesTheCell() async {
        let state = makeState(plus: true)
        let naming = FakeNaming()
        let model = makeModel(state, spy: TravelSpy(), naming: naming)
        model.centerChanged(to: precise)
        #expect(model.isNaming)
        await model.nameSelection(after: .zero)
        #expect(naming.cells == [LocationFuzzer.fuzz(latitude: precise.latitude, longitude: precise.longitude)])
        #expect(model.placeName == "Lisbon, Portugal")
        #expect(!model.isNaming)

        // Panning within the same cell keeps the name; leaving it drops it.
        model.centerChanged(to: .init(latitude: precise.latitude + 0.00001, longitude: precise.longitude))
        #expect(model.placeName == "Lisbon, Portugal")
        model.centerChanged(to: .init(latitude: precise.latitude + 0.05, longitude: precise.longitude))
        #expect(model.placeName == nil)
    }

    @Test("A searched place keeps its name where the lookup finds no city; otherwise the city wins")
    func searchedNames() async {
        let state = makeState(plus: true)
        let water = makeModel(state, spy: TravelSpy(), naming: FakeNaming(answer: TravelPlaceName(city: nil, region: "Portugal")))
        water.centerChanged(to: precise, spanMeters: 4000)
        water.suggestName("Lisbon")
        await water.nameSelection(after: .zero)
        #expect(water.placeName == "Lisbon")

        // Panned away from the searched cell: the region is all there is.
        water.centerChanged(to: .init(latitude: precise.latitude - 0.02, longitude: precise.longitude))
        await water.nameSelection(after: .zero)
        #expect(water.placeName == "Portugal")

        let city = makeModel(state, spy: TravelSpy(), naming: FakeNaming())
        city.centerChanged(to: precise, spanMeters: 4000)
        city.suggestName("Lisbon")
        await city.nameSelection(after: .zero)
        #expect(city.placeName == "Lisbon, Portugal")
    }

    @Test("Without a map position nothing is sent")
    func needsASelection() async {
        let state = makeState(plus: true)
        let spy = TravelSpy()
        let model = makeModel(state, spy: spy)
        #expect(model.selection == nil)
        #expect(await !model.browseFromSelection())
        #expect(await spy.sent.isEmpty)
        #expect(state.travel == nil)
    }

    @Test("Zoomed out to a continent, nothing can be picked or looked up")
    func zoomGate() async {
        let state = makeState(plus: true)
        let spy = TravelSpy()
        let naming = FakeNaming()
        let model = makeModel(state, spy: spy, naming: naming)
        model.centerChanged(to: precise, spanMeters: 5_000_000)
        #expect(model.isZoomedOut)
        #expect(model.selection == nil)
        await model.nameSelection(after: .zero)
        #expect(naming.cells.isEmpty)
        #expect(await !model.browseFromSelection())
        #expect(await spy.sent.isEmpty)

        model.centerChanged(to: precise, spanMeters: 4000)
        #expect(!model.isZoomedOut)
        #expect(model.selection == LocationFuzzer.fuzz(latitude: precise.latitude, longitude: precise.longitude))
    }

    // MARK: Plus gating

    @Test("Free users get the paywall and nothing is sent")
    func freeUsersSeePaywall() async {
        let state = makeState(plus: false)
        let spy = TravelSpy()
        let model = makeModel(state, spy: spy)
        model.centerChanged(to: precise)

        #expect(await !model.browseFromSelection())
        #expect(state.isPaywallPresented)
        #expect(await spy.sent.isEmpty)
        #expect(state.travel == nil)
    }

    @Test("A 402 from the server drops Stexx+ and opens the paywall")
    func serverSaysNoPlus() async {
        let state = makeState(plus: true)
        let spy = TravelSpy()
        await spy.fail(with: APIError.requiresPlus)
        let model = makeModel(state, spy: spy)
        model.centerChanged(to: precise)

        #expect(await !model.browseFromSelection())
        #expect(!state.hasPlus)
        #expect(state.isPaywallPresented)
        #expect(state.travel == nil)
    }

    // MARK: Off and errors

    @Test("Turning it off sends null, and works after Stexx+ lapsed")
    func turnOffSendsNull() async {
        let state = makeState(plus: true)
        let spy = TravelSpy()
        let model = makeModel(state, spy: spy)
        model.centerChanged(to: precise)
        #expect(await model.browseFromSelection())

        state.applySubscription(.inactive)
        #expect(state.isTravelPaused)
        #expect(!state.isTravelActive)

        #expect(await model.turnOff())
        #expect(await spy.sent.last == .some(nil))
        #expect(state.travel == nil)
        #expect(!state.isTravelPaused)
        #expect(state.me?.travel == nil)
        #expect(!state.isPaywallPresented)
    }

    @Test("Network errors keep the current state and show a message")
    func errorsKeepState() async {
        let state = makeState(plus: true)
        let spy = TravelSpy()
        let model = makeModel(state, spy: spy)
        model.centerChanged(to: precise)
        #expect(await model.browseFromSelection())
        let before = state.travel

        await spy.fail(with: URLError(.notConnectedToInternet))
        model.centerChanged(to: .init(latitude: 52.52, longitude: 13.405))
        #expect(await !model.browseFromSelection())
        #expect(model.errorMessage != nil)
        #expect(state.travel == before)

        #expect(await !model.turnOff())
        #expect(state.travel == before)
        #expect(state.isTravelActive)

        await spy.fail(with: nil)
        #expect(await model.turnOff())
        #expect(model.errorMessage == nil)
        #expect(state.travel == nil)
    }

    // MARK: State

    @Test("Stexx+ lapsing pauses travel mode; renewing resumes it")
    func plusExpiry() async {
        let state = makeState(plus: true)
        let model = makeModel(state, spy: TravelSpy())
        model.centerChanged(to: precise)
        #expect(await model.browseFromSelection())

        state.applySubscription(.inactive)
        #expect(state.travel != nil)
        #expect(state.isTravelPaused)

        state.applySubscription(SubscriptionStatus(isActive: true, expiresAt: .now.addingTimeInterval(3600)))
        #expect(state.isTravelActive)
        #expect(state.me?.travel == TravelStatus(isActive: true))
    }

    @Test("Stexx+ running out while the app is open pauses travel mode and re-checks with the server")
    func plusRunsOutInForeground() async {
        let state = makeState(plus: true)
        var rechecks = 0
        state.recheckEntitlement = { rechecks += 1 }
        let model = makeModel(state, spy: TravelSpy())
        model.centerChanged(to: precise)
        #expect(await model.browseFromSelection())
        state.adoptServerPrivacy(PrivacySettings(incognito: true))
        let expiresAt = Date.now.addingTimeInterval(3600)
        state.applySubscription(SubscriptionStatus(isActive: true, expiresAt: expiresAt))

        state.checkPlusExpiry(now: expiresAt.addingTimeInterval(-1))
        #expect(state.isTravelActive)
        #expect(rechecks == 0)

        state.checkPlusExpiry(now: expiresAt)
        #expect(!state.hasPlus)
        #expect(!state.isTravelActive)
        #expect(state.isTravelPaused)
        #expect(state.me?.travel == TravelStatus(isActive: false))
        #expect(rechecks == 1)
        // Plus-only settings wait for the server's answer (it may have renewed).
        #expect(state.privacy.incognito)
        #expect(!state.isPaywallPresented)

        // The server says it renewed: back on.
        state.applySubscription(SubscriptionStatus(isActive: true, expiresAt: expiresAt.addingTimeInterval(30 * 24 * 3600)))
        #expect(state.isTravelActive)
        #expect(state.me?.travel == TravelStatus(isActive: true))
    }

    @Test("A timer drops Stexx+ at plusExpiresAt without waiting for the next foreground")
    func plusExpiryTimer() async throws {
        let state = makeState(plus: true)
        var rechecks = 0
        state.recheckEntitlement = { rechecks += 1 }
        state.me?.travel = TravelStatus(isActive: true)
        state.applySubscription(SubscriptionStatus(isActive: true, expiresAt: .now.addingTimeInterval(0.1)))
        #expect(state.isTravelActive)

        for _ in 0..<40 where state.hasPlus {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(!state.hasPlus)
        #expect(state.isTravelPaused)
        #expect(rechecks == 1)
    }

    @Test("GET /me saying travel is paused wins over a stale Stexx+ flag here")
    func serverPausedTravelDropsPlus() {
        let state = makeState(plus: true)
        var rechecks = 0
        state.recheckEntitlement = { rechecks += 1 }
        var me = MockData.me
        me.travel = TravelStatus(isActive: true)
        state.me = me
        #expect(state.isTravelActive)
        #expect(rechecks == 0)

        me.travel = TravelStatus(isActive: false)
        state.me = me
        #expect(!state.hasPlus)
        #expect(!state.isTravelActive)
        #expect(state.isTravelPaused)
        #expect(state.travel != nil)
        #expect(rechecks == 1)

        // Already free: nothing more to do.
        state.me = me
        #expect(rechecks == 1)
    }

    @Test("The server's state wins: on without a known place, or off")
    func serverStateWins() {
        let state = makeState(plus: true)
        var me = MockData.me
        me.travel = TravelStatus(isActive: true)
        state.me = me
        #expect(state.travel == TravelPlace())
        #expect(state.isTravelActive)

        me.travel = nil
        state.me = me
        #expect(state.travel == nil)
    }

    @Test("The place survives a relaunch and is forgotten on sign-out")
    func persistence() async {
        let suite = "stexx.tests.travel.\(UUID().uuidString)"
        let store = InMemorySessionStore()
        let travelStore = makeFileStore()
        let state = AppState(defaults: UserDefaults(suiteName: suite)!, sessionStore: store, travelStore: travelStore)
        state.signIn(MockData.session)
        state.hasPlus = true
        let model = makeModel(state, spy: TravelSpy())
        model.centerChanged(to: precise)
        await model.nameSelection(after: .zero)
        #expect(await model.browseFromSelection())

        let relaunched = AppState(defaults: UserDefaults(suiteName: suite)!, sessionStore: store, travelStore: travelStore)
        #expect(relaunched.travel == state.travel)
        // Kept in the protected file, not in the backed-up preferences plist.
        #expect(UserDefaults(suiteName: suite)!.data(forKey: "stexx.travel") == nil)
        #expect(travelStore.load() == state.travel)
        // Reopening the picker starts at the saved cell with its name.
        let reopened = makeModel(relaunched, spy: TravelSpy())
        #expect(reopened.selection == state.travel?.location)
        #expect(reopened.placeName == "Lisbon, Portugal")

        relaunched.signOut()
        #expect(relaunched.travel == nil)
        #expect(travelStore.load() == nil)
        let afterSignOut = AppState(
            defaults: UserDefaults(suiteName: suite)!,
            sessionStore: InMemorySessionStore(session: MockData.session),
            travelStore: travelStore
        )
        #expect(afterSignOut.travel == nil)
    }

    @Test("The travel file is excluded from backups and removed when cleared")
    func fileStore() throws {
        let store = makeFileStore()
        #expect(store.load() == nil)
        let place = TravelPlace(location: LocationFuzzer.fuzz(latitude: precise.latitude, longitude: precise.longitude), name: "Lisbon, Portugal")
        store.save(place)
        #expect(store.load() == place)
        let values = try store.directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)

        store.clear()
        #expect(store.load() == nil)
        store.clear() // Clearing twice is fine.
    }

    // MARK: Wire and mock

    @Test("Profile.travel decodes when present and defaults to nil")
    func decodesTravel() throws {
        let base = """
        {"id":"p_1","displayName":"A","lookingFor":[],"tags":[],"photos":[],"isOnline":false,"isFavorite":false
        """
        let on = try JSONDecoder.stexx().decode(Profile.self, from: Data((base + #","travel":{"isActive":false}}"#).utf8))
        #expect(on.travel == TravelStatus(isActive: false))
        let off = try JSONDecoder.stexx().decode(Profile.self, from: Data((base + #","travel":null}"#).utf8))
        #expect(off.travel == nil)
        let other = try JSONDecoder.stexx().decode(Profile.self, from: Data((base + "}").utf8))
        #expect(other.travel == nil)
    }

    @Test("The mock reports travel mode on its own profile and lets anyone turn it off")
    func mockTravel() async throws {
        let free = MockAPIClient(latency: .zero)
        let cell = LocationFuzzer.fuzz(latitude: precise.latitude, longitude: precise.longitude)
        await #expect(throws: APIError.requiresPlus) { try await free.setTravelLocation(cell) }
        try await free.setTravelLocation(nil)
        #expect(try await free.fetchMe().travel == nil)

        let plus = MockAPIClient(latency: .zero, plusActive: true)
        try await plus.setTravelLocation(cell)
        #expect(try await plus.fetchMe().travel == TravelStatus(isActive: true))
        #expect(try await plus.updateMe(ProfileUpdate(MockData.me)).travel == TravelStatus(isActive: true))
        try await plus.setTravelLocation(nil)
        #expect(try await plus.fetchMe().travel == nil)
    }

    @Test("The drawn cell is the one the server snaps to", arguments: [
        (38.7223456, -9.1393456), (0.0001, 0.0001), (-33.9, 151.2), (64.1, -21.9),
    ])
    func cellCorners(latitude: Double, longitude: Double) {
        let cell = LocationFuzzer.fuzz(latitude: latitude, longitude: longitude)
        let corners = LocationFuzzer.corners(of: cell)
        #expect(corners.count == 4)
        let lats = corners.map(\.latitude)
        let lons = corners.map(\.longitude)
        #expect((lats.min()!...lats.max()!).contains(latitude))
        #expect((lons.min()!...lons.max()!).contains(longitude))
        // Points just inside each corner fall in the same cell.
        for corner in corners {
            let inside = (
                corner.latitude + (cell.latitude - corner.latitude) * 0.02,
                corner.longitude + (cell.longitude - corner.longitude) * 0.02
            )
            #expect(LocationFuzzer.fuzz(latitude: inside.0, longitude: inside.1) == cell)
        }
    }
}
