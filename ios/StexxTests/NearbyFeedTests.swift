import CoreLocation
import Foundation
import Testing
@testable import Stexx

/// A `NearbyFetch` the test drives: each request waits until the test
/// answers it, in any order.
@MainActor
final class ScriptedNearbyFetch {
    private(set) var requests: [NearbyQuery] = []
    private var pending: [CheckedContinuation<Page<Profile>, any Error>] = []

    var fetch: NearbyFetch {
        { [self] query in
            requests.append(query)
            return try await withCheckedThrowingContinuation { pending.append($0) }
        }
    }

    var waiting: Int { pending.count }

    func answer(_ index: Int = 0, with page: Page<Profile>) {
        pending.remove(at: index).resume(returning: page)
    }

    func fail(_ index: Int = 0, with error: any Error) {
        pending.remove(at: index).resume(throwing: error)
    }

    /// Lets queued main-actor work (the started fetch) run.
    func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }
}

@MainActor
struct NearbyFeedTests {
    private let profiles = Array(MockData.profiles.prefix(6))
    private var key: NearbyLoadKey { NearbyLoadKey(query: NearbyQuery()) }
    private var onlineKey: NearbyLoadKey {
        var query = NearbyQuery()
        query.onlineOnly = true
        return NearbyLoadKey(query: query)
    }

    private func page(_ range: Range<Int>, next: String? = nil) -> Page<Profile> {
        Page(items: Array(profiles[range]), nextCursor: next)
    }

    /// What the screen shows for `feed` with no travel mode or filters.
    private func content(
        _ feed: NearbyFeedModel,
        location: NearbyLocationState = .located,
        timedOut: Bool = false,
        travel: Bool = false,
        filters: Bool = false
    ) -> NearbyContent {
        NearbyContent.resolve(
            hasProfiles: !feed.profiles.isEmpty,
            isLoading: feed.isPending,
            failure: feed.failure,
            location: location,
            locatingTimedOut: timedOut,
            isTravelActive: travel,
            filtersActive: filters
        )
    }

    // MARK: Location state

    @Test("Location service states map to what the grid needs")
    func locationStateMapping() {
        #expect(NearbyLocationState(status: nil, hasUploaded: false) == .unavailable)
        #expect(NearbyLocationState(status: .waitingForPermission, hasUploaded: false) == .waitingForPermission)
        #expect(NearbyLocationState(status: .active, hasUploaded: false) == .locating)
        #expect(NearbyLocationState(status: .active, hasUploaded: true) == .located)
        // Backgrounded (stopped) keeps what was known.
        #expect(NearbyLocationState(status: .idle, hasUploaded: true) == .located)
        #expect(NearbyLocationState(status: .denied, hasUploaded: true) == .denied)
        #expect(NearbyLocationState(status: .restricted, hasUploaded: false) == .restricted)
        #expect(NearbyLocationState.denied.isOff && NearbyLocationState.restricted.isOff)
        #expect(!NearbyLocationState.located.isOff)
    }

    @Test("LocationService tells restricted apart from denied")
    func restrictedStatus() {
        let restricted = LocationService(manager: FakeLocationManager(status: .restricted)) { _ in }
        restricted.start()
        #expect(restricted.status == .restricted)

        let manager = FakeLocationManager(status: .notDetermined)
        let service = LocationService(manager: manager) { _ in }
        service.start()
        #expect(service.status == .waitingForPermission)
        manager.answer(.denied)
        #expect(service.status == .denied)
        #expect(!manager.isUpdating)
    }

    // MARK: First run

    @Test("First run: finding you until the first upload, then the reloaded grid")
    func firstRunToLoaded() async {
        let feed = NearbyFeedModel()
        let server = ScriptedNearbyFetch()
        // Before anything loaded: never "nobody here".
        #expect(content(feed, location: .waitingForPermission) == .findingLocation)
        #expect(content(feed, location: .unavailable) == .loading)

        // The grid loads before the upload; the server has no location yet.
        let first = Task { await feed.reload(key, using: server.fetch) }
        await server.settle()
        #expect(content(feed, location: .locating) == .findingLocation)
        server.answer(with: Page(items: [], nextCursor: nil))
        await first.value
        #expect(content(feed, location: .locating) == .findingLocation)

        // The upload succeeded: the screen reloads and shows the grid.
        let second = Task { await feed.reload(key, using: server.fetch) }
        await server.settle()
        #expect(content(feed, location: .located) == .loading)
        server.answer(with: page(0..<3))
        await second.value
        #expect(content(feed, location: .located) == .grid)
        #expect(feed.profiles.map(\.id) == profiles[0..<3].map(\.id))
        // Popping back from a profile to the same grid doesn't refetch.
        #expect(!feed.needsReload(for: key))
    }

