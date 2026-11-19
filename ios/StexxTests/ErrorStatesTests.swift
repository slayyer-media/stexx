import Foundation
import Testing
@testable import Stexx

struct UserFacingErrorTests {
    @Test("429 says how long to wait, from Retry-After, rounded up to minutes")
    func rateLimitedUsesRetryAfter() {
        #expect(UserFacingError.message(for: APIError.rateLimited(retryAfter: 600)) == "You're doing that too often. Try again in 10 min.")
        #expect(UserFacingError.message(for: APIError.rateLimited(retryAfter: 61)) == "You're doing that too often. Try again in 2 min.")
        #expect(UserFacingError.message(for: APIError.rateLimited(retryAfter: 5)) == "You're doing that too often. Try again in 1 min.")
        #expect(UserFacingError.message(for: APIError.rateLimited(retryAfter: 7200)) == "You're doing that too often. Try again in 2 h.")
        #expect(UserFacingError.message(for: APIError.rateLimited(retryAfter: nil)) == "You're doing that too often. Try again in a moment.")
    }

    @Test("A 429 isn't prefixed with the failed action; it explains itself")
    func rateLimitedIgnoresAction() {
        let message = UserFacingError.message(for: APIError.rateLimited(retryAfter: 120), failedAction: "Couldn't send the tap.")
        #expect(message == "You're doing that too often. Try again in 2 min.")
    }

    @Test("402 and requires_plus point at Stexx+")
    func requiresPlus() {
        #expect(UserFacingError.message(for: APIError.requiresPlus) == "This is part of Stexx+.")
        #expect(UserFacingError.message(for: APIError.server(status: 402, message: nil)) == "This is part of Stexx+.")
    }

    @Test("403 account_under_review shows the server's message as is")
    func underReviewUsesServerMessage() {
        let text = "Your account is being reviewed by our moderators."
        #expect(UserFacingError.message(for: APIError.server(status: 403, message: text), failedAction: "Couldn't send the tap.") == text)
        #expect(UserFacingError.message(for: APIError.server(status: 403, message: nil)) == "You can't do that right now.")
    }

    @Test("Offline and unreachable ask to check the connection, after the failed action")
    func offline() {
        #expect(UserFacingError.message(for: URLError(.notConnectedToInternet)) == "Couldn't connect. Check your connection and try again.")
        #expect(UserFacingError.message(for: URLError(.timedOut), failedAction: "Couldn't send the tap.")
            == "Couldn't send the tap. Check your connection and try again.")
        #expect(UserFacingError.isOffline(URLError(.cannotConnectToHost)))
        #expect(!UserFacingError.isOffline(URLError(.badServerResponse)))
    }

    @Test("Anything else gets a generic message; cancellations get none")
    func genericAndCancellation() {
        #expect(UserFacingError.message(for: APIError.server(status: 500, message: "stack trace")) == "Something went wrong. Try again.")
        #expect(UserFacingError.message(for: APIError.invalidResponse, failedAction: "Couldn't save your profile.")
            == "Couldn't save your profile. Try again.")
        #expect(UserFacingError.message(for: CancellationError()) == nil)
        #expect(UserFacingError.message(for: URLError(.cancelled)) == nil)
    }
}

extension UserFacingErrorTests {
    @Test("A 404 is worded neutrally, since it can come from any call")
    func notFoundIsNeutral() {
        #expect(UserFacingError.message(for: APIError.notFound) == "That no longer exists.")
        #expect(UserFacingError.message(for: APIError.notFound, failedAction: "Couldn't add that photo.")
            == "Couldn't add that photo. It no longer exists.")
    }
}

