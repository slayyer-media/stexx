import Foundation
import Testing
@testable import Stexx

struct MockAPIClientTests {
    private func makeClient() -> MockAPIClient {
        MockAPIClient(latency: .zero)
    }

    @Test("Nearby is sorted by distance and paginates")
    func nearbySortedAndPaged() async throws {
        let api = makeClient()
        var query = NearbyQuery()
        query.limit = 5

        let first = try await api.nearby(query)
        #expect(first.items.count == 5)
        let distances = first.items.compactMap(\.distanceMeters)
        #expect(distances == distances.sorted())

        let cursor: String = try #require(first.nextCursor)
        query.cursor = cursor
        let second = try await api.nearby(query)
        #expect(Set(first.items.map(\.id)).isDisjoint(with: second.items.map(\.id)))
    }

    @Test("Online filter only returns online members")
    func onlineOnly() async throws {
        var query = NearbyQuery()
        query.onlineOnly = true
        let page = try await makeClient().nearby(query)
        #expect(!page.items.isEmpty)
        #expect(page.items.allSatisfy { $0.isOnline })
    }

    @Test("Blocked members disappear from the grid and chats")
    func blockingHides() async throws {
        let api = makeClient()
        try await api.block(profileID: "p01")

        let nearby = try await api.nearby(NearbyQuery(limit: 100))
        #expect(!nearby.items.contains { $0.id == "p01" })

        let conversations = try await api.conversations()
        #expect(!conversations.contains { $0.participant.id == "p01" })

        await #expect(throws: APIError.notFound) {
            try await api.profile(id: "p01")
        }
    }

    @Test("Sending is idempotent per client ID")
    func idempotentSend() async throws {
        let api = makeClient()
        let conversation = try await api.openConversation(with: "p02")
        let draft = MessageDraft(clientID: "abc", text: "hello")

        let first = try await api.send(draft, in: conversation.id)
        let second = try await api.send(draft, in: conversation.id)
        #expect(first.id == second.id)

        let page = try await api.messages(in: conversation.id, before: nil)
        #expect(page.items.filter { $0.clientID == "abc" }.count == 1)
    }

    @Test("Seed conversations have unread counts")
    func unreadCounts() async throws {
        let conversations = try await makeClient().conversations()
        let eigenbro = try #require(conversations.first { $0.participant.id == "p01" })
        #expect(eigenbro.unreadCount == 2)
    }
}

@MainActor
struct AppStateTests {
    private func makeState() -> AppState {
        let suite = "stexx.tests.\(UUID().uuidString)"
        return AppState(defaults: UserDefaults(suiteName: suite)!, sessionStore: InMemorySessionStore())
    }

    @Test("Signing in requires the 18+ confirmation")
    func signInNeedsAgeGate() {
        let state = makeState()
        state.signIn(MockData.session)
        #expect(!state.isSignedIn)
        state.confirmAge()
        #expect(state.isSignedIn)
    }

    @Test("Deleting the account wipes local state")
    func wipe() {
        let state = makeState()
        state.confirmAge()
        state.signIn(MockData.session)
        state.adoptServerPrivacy(PrivacySettings(hideDistance: true))

        state.signOut(wipeLocalData: true)
        #expect(!state.isSignedIn)
        #expect(!state.isAgeConfirmed)
        #expect(state.privacy == PrivacySettings())
        #expect(state.privacyStatus == .loading)
    }

    @Test("Plus-gated actions open the paywall without Plus")
    func requirePlus() {
        let state = makeState()
        #expect(!state.requirePlus())
        #expect(state.isPaywallPresented)
        state.isPaywallPresented = false
        state.hasPlus = true
        #expect(state.requirePlus())
        #expect(!state.isPaywallPresented)
    }
}
