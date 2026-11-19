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
    let answer: String?

    init(answer: String? = "Lisbon, Portugal") { self.answer = answer }

    var cells: [FuzzedLocation] { lock.withLock { asked } }

    @MainActor
    func name(for cell: FuzzedLocation) async -> String? {
        lock.withLock { asked.append(cell) }
        return answer
    }
}

@MainActor
struct TravelModeTests {
    /// A precise point well inside a cell (Lisbon).
    private let precise = TravelModeModel.Point(latitude: 38.7223456, longitude: -9.1393456)

    private func makeState(plus: Bool, suite: String = "stexx.tests.travel.\(UUID().uuidString)") -> AppState {
        let state = AppState(defaults: UserDefaults(suiteName: suite)!, sessionStore: InMemorySessionStore())
        state.signIn(MockData.session)
        state.me = MockData.me
        state.hasPlus = plus
        return state
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
        let state = AppState(defaults: UserDefaults(suiteName: suite)!, sessionStore: store)
        state.signIn(MockData.session)
        state.hasPlus = true
        let model = makeModel(state, spy: TravelSpy())
        model.centerChanged(to: precise)
        await model.nameSelection(after: .zero)
        #expect(await model.browseFromSelection())

        let relaunched = AppState(defaults: UserDefaults(suiteName: suite)!, sessionStore: store)
        #expect(relaunched.travel == state.travel)
        // Reopening the picker starts at the saved cell with its name.
        let reopened = makeModel(relaunched, spy: TravelSpy())
        #expect(reopened.selection == state.travel?.location)
        #expect(reopened.placeName == "Lisbon, Portugal")

        relaunched.signOut()
        #expect(relaunched.travel == nil)
        let afterSignOut = AppState(defaults: UserDefaults(suiteName: suite)!, sessionStore: InMemorySessionStore(session: MockData.session))
        #expect(afterSignOut.travel == nil)
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
