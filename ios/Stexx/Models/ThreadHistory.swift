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

    init(messages: [Message] = [], olderCursor: Message.ID? = nil) {
        self.messages = messages
        self.olderCursor = olderCursor
    }

    var hasOlder: Bool { olderCursor != nil }

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
    mutating func applyLatest(_ page: Page<Message>, myID: Profile.ID) {
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
    }

    /// An older page arrived (fetched with `before: olderCursor`). Messages
    /// already shown are skipped, so a page that overlaps what's on screen
    /// (a message arrived and shifted the window) never duplicates one.
    ///
    /// Returns the message that was at the top before, which the thread
    /// keeps in place (`scrollAnchor`), so the screen doesn't jump.
    @discardableResult
    mutating func applyOlder(_ page: Page<Message>) -> Message? {
        let anchor = messages.first
        let fresh = page.items.filter { !Self.contains($0, in: messages) }
        messages = fresh + messages
        olderCursor = page.nextCursor
        return anchor
    }

    /// The older page's cursor no longer exists on the server (that message
    /// expired or was deleted): start again from the newest page. Only
    /// messages that never reached the server stay.
    mutating func restart() {
        messages = messages.filter { $0.status == .sending || $0.status == .failed }
        olderCursor = nil
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
