import Foundation
import Testing
@testable import Stexx

/// The received taps inbox: wire decoding, the mock backend, and how
/// `ChatStore` merges live taps and folds the unseen count into the badge.
struct TapsDecodingTests {
    @Test("A GET /me/taps page decodes, dates with or without fractional seconds")
    func decodesPage() throws {
        let json = #"""
        {"items":[
          {"from":\#(RealtimeFixtures.profile),"sentAt":"2026-11-17T20:31:00Z","isNew":true},
          {"from":\#(RealtimeFixtures.profile.replacingOccurrences(of: "\"p1\"", with: "\"p2\"")),"sentAt":"2026-11-16T08:00:00.250Z","isNew":false}
        ],"nextCursor":"WyIyMDI2Il0","unseenCount":1}
        """#
        let page = try JSONDecoder.stexx().decode(TapsPage.self, from: Data(json.utf8))
        #expect(page.items.map(\.id) == ["p1", "p2"])
        #expect(page.items[0].isNew)
        #expect(!page.items[1].isNew)
        #expect(page.items[0].from.displayName == "Eigenbro")
        #expect(page.nextCursor == "WyIyMDI2Il0")
        #expect(page.unseenCount == 1)
    }

    @Test("The last page has a null cursor; a missing required key fails")
    func nullCursorAndStrictness() throws {
        let last = try JSONDecoder.stexx().decode(TapsPage.self, from: Data(#"{"items":[],"nextCursor":null,"unseenCount":0}"#.utf8))
        #expect(last.items.isEmpty)
        #expect(last.nextCursor == nil)
        #expect(throws: (any Error).self) {
            try JSONDecoder.stexx().decode(TapsPage.self, from: Data(#"{"items":[],"nextCursor":null}"#.utf8))
        }
    }

    @Test("A live tap.received becomes a new inbox entry")
    func fromRealtime() {
        let profile = MockData.profiles[0]
        let sentAt = Date(timeIntervalSince1970: 1_000)
        let tap = ReceivedTap(RealtimeEvent.Tap(from: profile, sentAt: sentAt))
        #expect(tap.id == profile.id)
        #expect(tap.sentAt == sentAt)
        #expect(tap.isNew)
        let undated = ReceivedTap(RealtimeEvent.Tap(from: profile, sentAt: nil), receivedAt: Date(timeIntervalSince1970: 5))
        #expect(undated.sentAt == Date(timeIntervalSince1970: 5))
    }
}

struct MockTapsTests {
    @Test("The mock seeds taps newest first, one per sender, and counts the new ones")
    func seeded() async throws {
        let api = MockAPIClient(latency: .zero)
        let page = try await api.taps(before: nil)
        #expect(page.items.count == MockData.seedTaps.count)
        #expect(Set(page.items.map(\.id)).count == page.items.count)
        #expect(page.items.map(\.sentAt) == page.items.map(\.sentAt).sorted(by: >))
        #expect(page.unseenCount == page.items.filter(\.isNew).count)
        #expect(page.unseenCount == 3)
        #expect(page.nextCursor == nil)
    }

    @Test("Marking seen clears the new flags; blocked senders disappear")
    func seenAndBlocked() async throws {
        let api = MockAPIClient(latency: .zero)
        try await api.markTapsSeen()
        let seen = try await api.taps(before: nil)
        #expect(seen.unseenCount == 0)
        #expect(seen.items.allSatisfy { !$0.isNew })

        let first = try #require(seen.items.first)
        try await api.block(profileID: first.id)
        let afterBlock = try await api.taps(before: nil)
        #expect(!afterBlock.items.contains { $0.id == first.id })
    }
}

@MainActor
struct ChatStoreTapsTests {
    private func tap(_ id: Profile.ID, minutesAgo: Double = 0, isNew: Bool = true) -> ReceivedTap {
        let profile = MockData.profiles.first { $0.id == id } ?? MockData.profiles[0]
        return ReceivedTap(from: profile, sentAt: Date.now.addingTimeInterval(-minutesAgo * 60), isNew: isNew)
    }

    private func loadedStore(_ api: MockAPIClient = MockAPIClient(latency: .zero)) async -> ChatStore {
        let store = ChatStore(api: api)
        await store.loadIfNeeded()
        return store
    }

    @Test("Launch loads conversations and the first page of taps")
    func launchLoadsTaps() async {
        let store = await loadedStore()
        #expect(store.hasLoaded)
        #expect(store.hasLoadedTaps)
        #expect(store.taps.count == MockData.seedTaps.count)
        #expect(store.tapsUnseen == 3)
        #expect(store.tapsErrorMessage == nil)
    }

    @Test("New taps are part of the Chats badge")
    func badgeIncludesTaps() async {
        let store = await loadedStore()
        let messages = store.conversations.reduce(0) { $0 + ($1.isMuted ? 0 : $1.unreadCount) }
        #expect(messages > 0)
        #expect(store.unreadTotal == messages + 3)
        await store.markTapsSeen()
        #expect(store.unreadTotal == messages)
    }

    @Test("A live tap from someone new goes on top and raises the count")
    func liveTapFromNewSender() async throws {
        let store = await loadedStore()
        let before = store.unreadTotal
        store.apply(.tapReceived(RealtimeEvent.Tap(from: MockData.profiles[0], sentAt: .now)), myID: MockData.myID)
        #expect(store.taps.first?.id == MockData.profiles[0].id)
        #expect(store.taps.first?.isNew == true)
        #expect(store.tapsUnseen == 4)
        #expect(store.unreadTotal == before + 1)
    }

    @Test("A sender who taps again moves to the top; counted once while still new")
    func repeatSenderMovesUp() async throws {
        let store = await loadedStore()
        let seenSender = try #require(store.taps.last { !$0.isNew })
        let newSender = try #require(store.taps.first { $0.isNew && $0.id != store.taps.first?.id })
        let count = store.taps.count

        // An already-new sender: moves up, no extra count.
        store.receive(tap(newSender.id))
        #expect(store.taps.first?.id == newSender.id)
        #expect(store.tapsUnseen == 3)
        // A seen sender: moves up and becomes new again.
        store.receive(tap(seenSender.id))
        #expect(store.taps.first?.id == seenSender.id)
        #expect(store.taps.first?.isNew == true)
        #expect(store.tapsUnseen == 4)
        // Still one row per sender.
        #expect(store.taps.count == count)
        #expect(Set(store.taps.map(\.id)).count == count)
    }

    @Test("Replays of a tap we already have change nothing")
    func replayIgnored() async throws {
        let store = await loadedStore()
        await store.markTapsSeen()
        let existing = try #require(store.taps.last)
        store.receive(ReceivedTap(from: existing.from, sentAt: existing.sentAt, isNew: true))
        store.receive(ReceivedTap(from: existing.from, sentAt: existing.sentAt.addingTimeInterval(-60), isNew: true))
        #expect(store.tapsUnseen == 0)
        #expect(store.taps.last?.id == existing.id)
    }

    @Test("Opening the taps screen clears the count and moves the server watermark")
    func markSeen() async throws {
        let api = MockAPIClient(latency: .zero)
        let store = await loadedStore(api)
        await store.markTapsSeen()
        #expect(store.tapsUnseen == 0)
        #expect(store.taps.allSatisfy { !$0.isNew })
        #expect(try await api.taps(before: nil).unseenCount == 0)
        // A reload keeps it at zero (the server agrees).
        await store.loadTaps()
        #expect(store.tapsUnseen == 0)
    }

    @Test("Resync refetches the first page (taps received while offline show up)")
    func resyncRefetches() async throws {
        let api = MockAPIClient(latency: .zero)
        let store = await loadedStore(api)
        await store.markTapsSeen()
        // Tapped while the socket was down: no live event, only the list has it.
        await api.receiveTap(from: "p01")
        store.resync()
        for _ in 0..<100 where store.tapsUnseen == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.taps.first?.id == "p01")
        #expect(store.tapsUnseen == 1)
    }

    @Test("A live tap that arrives during a load is kept when the older snapshot lands")
    func liveTapDuringLoad() async throws {
        let api = MockAPIClient(latency: .milliseconds(150))
        let store = ChatStore(api: api)
        let load = Task { await store.loadTaps() }
        try await Task.sleep(for: .milliseconds(30))
        #expect(store.isLoadingTaps)
        store.receive(tap("p01"))
        await load.value
        #expect(store.taps.first?.id == "p01")
        #expect(store.tapsUnseen == 4)
        #expect(store.taps.count == MockData.seedTaps.count + 1)
    }

    @Test("Marking taps seen while the next page loads keeps that page (infinite scroll doesn't stall)")
    func markSeenDuringLoadMore() async throws {
        let api = MockAPIClient(latency: .milliseconds(150))
        await api.setTapsPageSize(2)
        let store = ChatStore(api: api)
        await store.loadTaps()
        #expect(store.taps.map(\.id) == ["p06", "p02"])
        #expect(store.tapsNextCursor != nil)

        // Page two (p15 is still new on the server) is in flight when a live
        // tap makes the open taps screen mark everything seen.
        let more = Task { await store.loadMoreTaps() }
        try await Task.sleep(for: .milliseconds(30))
        #expect(store.isLoadingTaps)
        await store.markTapsSeen()
        await more.value

        #expect(store.taps.map(\.id) == ["p06", "p02", "p15", "p09"])
        #expect(store.taps.allSatisfy { !$0.isNew })
        #expect(store.tapsUnseen == 0)
        #expect(!store.isLoadingTaps)
        #expect(store.tapsNextCursor != nil)

        // Scrolling on still works.
        await store.loadMoreTaps()
        #expect(store.taps.count == 6)
    }

    @Test("Marking taps seen while the first page loads drops that stale page")
    func markSeenDuringFirstLoad() async throws {
        let api = MockAPIClient(latency: .milliseconds(150))
        let store = ChatStore(api: api)
        let load = Task { await store.loadTaps() }
        try await Task.sleep(for: .milliseconds(30))
        await store.markTapsSeen()
        await load.value
        #expect(store.tapsUnseen == 0)
        #expect(!store.isLoadingTaps)
        // The next load reflects the moved watermark.
        await store.loadTaps()
        #expect(store.tapsUnseen == 0)
        #expect(store.taps.count == MockData.seedTaps.count)
        #expect(store.taps.allSatisfy { !$0.isNew })
    }

    @Test("Blocking someone drops their tap and its count")
    func blockDropsTap() async throws {
        let store = await loadedStore()
        let newest = try #require(store.taps.first { $0.isNew })
        store.removeConversations(with: newest.id)
        #expect(!store.taps.contains { $0.id == newest.id })
        #expect(store.tapsUnseen == 2)
    }

    @Test("Signing out clears taps")
    func resetClears() async {
        let store = await loadedStore()
        store.reset()
        #expect(store.taps.isEmpty)
        #expect(store.tapsUnseen == 0)
        #expect(!store.hasLoadedTaps)
        #expect(store.unreadTotal == 0)
    }

    @Test("A failed taps load keeps the chat list error-free")
    func tapsErrorIsSeparate() async {
        let api = MockAPIClient(latency: .zero)
        let store = ChatStore(api: api)
        await api.setFailsConversationList(true)
        await store.loadIfNeeded()
        #expect(store.errorMessage != nil)
        #expect(store.conversations.isEmpty)
        // Taps still loaded: the Taps row works while chats are down.
        #expect(store.hasLoadedTaps)
        #expect(store.tapsErrorMessage == nil)

        // Recovering clears the chat error.
        await api.setFailsConversationList(false)
        await store.load()
        #expect(store.errorMessage == nil)
        #expect(!store.conversations.isEmpty)
    }

    @Test("A failed refresh keeps cached conversations (inline banner state)")
    func staleKeepsConversations() async {
        let api = MockAPIClient(latency: .zero)
        let store = await loadedStore(api)
        let cached = store.conversations
        await api.setFailsConversationList(true)
        await store.refresh()
        #expect(store.errorMessage != nil)
        #expect(store.conversations == cached)
    }
}

/// What the Taps row in Chats and the taps screen's label say.
@MainActor
struct TapsCopyTests {
    private func summary(_ store: ChatStore) -> String {
        TapsCopy.rowSummary(
            latest: store.taps.first,
            unseen: store.tapsUnseen,
            hasLoaded: store.hasLoadedTaps,
            failed: store.tapsErrorMessage != nil
        )
    }

    @Test("Server down on a cold launch: the Taps row says taps failed, not \"No taps yet\"")
    func coldLaunchOffline() async {
        let api = MockAPIClient(latency: .zero)
        await api.setFailsConversationList(true)
        await api.setFailsTaps(true)
        let store = ChatStore(api: api)
        await store.loadIfNeeded()
        #expect(store.errorMessage != nil)
        #expect(store.tapsErrorMessage != nil)
        #expect(store.taps.isEmpty)
        #expect(summary(store) == "Couldn't load taps")

        // Back online: the real summary returns.
        await api.setFailsConversationList(false)
        await api.setFailsTaps(false)
        await store.refresh()
        #expect(store.tapsErrorMessage == nil)
        #expect(summary(store) == "3 people tapped you")
    }

    @Test("A failed refresh keeps the cached latest tap in the Taps row")
    func failedRefreshKeepsCachedTap() async throws {
        let api = MockAPIClient(latency: .zero)
        let store = ChatStore(api: api)
        await store.loadIfNeeded()
        await store.markTapsSeen()
        let latest = try #require(store.taps.first)
        await api.setFailsTaps(true)
        await store.loadTaps()
        #expect(store.tapsErrorMessage != nil)
        #expect(store.taps.first == latest)
        #expect(summary(store) == "Latest: \(latest.from.displayName)")
    }

    @Test("Empty inbox: neutral while the first load runs, \"No taps yet\" only once it succeeded")
    func emptyStates() {
        #expect(TapsCopy.rowSummary(latest: nil, unseen: 0, hasLoaded: false, failed: false) == "See who tapped you")
        #expect(TapsCopy.rowSummary(latest: nil, unseen: 0, hasLoaded: true, failed: false) == "No taps yet")
        #expect(TapsCopy.rowSummary(latest: nil, unseen: 0, hasLoaded: true, failed: true) == "Couldn't load taps")
    }

    @Test("New taps name a single sender or count several")
    func unseenSummaries() {
        let tap = ReceivedTap(RealtimeEvent.Tap(from: MockData.profiles[0], sentAt: .now))
        let name = MockData.profiles[0].displayName
        #expect(TapsCopy.rowSummary(latest: tap, unseen: 1, hasLoaded: true, failed: false) == "\(name) tapped you")
        #expect(TapsCopy.rowSummary(latest: tap, unseen: 2, hasLoaded: true, failed: true) == "2 people tapped you")
    }

    @Test("The taps screen's count label is pluralized")
    func countLabel() {
        #expect(TapsCopy.countLabel(count: 1, new: 0) == "1 tap")
        #expect(TapsCopy.countLabel(count: 1, new: 1) == "1 tap, 1 new")
        #expect(TapsCopy.countLabel(count: 8, new: 0) == "8 taps")
        #expect(TapsCopy.countLabel(count: 8, new: 3) == "8 taps, 3 new")
    }
}