struct MyProfileLoadStateTests {
    @Test("Edit stays disabled until the real profile has loaded")
    func editDisabledUntilLoaded() {
        let loading = MyProfileLoadState(me: nil, loadError: nil)
        #expect(loading == .loading)
        #expect(!loading.canEdit)

        let failed = MyProfileLoadState(me: nil, loadError: "Couldn't connect.")
        #expect(failed == .failed("Couldn't connect."))
        #expect(!failed.canEdit)

        let loaded = MyProfileLoadState(me: MockData.me, loadError: nil)
        #expect(loaded == .loaded(MockData.me))
        #expect(loaded.canEdit)
    }

    @Test("A profile that arrives later wins over an earlier error")
    func profileWinsOverStaleError() {
        let state = MyProfileLoadState(me: MockData.me, loadError: "Couldn't connect.")
        #expect(state.canEdit)
    }
}

struct EditProfileDirtyTests {
    private let initial = MockData.profiles[0]

    @Test("An untouched draft has nothing to lose")
    func untouched() {
        #expect(!EditProfileView.hasUnsavedChanges(initial: initial, draft: initial, pendingTag: ""))
        #expect(!EditProfileView.hasUnsavedChanges(initial: initial, draft: initial, pendingTag: "   "))
    }

    @Test("Field, photo and pending-tag changes count as unsaved")
    func changes() throws {
        var headline = initial
        headline.headline = (initial.headline ?? "") + "!"
        #expect(EditProfileView.hasUnsavedChanges(initial: initial, draft: headline, pendingTag: ""))

        try #require(initial.photos.count > 1)
        var removed = initial
        removed.photos.removeFirst()
        #expect(EditProfileView.hasUnsavedChanges(initial: initial, draft: removed, pendingTag: ""))
        var reordered = initial
        reordered.photos.reverse()
        #expect(EditProfileView.hasUnsavedChanges(initial: initial, draft: reordered, pendingTag: ""))

        var tags = initial
        tags.tags.append("Chess")
        #expect(EditProfileView.hasUnsavedChanges(initial: initial, draft: tags, pendingTag: ""))

        #expect(EditProfileView.hasUnsavedChanges(initial: initial, draft: initial, pendingTag: "Chess"))
    }

    @Test("A photo still uploading counts as unsaved, so the sheet can't be swiped or cancelled away silently")
    func uploadInFlight() {
        #expect(EditProfileView.hasUnsavedChanges(initial: initial, draft: initial, pendingTag: "", isUploading: true))
    }

    @Test("Toggling a looking-for item off and on again isn't a change")
    func lookingForOrder() {
        var base = initial
        base.lookingFor = [.chat, .dates]
        var draft = base
        draft.lookingFor = [.dates, .chat]
        #expect(!EditProfileView.hasUnsavedChanges(initial: base, draft: draft, pendingTag: ""))
    }
}

@MainActor
struct ProfileActionsTests {
    private func makeAPI() -> MockAPIClient { MockAPIClient(latency: .zero) }
    private let profile = MockData.profiles[0]

    @Test("A failed favorite puts the star back and explains")
    func favoriteReverts() async {
        let api = makeAPI()
        await api.inject(.fail(URLError(.notConnectedToInternet)), for: "setFavorite")
        let actions = ProfileActions(profile: profile)
        let before = actions.profile.isFavorite

        await actions.toggleFavorite(using: api)

        #expect(actions.profile.isFavorite == before)
        #expect(actions.toast?.hasPrefix(before ? "Couldn't remove from favorites." : "Couldn't add to favorites.") == true)
    }

    @Test("A successful favorite keeps the new value and no toast")
    func favoriteSucceeds() async {
        let actions = ProfileActions(profile: profile)
        let before = actions.profile.isFavorite
        await actions.toggleFavorite(using: makeAPI())
        #expect(actions.profile.isFavorite == !before)
        #expect(actions.toast == nil)
    }

    @Test("A rate-limited tap re-enables the button and says when to try again")
    func tapRateLimited() async {
        let api = makeAPI()
        await api.inject(.fail(APIError.rateLimited(retryAfter: 600)), for: "sendTap")
        let actions = ProfileActions(profile: profile)

        await actions.sendTap(using: api)

        #expect(!actions.didTap)
        #expect(actions.toast == "You're doing that too often. Try again in 10 min.")
    }

