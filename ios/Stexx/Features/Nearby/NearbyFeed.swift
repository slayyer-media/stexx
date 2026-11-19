import Foundation
import Observation

/// Fetches one page of the Nearby grid (`GET /nearby`).
typealias NearbyFetch = @MainActor (NearbyQuery) async throws -> Page<Profile>

/// What the grid depends on: the filters, and where you browse from
/// (travel mode on, moved or off, or paused by a lapsed Stexx+).
struct NearbyLoadKey: Hashable {
    var query: NearbyQuery
    var travelRevision: Int = 0
    var isTravelActive: Bool = false
}

/// What Nearby knows about this phone's location, read from
/// `LocationService`. Only the state; never a coordinate.
enum NearbyLocationState: Equatable {
    /// No location service (previews, tests): don't gate the grid on it.
    case unavailable
    /// The system permission prompt is up (or about to be).
    case waitingForPermission
    /// Allowed, but no cell has been uploaded this session yet.
    case locating
    /// A cell was uploaded this session.
    case located
    /// The user said no, or Location Services are off.
    case denied
    /// Screen Time or a device profile blocks location; the user may not be
    /// able to change it.
    case restricted

    init(status: LocationService.Status?, hasUploaded: Bool) {
        switch status {
        case nil: self = .unavailable
        case .waitingForPermission: self = .waitingForPermission
        case .denied: self = .denied
        case .restricted: self = .restricted
        // `idle` is the brief moment before the service starts (or the app
        // is in the background): same as active until something is known.
        case .idle, .active: self = hasUploaded ? .located : .locating
        }
    }

    /// The phone's own location can't be used, so the server can only
    /// place you at a location it already has (or nowhere).
    var isOff: Bool { self == .denied || self == .restricted }
}

/// What the Nearby screen shows in place of (or as) the grid.
enum NearbyContent: Equatable {
    /// Tiles (with an inline footer for the next page).
    case grid
    /// The first page is loading and there's nothing to show yet.
    case loading
    /// First run: waiting for permission or the first location upload.
    case findingLocation
    /// Location is denied or restricted and the grid came back empty.
    case locationOff(restricted: Bool)
    /// The first page failed to load.
    case failed(String)
    /// Loaded, and nobody matched. `filtersActive` offers a one-tap reset.
    case empty(filtersActive: Bool)

    /// How long the first-run state waits for a location upload before
    /// falling back to whatever the grid returned.
    static let locatingTimeout: Duration = .seconds(20)

    /// The state machine. Order matters:
    /// 1. Anything to show wins: the grid. So do more pages on the server
    ///    when every loaded tile is hidden here (blocked since the page
    ///    loaded): the grid's page cell keeps loading (or offers Retry)
    ///    instead of claiming nobody is nearby.
    /// 2. Unless travel mode places you, an empty grid is explained by the
    ///    location first (off, or not uploaded yet). Off wins over a request
    ///    error, since turning location on is what the user can fix.
    ///    "Finding you" only while it can still come true: not after the
    ///    timeout, a failed location upload or a failed first page. Offline,
    ///    both fail at once; a returning user (the server already has a
    ///    location) then sees the error with Retry, not the first-run copy.
    /// 3. A first page in flight shows a spinner (also while retrying).
    /// 4. A failed first page shows the error with Retry.
    /// 5. Otherwise nobody matched: friendly empty, or "clear filters".
    static func resolve(
        hasProfiles: Bool,
        hasMorePages: Bool = false,
        isLoading: Bool,
        failure: String?,
        location: NearbyLocationState,
        locatingTimedOut: Bool = false,
        locationUploadFailed: Bool = false,
        isTravelActive: Bool,
        filtersActive: Bool
    ) -> NearbyContent {
        if hasProfiles || (hasMorePages && !isLoading) { return .grid }
        if !isTravelActive {
            switch location {
            case .denied: return .locationOff(restricted: false)
            case .restricted: return .locationOff(restricted: true)
            case .waitingForPermission: return .findingLocation
            case .locating where !locatingTimedOut && !locationUploadFailed && failure == nil:
                return .findingLocation
            case .locating, .located, .unavailable: break
            }
        }
        if isLoading { return .loading }
        if let failure { return .failed(failure) }
        return .empty(filtersActive: filtersActive)
    }
}

/// The Nearby grid's data: the first page, further pages and their errors.
/// The screen derives what to show with `NearbyContent.resolve`.
@MainActor
@Observable
final class NearbyFeedModel {
    enum NextPage: Equatable {
        case idle
        case loading
        /// A page failed; the grid shows a Retry cell at its end and doesn't
        /// fetch again by itself.
        case failed(String)
    }

    private(set) var profiles: [Profile] = []
    private(set) var nextCursor: String?
    /// The first page is being (re)loaded.
    private(set) var isLoading = false
    /// The last first-page load failed and there was nothing (still valid)
    /// to show.
    private(set) var failure: String?
    /// A refresh of a grid that's still on screen failed; the tiles stay.
    private(set) var refreshFailure: String?
    private(set) var nextPage: NextPage = .idle
    /// The key the tiles on screen were loaded for.
    private(set) var loadedKey: NearbyLoadKey?

