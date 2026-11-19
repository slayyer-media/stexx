#if DEBUG
import Foundation

/// Debug/screenshot-only (compiled out of Release): forces a Nearby state on
/// the mock backend, e.g.
/// `-StexxScreenshotRoute app -StexxDebugNearby denied`.
///
/// The location service is left out while a scenario runs (no system
/// prompt over the screenshot); the scenario says what the location state
/// is instead.
enum NearbyDebugScenario: String {
    /// No location uploaded yet: "Finding guys near you…".
    case firstRun
    /// Location permission denied, and the server has no location.
    case denied
    /// Location restricted (Screen Time or a device profile).
    case restricted
    /// Location denied, but the server still has a last known location.
    case deniedWithGrid
    /// Nobody nearby, with the Online quick filter on.
    case emptyFiltered
    /// Nobody nearby, no filters.
    case empty
    /// The first page fails (offline).
    case error
    /// Small pages; the second page fails once, then Retry works.
    case pageError
    /// The normal grid, located (for Dynamic Type screenshots).
    case grid

    static var current: NearbyDebugScenario? {
        UserDefaults.standard.string(forKey: "StexxDebugNearby").flatMap(NearbyDebugScenario.init)
    }

    var location: NearbyLocationState {
        switch self {
        case .firstRun: .locating
        case .denied, .deniedWithGrid: .denied
        case .restricted: .restricted
        case .emptyFiltered, .empty, .error, .pageError, .grid: .located
        }
    }

    /// The quick filter the screen starts with.
    var startsWithOnlineFilter: Bool { self == .emptyFiltered }

    /// Wraps the real (mock) fetch.
    func fetch(_ base: @escaping NearbyFetch) -> NearbyFetch {
        switch self {
        case .firstRun, .denied, .restricted, .empty, .emptyFiltered:
            return { _ in
                try await Task.sleep(for: .milliseconds(250))
                return Page(items: [], nextCursor: nil)
            }
        case .error:
            return { _ in
                try await Task.sleep(for: .milliseconds(250))
                throw URLError(.notConnectedToInternet)
            }
        case .pageError:
            return { query in
                var query = query
                query.limit = 9
                if query.cursor != nil, !NearbyDebugState.pageFailed {
                    NearbyDebugState.pageFailed = true
                    try await Task.sleep(for: .milliseconds(250))
                    throw URLError(.timedOut)
                }
                return try await base(query)
            }
        case .grid, .deniedWithGrid:
            return base
        }
    }
}

@MainActor
private enum NearbyDebugState {
    static var pageFailed = false
}
#endif