    @Test("A tap refused for review shows the server's message")
    func tapUnderReview() async {
        let api = makeAPI()
        let text = "Your account is being reviewed by our moderators."
        await api.inject(.fail(APIError.server(status: 403, message: text)), for: "sendTap")
        let actions = ProfileActions(profile: profile)

        await actions.sendTap(using: api)

        #expect(!actions.didTap)
        #expect(actions.toast == text)
    }

    @Test("A 404 on a profile action says the profile is gone")
    func tapNotFound() async {
        let api = makeAPI()
        await api.inject(.fail(APIError.notFound), for: "sendTap")
        let actions = ProfileActions(profile: profile)

        await actions.sendTap(using: api)

        #expect(!actions.didTap)
        #expect(actions.toast == "This profile is no longer available.")
    }

    @Test("A failed block never reports success, and the profile isn't blocked")
    func blockFailureIsNotSuccess() async throws {
        let api = makeAPI()
        await api.inject(.fail(URLError(.notConnectedToInternet)), for: "block")
        let actions = ProfileActions(profile: profile)

        let didBlock = await actions.block(using: api)

        #expect(!didBlock)
        #expect(actions.blockFailure == "Couldn't connect. Check your connection and try again.")
        #expect(!actions.isBlocking)
        await api.inject(nil, for: "block")
        #expect(try await api.blockedProfiles().isEmpty)

        // Retry after the network is back.
        #expect(await actions.block(using: api))
        #expect(actions.blockFailure == nil)
        #expect(try await api.blockedProfiles().map(\.id) == [profile.id])
    }
}

struct MockFailureInjectionTests {
    @Test("-StexxMockFail parses each endpoint's outcome and skips unknown values")
    func parsesLaunchArgument() async {
        let outcomes = MockAPIClient.parseLaunchOutcomes("fetchMe=offline, sendTap=429,block=nope,=500")
        #expect(Set(outcomes.keys) == ["fetchMe", "sendTap"])

        let api = MockAPIClient(latency: .zero)
        await api.inject(outcomes["sendTap"], for: "sendTap")
        await #expect(throws: APIError.rateLimited(retryAfter: 600)) {
            try await api.sendTap(to: "p01")
        }
        // Other endpoints are untouched.
        _ = try? await api.fetchMe()
    }

    @Test("Reset filters keeps the quick filters the sheet doesn't show")
    func clearedFilters() {
        var query = NearbyQuery()
        query.onlineOnly = true
        query.minAge = 21
        query.maxAge = 30
        query.positions = [.top]
        query.tags = ["Chess"]
        query.lookingFor = [.chat]
        let cleared = FilterSheet.cleared(query)
        #expect(cleared.onlineOnly)
        #expect(!cleared.usesAdvancedFilters)
        #expect(cleared.lookingFor.isEmpty)
    }
}

@MainActor
struct EditProfileSaveTests {
    private func makeAPI() -> MockAPIClient { MockAPIClient(latency: .zero) }

    @Test("A photo that finishes uploading after the edit was discarded is deleted, not left on the profile")
    func uploadLandingAfterDiscard() async throws {
        let api = makeAPI()
        let a = try await api.uploadPhoto(jpegData: Data([0xFF]))
        let sync = ProfilePhotoSync(photos: [a])

        // The sheet closes while an upload is still running…
        await sync.discardUnsavedUploads(using: api)
        #expect(sync.isAbandoned)
        // …and then the upload lands on the server.
        let late = try await api.uploadPhoto(jpegData: Data([0xFF]))
        let kept = await sync.didUpload(late, using: api)

        #expect(!kept)
        #expect(sync.unsavedUploads.isEmpty)
        #expect(try await api.fetchMe().photos.map(\.id) == [a.id])
    }

