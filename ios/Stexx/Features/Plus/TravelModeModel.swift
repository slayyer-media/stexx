import Foundation
import MapKit
import Observation

/// Stexx+ travel mode: the picker's state and the on/off calls.
///
/// The map's center never leaves the phone. What is sent is `selection`, the
/// 500 m grid cell around it (`LocationFuzzer`), and the server re-snaps it
/// to the same grid. The place name is looked up on the device (MapKit) and
/// kept in `AppState`; the Stexx server never receives it.
@MainActor
@Observable
final class TravelModeModel {
    /// A map coordinate (Sendable and Equatable, unlike `CLLocationCoordinate2D`).
    struct Point: Hashable, Sendable {
        var latitude: Double
        var longitude: Double
    }

    /// Where the map is centered. Stays on this device.
    private(set) var center: Point?
    /// The name of the selected cell, looked up on this device.
    private(set) var placeName: String?
    private(set) var isNaming = false
    private(set) var isSaving = false
    var errorMessage: String?

    @ObservationIgnored let appState: AppState
    @ObservationIgnored private let send: @Sendable (FuzzedLocation?) async throws -> Void
    @ObservationIgnored private let naming: any TravelPlaceNaming

    /// - Parameters:
    ///   - setTravelLocation: `PUT /me/travel` (`APIClient.setTravelLocation`).
    ///   - naming: Looks up a display name for a cell.
    init(
        appState: AppState,
        setTravelLocation: @escaping @Sendable (FuzzedLocation?) async throws -> Void,
        naming: any TravelPlaceNaming = MapKitPlaceNaming()
    ) {
        self.appState = appState
        self.send = setTravelLocation
        self.naming = naming
        if let current = appState.travel, let cell = current.location {
            center = Point(latitude: cell.latitude, longitude: cell.longitude)
            placeName = current.name
        }
    }

    convenience init(appState: AppState, api: any APIClient) {
        self.init(appState: appState, setTravelLocation: { try await api.setTravelLocation($0) })
    }

    // MARK: Selection

    /// The cell that would be sent: the map center, snapped on this device.
    var selection: FuzzedLocation? {
        center.map { LocationFuzzer.fuzz(latitude: $0.latitude, longitude: $0.longitude) }
    }

    /// Travel mode is on (possibly paused by a lapsed Stexx+).
    var isOn: Bool { appState.travel != nil }

    /// The selection is already where travel mode puts you.
    var isCurrentPlace: Bool {
        guard let selection else { return false }
        return appState.isTravelActive && appState.travel?.location == selection
    }

    /// The map moved. A new cell forgets the old cell's name.
    func centerChanged(to point: Point) {
        let before = selection
        center = point
        if selection != before {
            placeName = nil
            isNaming = selection != nil
        }
    }

    /// Looks up the selected cell's name. Call from `.task(id: selection)`,
    /// which cancels it when the map moves on.
    func nameSelection(after delay: Duration = .milliseconds(350)) async {
        guard let cell = selection else { return }
        if delay > .zero {
            // Debounce: panning changes the cell many times per second.
            do { try await Task.sleep(for: delay) } catch { return }
        }
        let name = await naming.name(for: cell)
        guard !Task.isCancelled, cell == selection else { return }
        placeName = name
        isNaming = false
    }

    /// Uses a name the user picked from search results until (unless) the
    /// lookup for the new cell answers.
    func suggestName(_ name: String) {
        placeName = name
    }

    // MARK: On / off

    /// Turns travel mode on at the selected cell, or moves it there.
    /// Without Stexx+ this opens the paywall and sends nothing.
    /// Returns `true` once the server accepted it.
    @discardableResult
    func browseFromSelection() async -> Bool {
        guard appState.requirePlus() else { return false }
        guard let cell = selection, !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }
        errorMessage = nil
        do {
            try await send(cell)
            appState.travelDidChange(to: TravelPlace(location: cell, name: placeName))
            return true
        } catch APIError.requiresPlus {
            appState.handleRequiresPlus()
        } catch {
            errorMessage = error.localizedDescription
        }
        return false
    }

    /// Turns travel mode off (sends `null`). Free: a lapsed subscriber can
    /// always turn it off. Returns `true` once the server accepted it.
    @discardableResult
    func turnOff() async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }
        errorMessage = nil
        do {
            try await send(nil)
            appState.travelDidChange(to: nil)
            return true
        } catch {
            errorMessage = error.localizedDescription
        }
        return false
    }
}

// MARK: - Place names

/// Names a travel cell for display. The name stays on the device.
protocol TravelPlaceNaming: Sendable {
    @MainActor func name(for cell: FuzzedLocation) async -> String?
}

/// Reverse geocoding with MapKit (Apple's built-in service; no third-party
/// API). Only the already-fuzzed cell center is looked up.
struct MapKitPlaceNaming: TravelPlaceNaming {
    @MainActor
    func name(for cell: FuzzedLocation) async -> String? {
        let location = CLLocation(latitude: cell.latitude, longitude: cell.longitude)
        guard let request = MKReverseGeocodingRequest(location: location),
              let item = try? await request.mapItems.first
        else { return nil }
        let address = item.addressRepresentations
        return address?.cityWithContext(.short) ?? address?.cityName ?? address?.regionName ?? item.name
    }
}

// MARK: - City search

/// City search for the picker, with MapKit's `MKLocalSearchCompleter`
/// (Apple's built-in service). Queries go to Apple, never to Stexx.
@MainActor
@Observable
final class TravelPlaceSearch: NSObject {
    struct Suggestion: Identifiable, Hashable, Sendable {
        var title: String
        var subtitle: String
        var id: String { "\(title)\u{1F}\(subtitle)" }
    }

    var query = "" {
        didSet {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                completer.cancel()
                results = []
            } else {
                completer.queryFragment = trimmed
            }
        }
    }
    private(set) var results: [Suggestion] = []

    @ObservationIgnored private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = .address
        completer.addressFilter = MKAddressFilter(including: [.locality, .subLocality, .administrativeArea, .country])
    }

    /// The center of a suggestion, or `nil` if MapKit can't find it.
    func locate(_ suggestion: Suggestion) async -> TravelModeModel.Point? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = [suggestion.title, suggestion.subtitle]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        request.resultTypes = .address
        guard let item = try? await MKLocalSearch(request: request).start().mapItems.first else { return nil }
        let coordinate = item.location.coordinate
        return TravelModeModel.Point(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    fileprivate func update(_ suggestions: [Suggestion]) {
        results = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : suggestions
    }
}

extension TravelPlaceSearch: MKLocalSearchCompleterDelegate {
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let suggestions = completer.results.prefix(8).map { Suggestion(title: $0.title, subtitle: $0.subtitle) }
        Task { @MainActor in self.update(Array(suggestions)) }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: any Error) {
        Task { @MainActor in self.update([]) }
    }
}