    @Test("First run: a slow upload stops blocking the grid after the timeout")
    func locatingTimeout() async {
        let feed = NearbyFeedModel()
        let server = ScriptedNearbyFetch()
        let load = Task { await feed.reload(key, using: server.fetch) }
        await server.settle()
        server.answer(with: Page(items: [], nextCursor: nil))
        await load.value
        #expect(content(feed, location: .locating, timedOut: false) == .findingLocation)
        #expect(content(feed, location: .locating, timedOut: true) == .empty(filtersActive: false))
        // Waiting on the permission prompt isn't timed out: the user decides.
        #expect(content(feed, location: .waitingForPermission, timedOut: true) == .findingLocation)
    }

    @Test("Offline cold launch: a failed first page or upload ends 'finding you' at once, without the timeout")
    func locatingFailsFast() async {
        let feed = NearbyFeedModel()
        let server = ScriptedNearbyFetch()
        func shown(uploadFailed: Bool = false) -> NearbyContent {
            NearbyContent.resolve(
                hasProfiles: !feed.profiles.isEmpty,
                isLoading: feed.isPending,
                failure: feed.failure,
                location: .locating,
                locatingTimedOut: false,
                locationUploadFailed: uploadFailed,
                isTravelActive: false,
                filtersActive: false
            )
        }

        // The upload failed while the first page is still in flight: a
        // spinner, not the first-run copy.
        let load = Task { await feed.reload(key, using: server.fetch) }
        await server.settle()
        #expect(shown() == .findingLocation)
        #expect(shown(uploadFailed: true) == .loading)

        // The first page failed (offline): the error with Retry, well before
        // the 20 s timeout, whether or not the upload has failed yet.
        server.fail(with: URLError(.notConnectedToInternet))
        await load.value
        let offline = NearbyFeedModel.message(for: URLError(.notConnectedToInternet))
        #expect(shown() == .failed(offline))
        #expect(shown(uploadFailed: true) == .failed(offline))

        // Retry shows a spinner; back online the grid shows.
        let retry = Task { await feed.reload(key, using: server.fetch) }
        await server.settle()
        #expect(shown() == .loading)
        server.answer(with: page(0..<3))
        await retry.value
        #expect(shown() == .grid)

        // The first page answered empty but the upload failed: no waiting
        // for an upload that won't come; same as after the timeout.
        let empty = Task { await feed.reload(onlineKey, using: server.fetch) }
        await server.settle()
        server.answer(with: Page(items: [], nextCursor: nil))
        await empty.value
        #expect(shown() == .findingLocation)
        #expect(shown(uploadFailed: true) == .empty(filtersActive: false))

        // Location off still explains the grid before any request error.
        #expect(NearbyContent.resolve(
            hasProfiles: false, isLoading: false, failure: offline, location: .denied,
            locationUploadFailed: true, isTravelActive: false, filtersActive: false
        ) == .locationOff(restricted: false))
    }

    // MARK: Location off

    @Test("Denied or restricted explains the empty grid; tiles or travel mode win")
    func locationOff() async {
        let feed = NearbyFeedModel()
        let server = ScriptedNearbyFetch()
        let load = Task { await feed.reload(key, using: server.fetch) }
        await server.settle()
        #expect(content(feed, location: .denied) == .locationOff(restricted: false))
        server.answer(with: Page(items: [], nextCursor: nil))
        await load.value

        #expect(content(feed, location: .denied) == .locationOff(restricted: false))
        #expect(content(feed, location: .restricted) == .locationOff(restricted: true))
        // Even with filters on, the location is the reason.
        #expect(content(feed, location: .denied, filters: true) == .locationOff(restricted: false))
        // Travel mode places you without the phone's location.
        #expect(content(feed, location: .denied, travel: true) == .empty(filtersActive: false))

        // The server still knows where you last were: show those tiles.
        let reload = Task { await feed.reload(key, using: server.fetch) }
        await server.settle()
        server.answer(with: page(0..<2))
        await reload.value
        #expect(content(feed, location: .denied) == .grid)
    }

    // MARK: Empty

    @Test("Nobody nearby is distinct from filtered-empty and from errors")
    func emptyVersusFiltered() async {
        let feed = NearbyFeedModel()
        let server = ScriptedNearbyFetch()
        let load = Task { await feed.reload(onlineKey, using: server.fetch) }
        await server.settle()
        server.answer(with: Page(items: [], nextCursor: nil))
        await load.value

        #expect(feed.failure == nil)
        #expect(content(feed, filters: false) == .empty(filtersActive: false))
        #expect(content(feed, filters: true) == .empty(filtersActive: true))
        #expect(feed.loadedKey == onlineKey)
        // An empty grid is fetched again whenever the screen reappears,
        // and the filter reset (a different key) always reloads.
        #expect(feed.needsReload(for: onlineKey))
        #expect(feed.needsReload(for: key))
    }

    // MARK: Errors

    @Test("A failed first page shows the error; Retry shows a spinner, then the grid")
    func firstPageErrorAndRetry() async {
        let feed = NearbyFeedModel()
        let server = ScriptedNearbyFetch()
        let load = Task { await feed.reload(key, using: server.fetch) }
        await server.settle()
        server.fail(with: URLError(.notConnectedToInternet))
        await load.value

        guard case .failed(let message) = content(feed) else {
            Issue.record("expected the error state, got \(content(feed))")
            return
        }
        #expect(message == NearbyFeedModel.message(for: URLError(.notConnectedToInternet)))
        #expect(!message.contains("NSURLErrorDomain"))
        #expect(feed.profiles.isEmpty)

        let retry = Task { await feed.reload(key, using: server.fetch) }
        await server.settle()
        #expect(content(feed) == .loading)
        server.answer(with: page(0..<3))
        await retry.value
        #expect(content(feed) == .grid)
        #expect(feed.failure == nil)
    }

    @Test("A failed refresh keeps the same grid; a failed filter change doesn't show stale tiles")
    func refreshFailure() async {
        let feed = NearbyFeedModel()
        let server = ScriptedNearbyFetch()
        let load = Task { await feed.reload(key, using: server.fetch) }
        await server.settle()
        server.answer(with: page(0..<3))
        await load.value

        // Pull to refresh fails: tiles stay, with a notice.
        let refresh = Task { await feed.reload(key, using: server.fetch) }
        await server.settle()
        server.fail(with: URLError(.timedOut))
        await refresh.value
        #expect(feed.profiles.count == 3)
        #expect(feed.refreshFailure != nil)
        #expect(content(feed) == .grid)
        feed.dismissRefreshFailure()
        #expect(feed.refreshFailure == nil)

        // A new filter fails: the old tiles were for other filters.
        let change = Task { await feed.reload(onlineKey, using: server.fetch) }
        await server.settle()
        server.fail(with: URLError(.timedOut))
        await change.value
        #expect(feed.profiles.isEmpty)
        #expect(feed.loadedKey == nil)
        if case .failed = content(feed) {} else { Issue.record("expected the error state, got \(content(feed))") }
    }

    @Test("A newer reload wins over an older one that answers late")
    func staleReloadIgnored() async {
        let feed = NearbyFeedModel()
        let server = ScriptedNearbyFetch()
        let older = Task { await feed.reload(key, using: server.fetch) }
        await server.settle()
        let newer = Task { await feed.reload(onlineKey, using: server.fetch) }
        await server.settle()
        #expect(server.waiting == 2)

        server.answer(1, with: page(0..<2))
        await newer.value
        server.fail(0, with: URLError(.timedOut))
        await older.value

        #expect(feed.loadedKey == onlineKey)
        #expect(feed.profiles.map(\.id) == profiles[0..<2].map(\.id))
        #expect(feed.failure == nil)
        #expect(!feed.isLoading)
    }

    // MARK: Pages

    @Test("A failed page shows a Retry cell, doesn't refetch by itself, and Retry continues")
    func pageErrorAndRetry() async {
        let feed = NearbyFeedModel()
        let server = ScriptedNearbyFetch()
        let load = Task { await feed.reload(key, using: server.fetch) }
        await server.settle()
        server.answer(with: page(0..<3, next: "3"))
        await load.value
        #expect(feed.showsFooter)
        #expect(feed.nextPage == .idle)

        let more = Task { await feed.loadMore(using: server.fetch) }
        await server.settle()
        #expect(feed.nextPage == .loading)
        #expect(server.requests.last?.cursor == "3")
        // Scrolling again while it loads doesn't start a second request.
        await feed.loadMore(using: server.fetch)
        #expect(server.waiting == 1)
        server.fail(with: URLError(.timedOut))
        await more.value

        guard case .failed = feed.nextPage else {
            Issue.record("expected a failed page, got \(feed.nextPage)")
            return
        }
        #expect(feed.profiles.count == 3)
        #expect(feed.showsFooter)
        #expect(content(feed) == .grid)

        // Reaching the end again doesn't hammer the server.
        await feed.loadMore(using: server.fetch)
        #expect(server.waiting == 0)
        #expect(server.requests.count == 2)

        // Retry: same cursor, appended, and the end of the grid.
        let retry = Task { await feed.retryNextPage(using: server.fetch) }
        await server.settle()
        #expect(feed.nextPage == .loading)
        #expect(server.requests.last?.cursor == "3")
        // A repeat (someone moved between pages) isn't shown twice.
        server.answer(with: Page(items: [profiles[2]] + Array(profiles[3..<6]), nextCursor: nil))
        await retry.value
        #expect(feed.nextPage == .idle)
        #expect(feed.profiles.map(\.id) == profiles.map(\.id))
        #expect(feed.nextCursor == nil)
        #expect(!feed.showsFooter)
    }

    @Test("A page of only hidden (blocked) people keeps paging instead of reading as nobody nearby")
    func allHiddenPageKeepsPaging() async {
        let feed = NearbyFeedModel()
        let server = ScriptedNearbyFetch()
        // Blocked on this phone after the pages were served.
        let blocked = Set(profiles[0..<4].map(\.id))
        let isHidden: (Profile) -> Bool = { blocked.contains($0.id) }
        func shown() -> NearbyContent {
            NearbyContent.resolve(
                hasProfiles: feed.profiles.contains { !isHidden($0) },
                hasMorePages: feed.nextCursor != nil,
                isLoading: feed.isPending,
                failure: feed.failure,
                location: .located,
                isTravelActive: false,
                filtersActive: false
            )
        }

        let load = Task { await feed.reload(key, using: server.fetch) }
        await server.settle()
        server.answer(with: page(0..<2, next: "2"))
        await load.value
        // Nothing visible, but the server has more: the grid with its page
        // cell, not "Nobody here yet".
        #expect(shown() == .grid)
        #expect(feed.showsFooter)

        // Two hidden-only pages in a row, then someone visible.
        let paging = Task { await feed.loadMoreWhileAllHidden(isHidden, using: server.fetch) }
        await server.settle()
        #expect(server.requests.last?.cursor == "2")
        server.answer(with: page(2..<4, next: "4"))
        await server.settle()
        #expect(server.requests.last?.cursor == "4")
        server.answer(with: page(4..<5, next: "5"))
        await paging.value
        // Stops at the first visible profile; the last-tile trigger takes over.
        #expect(server.requests.count == 3)
        #expect(server.waiting == 0)
        #expect(shown() == .grid)

        // With nothing more on the server, hidden-only really is empty.
        let empty = NearbyFeedModel()
        let emptyLoad = Task { await empty.reload(key, using: server.fetch) }
        await server.settle()
        server.answer(with: page(0..<2))
        await emptyLoad.value
        await empty.loadMoreWhileAllHidden(isHidden, using: server.fetch)
        #expect(server.waiting == 0)
        #expect(NearbyContent.resolve(
            hasProfiles: false,
            hasMorePages: empty.nextCursor != nil,
            isLoading: empty.isPending,
            failure: empty.failure,
            location: .located,
            isTravelActive: false,
            filtersActive: false
        ) == .empty(filtersActive: false))
    }

    @Test("A failed page behind hidden-only tiles shows the Retry cell, and Retry continues paging")
    func allHiddenPageFailure() async {
        let feed = NearbyFeedModel()
        let server = ScriptedNearbyFetch()
        let blocked = Set(profiles[0..<4].map(\.id))
        let isHidden: (Profile) -> Bool = { blocked.contains($0.id) }

        let load = Task { await feed.reload(key, using: server.fetch) }
        await server.settle()
        server.answer(with: page(0..<2, next: "2"))
        await load.value

        let paging = Task { await feed.loadMoreWhileAllHidden(isHidden, using: server.fetch) }
        await server.settle()
        server.fail(with: URLError(.notConnectedToInternet))
        await paging.value
        guard case .failed = feed.nextPage else {
            Issue.record("expected a failed page, got \(feed.nextPage)")
            return
        }
        // No retry loop: one request, then the Retry cell in the grid.
        #expect(server.requests.count == 2)
        #expect(NearbyContent.resolve(
            hasProfiles: false,
            hasMorePages: true,
            isLoading: false,
            failure: nil,
            location: .located,
            isTravelActive: false,
            filtersActive: false
        ) == .grid)
        await feed.loadMoreWhileAllHidden(isHidden, using: server.fetch)
        #expect(server.waiting == 0)

        // Retry answers another hidden-only page; the screen's task (keyed on
        // the cursor) runs the loop again, which fetches on.
        let retry = Task { await feed.retryNextPage(using: server.fetch) }
        await server.settle()
        server.answer(with: page(2..<4, next: "4"))
        await retry.value
        let again = Task { await feed.loadMoreWhileAllHidden(isHidden, using: server.fetch) }
        await server.settle()
        #expect(server.requests.last?.cursor == "4")
        server.answer(with: page(4..<6))
        await again.value
        #expect(feed.profiles.count == 6)
        #expect(feed.nextCursor == nil)
    }

    @Test("While a first page loads, more pages from the old grid don't hide the spinner")
    func moreOldPagesDuringReload() {
        #expect(NearbyContent.resolve(
            hasProfiles: false,
            hasMorePages: true,
            isLoading: true,
            failure: nil,
            location: .located,
            isTravelActive: false,
            filtersActive: false
        ) == .loading)
    }

    @Test("A reload drops a page request that was still running")
    func reloadDuringPage() async {
        let feed = NearbyFeedModel()
        let server = ScriptedNearbyFetch()
        let load = Task { await feed.reload(key, using: server.fetch) }
        await server.settle()
        server.answer(with: page(0..<3, next: "3"))
        await load.value

        let more = Task { await feed.loadMore(using: server.fetch) }
        await server.settle()
        let reload = Task { await feed.reload(onlineKey, using: server.fetch) }
        await server.settle()
        #expect(feed.nextPage == .idle)

        server.answer(1, with: page(4..<6))
        await reload.value
        // The old grid's page arrives late and must not be appended.
        server.answer(0, with: page(3..<4, next: "4"))
        await more.value
        #expect(feed.profiles.map(\.id) == profiles[4..<6].map(\.id))
        #expect(feed.nextCursor == nil)
    }

    @Test("Error text is a sentence, not an error code")
    func errorMessages() {
        #expect(NearbyFeedModel.message(for: URLError(.notConnectedToInternet)).contains("offline"))
        #expect(NearbyFeedModel.message(for: URLError(.timedOut)).contains("too long"))
        #expect(NearbyFeedModel.message(for: URLError(.cannotFindHost)).contains("Couldn't reach"))
        #expect(NearbyFeedModel.message(for: APIError.rateLimited(retryAfter: nil)) == APIError.rateLimited(retryAfter: nil).localizedDescription)
    }

    // MARK: Accessibility

    @Test("Tiles read name, age, online, distance and favorite")
    func tileLabel() {
        var profile = MockData.profiles[0]
        profile.isOnline = true
        profile.isFavorite = true
        profile.distanceMeters = 240
        let label = ProfileTile.accessibilityLabel(for: profile, locale: Locale(identifier: "de_DE"))
        #expect(label == "\(profile.nameAndAge), online, 200 m away, favorite")

        profile.isOnline = false
        profile.isFavorite = false
        profile.distanceMeters = nil
        #expect(ProfileTile.accessibilityLabel(for: profile) == profile.nameAndAge)
    }
}