    @Test("Uploads during a live edit are still recorded")
    func uploadDuringEdit() async throws {
        let api = makeAPI()
        let sync = ProfilePhotoSync(photos: [])
        let x = try await api.uploadPhoto(jpegData: Data([0xFF]))
        #expect(await sync.didUpload(x, using: api))
        #expect(sync.unsavedUploads == [x.id])
        #expect(sync.committedPhotos.isEmpty)
    }

    @Test("Details and photos both saved")
    func saved() async throws {
        let api = makeAPI()
        let a = try await api.uploadPhoto(jpegData: Data([0xFF]))
        let b = try await api.uploadPhoto(jpegData: Data([0xFF]))
        var draft = try await api.fetchMe()
        let sync = ProfilePhotoSync(photos: draft.photos)
        draft.headline = "New headline"
        draft.photos = [b, a]

        guard case .saved(let profile) = await EditProfileView.saveChanges(draft, photoSync: sync, using: api) else {
            Issue.record("expected .saved")
            return
        }
        #expect(profile.headline == "New headline")
        #expect(profile.photos.map(\.id) == [b.id, a.id])
    }

    @Test("If the details save but the photos don't, the outcome says the details are live")
    func detailsOnly() async throws {
        let api = makeAPI()
        let a = try await api.uploadPhoto(jpegData: Data([0xFF]))
        let b = try await api.uploadPhoto(jpegData: Data([0xFF]))
        var draft = try await api.fetchMe()
        let sync = ProfilePhotoSync(photos: draft.photos)
        let x = try await api.uploadPhoto(jpegData: Data([0xFF]))
        _ = await sync.didUpload(x, using: api)
        draft.headline = "Something I regret"
        draft.photos = [x, b, a]
        await api.inject(.fail(URLError(.notConnectedToInternet)), for: "reorderPhotos")

        guard case .detailsOnly(let profile, let error) = await EditProfileView.saveChanges(draft, photoSync: sync, using: api) else {
            Issue.record("expected .detailsOnly")
            return
        }
        // The headline really is on the server, so the screen must treat it as saved.
        #expect(try await api.fetchMe().headline == "Something I regret")
        #expect(profile.headline == "Something I regret")
        // The photos it reports are the ones from before this edit, not the unsaved upload.
        #expect(profile.photos.map(\.id) == [a.id, b.id])
        #expect(EditProfileView.detailsOnlyMessage(for: error)
            == "Your details were saved, but your photo changes weren't. Check your connection and try again.")
        // So discarding now would only lose the photo changes.
        #expect(EditProfileView.hasUnsavedChanges(initial: profile, draft: draft, pendingTag: ""))
        var detailsOnlyDraft = draft
        detailsOnlyDraft.photos = profile.photos
        #expect(!EditProfileView.hasUnsavedChanges(initial: profile, draft: detailsOnlyDraft, pendingTag: ""))
    }

    @Test("A self-explaining error still says the details were saved")
    func detailsOnlyRateLimited() {
        #expect(EditProfileView.detailsOnlyMessage(for: APIError.rateLimited(retryAfter: 120))
            == "Your details were saved, but your photo changes weren't. You're doing that too often. Try again in 2 min.")
    }

    @Test("If the details fail, nothing was saved")
    func failed() async throws {
        let api = makeAPI()
        var draft = try await api.fetchMe()
        let before = draft.headline
        let sync = ProfilePhotoSync(photos: draft.photos)
        draft.headline = "Never saved"
        await api.inject(.fail(APIError.server(status: 500, message: nil)), for: "updateMe")

        guard case .failed = await EditProfileView.saveChanges(draft, photoSync: sync, using: api) else {
            Issue.record("expected .failed")
            return
        }
        await api.inject(nil, for: "updateMe")
        #expect(try await api.fetchMe().headline == before)
    }
}