    /// Bumped by every reload: older requests finishing late are ignored.
    @ObservationIgnored private var generation = 0

    /// Nothing loaded (or failed) yet for any key, or a first page is
    /// loading: the empty grid isn't an answer yet.
    var isPending: Bool { isLoading || (loadedKey == nil && failure == nil) }

    /// Whether the end of the grid shows a footer (loading or Retry).
    var showsFooter: Bool { nextCursor != nil || nextPage != .idle }

    /// Whether a reload is due when the screen (re)appears for `key`:
    /// skipped when popping back from a profile to the same grid.
    func needsReload(for key: NearbyLoadKey) -> Bool {
        key != loadedKey || profiles.isEmpty
    }

    /// Loads the first page for `key`, replacing the grid.
    ///
    /// Old tiles stay on screen while it loads. If it fails and they were
    /// for the same filters, they stay and `refreshFailure` says so; if they
    /// were for other filters (or there were none), they go and `failure`
    /// shows instead.
    func reload(_ key: NearbyLoadKey, using fetch: NearbyFetch) async {
        generation += 1
        let generation = generation
        isLoading = true
        // A page request still running belongs to the old grid.
        nextPage = .idle
        do {
            var query = key.query
            query.cursor = nil
            let page = try await fetch(query)
            guard generation == self.generation else { return }
            profiles = Self.unique(page.items)
            nextCursor = page.nextCursor
            loadedKey = key
            failure = nil
            refreshFailure = nil
        } catch let error where Self.isCancellation(error) {
            // Replaced by a newer reload, or the screen went away; the next
            // appearance loads again if needed.
        } catch {
            guard generation == self.generation else { return }
            let message = Self.message(for: error)
            if key == loadedKey, !profiles.isEmpty {
                refreshFailure = message
            } else {
                profiles = []
                nextCursor = nil
                loadedKey = nil
                failure = message
                refreshFailure = nil
            }
        }
        if generation == self.generation { isLoading = false }
    }

    /// Loads the page after the last one. Does nothing while the first page
    /// loads, after the last page, or after a failure (use `retryNextPage`).
    func loadMore(using fetch: NearbyFetch) async {
        guard let cursor = nextCursor, let key = loadedKey, nextPage == .idle, !isLoading else { return }
        let generation = generation
        nextPage = .loading
        var query = key.query
        query.cursor = cursor
        do {
            let page = try await fetch(query)
            guard generation == self.generation else { return }
            profiles = Self.unique(profiles + page.items)
            nextCursor = page.nextCursor
            nextPage = .idle
        } catch let error where Self.isCancellation(error) {
            if generation == self.generation { nextPage = .idle }
        } catch {
            guard generation == self.generation else { return }
            nextPage = .failed(Self.message(for: error))
        }
    }

    /// Keeps loading pages while every profile loaded so far is hidden on
    /// this phone (blocked after the page loaded). With no tile on screen
    /// the last-tile trigger never fires, so without this a page of only
    /// hidden people would stop paging. Stops at the first visible profile,
    /// the last page, a failed page (the Retry cell takes over), a reload,
    /// or cancellation.
    func loadMoreWhileAllHidden(_ isHidden: (Profile) -> Bool, using fetch: NearbyFetch) async {
        while let cursor = nextCursor, nextPage == .idle, !isLoading,
              profiles.allSatisfy(isHidden), !Task.isCancelled {
            await loadMore(using: fetch)
            // No progress: cancelled, failed or replaced by a reload.
            guard nextCursor != cursor else { return }
        }
    }

    /// The Retry cell at the end of the grid.
    func retryNextPage(using fetch: NearbyFetch) async {
        guard case .failed = nextPage else { return }
        nextPage = .idle
        await loadMore(using: fetch)
    }

    func dismissRefreshFailure() {
        refreshFailure = nil
    }

    /// First occurrence wins: a page can repeat someone who moved between
    /// requests.
    private static func unique(_ items: [Profile]) -> [Profile] {
        var seen = Set<Profile.ID>()
        return items.filter { seen.insert($0.id).inserted }
    }

    /// Words for the error states. Network failures get plain sentences
    /// (a bare `URLError` reads "NSURLErrorDomain error -1009"); API errors
    /// already carry the server's or the app's message.
    static func message(for error: any Error) -> String {
        guard let error = error as? URLError else { return error.localizedDescription }
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            return String(localized: "You're offline. Check your connection and try again.")
        case .timedOut:
            return String(localized: "Stexx took too long to answer. Try again.")
        default:
            return String(localized: "Couldn't reach Stexx. Try again in a moment.")
        }
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let error = error as? URLError, error.code == .cancelled { return true }
        return false
    }
}
