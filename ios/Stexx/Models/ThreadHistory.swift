import Foundation

/// The messages a chat thread shows and where its older history continues.
///
/// `GET /conversations/{id}/messages` returns the newest page first; each
/// page is oldest-first and its `nextCursor` (the page's oldest message) is
/// passed as `before` to fetch the page before it. The thread starts with
/// the newest page and prepends older ones as the user scrolls up.
///
/// End-to-end encrypted messages need nothing special here: every page goes
/// through `E2EAPIClient.messages`, which shows the local plaintext of
/// messages this phone already decrypted (or sent) and the "not available on
/// this phone" placeholder for ones it never had (e.g. before a reinstall).
struct ThreadHistory: Equatable, Sendable {
    /// Oldest first. Includes optimistic messages still sending or failed.
    var messages: [Message] = []
    /// `before` for the next older page; `nil` once the start of the thread
    /// is on screen (or before the first page has loaded).
    private(set) var olderCursor: Message.ID?
    /// The newest page has arrived at least once. Until then what's on
    /// screen (a send that failed, a live event) isn't the thread's history.
    private(set) var hasLoadedLatest = false

    init(messages: [Message] = [], olderCursor: Message.ID? = nil) {
        self.messages = messages
        self.olderCursor = olderCursor
    }

    var hasOlder: Bool { olderCursor != nil }

    /// Whether the thread shows its load error with Retry: the load failed
    /// and the newest page never arrived. Messages shown meanwhile (my own
    /// failed send) don't hide it, or the thread would pass for a new chat.
    /// A failed refetch of a thread that did load keeps what's there.
    func showsLoadError(hasError: Bool, isLoading: Bool) -> Bool {
        hasError && !isLoading && !hasLoadedLatest
    }

    /// Whether `message` is already shown: the same server ID, or my own
    /// optimistic copy with the same client ID.
    static func contains(_ message: Message, in messages: [Message]) -> Bool {
        messages.contains { Self.isSame($0, message) }
    }

    static func isSame(_ a: Message, _ b: Message) -> Bool {
        a.id == b.id || (a.clientID != nil && a.clientID == b.clientID && a.senderID == b.senderID)
    }

    /// The newest page arrived (the first load, a resync or a refetch).
    ///
    /// Reconciled with what's shown (`ChatStore.reconcile`): messages older
    /// than the page are kept while the server has older ones (they're
    /// older pages already loaded); without older ones the page is the whole
    /// thread and anything missing from it is gone. The cursor only moves
    /// when nothing older than this page is on screen: otherwise it already
    /// points before the oldest loaded message.
    ///
    /// A kept older page isn't re-checked against the server, so anything
    /// whose timer ran out by `now` goes here (`pruneExpired`): the server
    /// has deleted it, and a resync mustn't keep it on screen.
    mutating func applyLatest(_ page: Page<Message>, myID: Profile.ID, now: Date = .now) {
        let merged = ChatStore.reconcile(
            snapshot: page.items,
            with: messages,
            myID: myID,
            keepsOlder: page.nextCursor != nil
        )
        let oldestInPage = page.items.first?.sentAt
        let showsOlder = oldestInPage.map { oldest in
            merged.contains { $0.sentAt < oldest && $0.status != .sending && $0.status != .failed }
        } ?? false
        if !showsOlder { olderCursor = page.nextCursor }
        messages = merged
        hasLoadedLatest = true
        pruneExpired(now: now)
    }

    /// An older page arrived (fetched with `before: olderCursor`). Messages
    /// already shown are skipped, so a page that overlaps what's on screen
    /// (a message arrived and shifted the window) never duplicates one.
    ///
    /// Returns the message that was at the top before, which the thread
    /// keeps in place (`scrollAnchor`), so the screen doesn't jump.
    @discardableResult
    mutating func applyOlder(_ page: Page<Message>, now: Date = .now) -> Message? {
        let anchor = messages.first
        let fresh = page.items.filter { !Self.contains($0, in: messages) && !Self.hasExpired($0, at: now) }
        messages = fresh + messages
        olderCursor = page.nextCursor
        return anchor
    }

    /// Drops messages whose timer ran out by `now` (`expiresAt`): the
    /// server deletes them then, with their media. Lets an open thread hide
    /// them on time without a refetch (`ChatThreadView` calls it at
    /// `nextExpiry`). Returns whether anything went.
    @discardableResult
    mutating func pruneExpired(now: Date = .now) -> Bool {
        let count = messages.count
        messages.removeAll { Self.hasExpired($0, at: now) }
        return messages.count != count
    }

    /// The soonest `expiresAt` still ahead of `now`, if any: when the
    /// thread next has to prune.
    func nextExpiry(after now: Date = .now) -> Date? {
        messages.lazy
            .filter { $0.status != .sending && $0.status != .failed }
            .compactMap(\.expiresAt)
            .filter { $0 > now }
            .min()
    }

    /// A message the server has deleted by `now` because its timer ran
    /// out. Unsent ones never had a timer running.
    static func hasExpired(_ message: Message, at now: Date) -> Bool {
        guard message.status != .sending, message.status != .failed, let expiresAt = message.expiresAt else { return false }
        return expiresAt <= now
    }

    /// The older page's cursor no longer exists on the server (that message
    /// expired or was deleted): start again from the newest page. Only
    /// messages that never reached the server stay.
    mutating func restart() {
        messages = messages.filter { $0.status == .sending || $0.status == .failed }
        olderCursor = nil
    }

    /// The server's copy of a send that failed on this phone, if a refetch
    /// shows it arrived after all: the same client ID, a server ID and a
    /// settled status. `nil` while it's still only the local failed copy
    /// (or a retry of it is in flight).
    static func deliveredCopy(of failed: Message, in messages: [Message]) -> Message? {
        messages.first {
            isSame($0, failed) && $0.id != failed.id && $0.status != .sending && $0.status != .failed
        }
    }

    /// The bubble to keep at the top after older messages were prepended:
    /// the one that was first before, if it's still there.
    static func scrollAnchor(previousFirst: Message?, in messages: [Message]) -> String? {
        guard let previousFirst,
              let kept = messages.first(where: { isSame($0, previousFirst) })
        else { return nil }
        return kept.bubbleKey
    }

    /// Whether the scroll view is close enough to the top to fetch the next
    /// older page (`ChatThreadView`, `onScrollGeometryChange`).
    static func isNearTop(contentOffsetY: CGFloat, topInset: CGFloat, threshold: CGFloat = 400) -> Bool {
        contentOffsetY + topInset < threshold
    }
}

extension Message {
    /// Stable identity across the optimistic → sent swap (the server's copy
    /// gets a new `id` but keeps the client ID).
    var bubbleKey: String { "\(senderID)|\(clientID ?? id)" }
}
