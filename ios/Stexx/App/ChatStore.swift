import Foundation
import Observation

/// Conversation list shared by the Chats tab (and its badge) and threads.
/// Realtime events (`RealtimeClient`) land here and are fanned out to open
/// threads via `threadUpdates(for:)`.
@MainActor
@Observable
final class ChatStore {
    private(set) var conversations: [Conversation] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    var errorMessage: String?
    /// The most recent tap someone sent you (from `tap.received`).
    private(set) var latestTap: RealtimeEvent.Tap?
    /// View-once photos opened on this phone since launch: shown as
    /// "Opened" right away, even if telling the server failed.
    private(set) var openedViewOnce: Set<Message.ID> = []

    /// Change to a thread pushed to its open view.
    enum ThreadUpdate: Hashable, Sendable {
        case created(Message)
        /// A message already in the thread changed (`message.updated`).
        case updated(Message)
        case read(RealtimeEvent.ReadReceipt)
        /// Live events may have been missed (the socket was down): refetch
        /// the thread and reconcile it with `reconcile(snapshot:with:myID:)`.
        case resync
    }

    @ObservationIgnored private let api: any APIClient
    @ObservationIgnored private var threadContinuations: [Conversation.ID: [UUID: AsyncStream<ThreadUpdate>.Continuation]] = [:]
    /// Sanitized JPEGs of photo messages that haven't been sent yet, by
    /// client ID, so a failed send can be retried.
    @ObservationIgnored private var pendingPhotos: [String: Data] = [:]
    /// Bumped by every `load()` and by `reset()`: only the newest load may
    /// apply its result, and nothing started before a sign-out lands after it.
    @ObservationIgnored private var loadGeneration = 0
    /// Bumped by `reset()` (sign-out).
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private let defaults: UserDefaults
    /// View-once opens the server hasn't confirmed yet (offline), retried on
    /// the next resync or list load. Memory only: if the app quits first,
    /// the server's 14-day cap deletes the photo instead.
    @ObservationIgnored private var pendingViewOnceOpens: [Message.ID: Conversation.ID] = [:]

    init(api: any APIClient, defaults: UserDefaults = .standard) {
        self.api = api
        self.defaults = defaults
    }

    var unreadTotal: Int {
        conversations.reduce(0) { $0 + ($1.isMuted ? 0 : $1.unreadCount) }
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await load()
    }

    /// Fetches the conversation list. Concurrent loads are fine: only the
    /// most recently started one applies its result, and a load still in
    /// flight when the user signs out (`reset()`) is discarded.
    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        defer { if generation == loadGeneration { isLoading = false } }
        do {
            let fetched = try await api.conversations()
            guard generation == loadGeneration else { return }
            conversations = fetched
            hasLoaded = true
            errorMessage = nil
            markOpenThreadsRead()
            retryPendingViewOnceOpens()
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Catches up after the socket was down (reconnect, foreground): reloads
    /// the list and tells open threads to refetch.
    func resync() {
        for conversationID in threadContinuations.keys {
            broadcast(.resync, to: conversationID)
        }
        Task { await load() }
    }

    /// Open threads show everything, so the server's unread counts for them
    /// are cleared (e.g. messages that arrived while the socket was down).
    private func markOpenThreadsRead() {
        for index in conversations.indices
        where conversations[index].unreadCount > 0 && isThreadOpen(conversations[index].id) {
            conversations[index].unreadCount = 0
            let api = self.api
            let id = conversations[index].id
            Task { try? await api.markRead(conversationID: id) }
        }
    }

    func markRead(_ conversationID: Conversation.ID) async {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }),
              conversations[index].unreadCount > 0
        else { return }
        conversations[index].unreadCount = 0
        try? await api.markRead(conversationID: conversationID)
    }

    /// Updates the list after a message is sent from a thread.
    func didSend(_ message: Message, in conversation: Conversation) {
        var updated = conversations.first { $0.id == conversation.id } ?? conversation
        updated.lastMessage = message
        updated.updatedAt = message.sentAt
        conversations.removeAll { $0.id == conversation.id }
        conversations.insert(updated, at: 0)
    }

    func delete(_ conversationID: Conversation.ID) async {
        let previous = conversations
        let epoch = self.epoch
        conversations.removeAll { $0.id == conversationID }
        do {
            try await api.deleteConversation(conversationID)
        } catch {
            guard epoch == self.epoch else { return }
            conversations = previous
            errorMessage = error.localizedDescription
        }
    }

    /// Drops every conversation with a blocked member.
    func removeConversations(with profileID: Profile.ID) {
        conversations.removeAll { $0.participant.id == profileID }
    }

    func reset() {
        loadGeneration += 1
        epoch += 1
        conversations = []
        hasLoaded = false
        isLoading = false
        errorMessage = nil
        latestTap = nil
        pendingPhotos = [:]
        openedViewOnce = []
        pendingViewOnceOpens = [:]
    }

    // MARK: View-once photos

    /// The recipient is looking at a view-once photo: tell the server
    /// (`POST …/open`, which deletes it about 30 s later and, if they send
    /// read receipts, tells the sender). Returns the server's copy, or nil
    /// if that didn't work; a network failure is retried later
    /// (`retryPendingViewOnceOpens`), a 404 (gone, blocked) never.
    @discardableResult
    func openViewOnce(_ messageID: Message.ID, in conversationID: Conversation.ID) async -> Message? {
        openedViewOnce.insert(messageID)
        pendingViewOnceOpens[messageID] = conversationID
        return await sendViewOnceOpen(messageID, in: conversationID)
    }

    func hasOpenedViewOnce(_ messageID: Message.ID) -> Bool {
        openedViewOnce.contains(messageID)
    }

    private func sendViewOnceOpen(_ messageID: Message.ID, in conversationID: Conversation.ID) async -> Message? {
        let epoch = self.epoch
        do {
            let opened = try await api.openViewOnce(messageID: messageID, in: conversationID)
            guard epoch == self.epoch else { return nil }
            pendingViewOnceOpens[messageID] = nil
            if let index = conversations.firstIndex(where: { $0.id == conversationID }),
               let last = conversations[index].lastMessage, last.id == messageID {
                conversations[index].lastMessage = Self.updating(last, with: opened)
            }
            return opened
        } catch APIError.notFound {
            guard epoch == self.epoch else { return nil }
            pendingViewOnceOpens[messageID] = nil
            return nil
        } catch {
            return nil
        }
    }

    /// Opens that couldn't reach the server, tried again.
    func retryPendingViewOnceOpens() {
        for (messageID, conversationID) in pendingViewOnceOpens {
            Task { await sendViewOnceOpen(messageID, in: conversationID) }
        }
    }

    // MARK: Photo messages

    /// Sends a photo message (`APIClient.sendPhoto`): the (already
    /// sanitized) JPEG goes up as a private chat attachment
    /// (`POST /me/attachments`, never on the public profile), end-to-end
    /// encrypted when the chat is, and is sent as `attachmentPhotoID`.
    ///
    /// `isViewOnce` sends a view-once photo (no timer). Otherwise
    /// `expiresAfterSeconds == nil` sends the photo explicitly as not
    /// view-once (`isViewOnce: false`); otherwise the server would apply the
    /// sender's "expiring photos by default" setting.
    ///
    /// Re-sending the same `clientID` after a failure is safe: the server
    /// deduplicates by client ID, an unsent upload expires on its own, and an
    /// encrypted photo is re-sent with the same key.
    func sendPhoto(
        jpegData: Data? = nil,
        clientID: String,
        text: String? = nil,
        expiresAfterSeconds: Int?,
        isViewOnce: Bool = false,
        in conversation: Conversation
    ) async throws -> Message {
        if let jpegData { pendingPhotos[clientID] = jpegData }
        guard let jpeg = pendingPhotos[clientID] else { throw APIError.invalidResponse }
        let epoch = self.epoch

        let draft = MessageDraft(
            clientID: clientID,
            text: text,
            expiresAfterSeconds: isViewOnce ? nil : expiresAfterSeconds,
            isViewOnce: isViewOnce ? true : expiresAfterSeconds == nil ? false : nil
        )
        let sent = try await api.sendPhoto(jpegData: jpeg, draft: draft, in: conversation.id)
        guard epoch == self.epoch else { return sent }
        pendingPhotos[clientID] = nil
        didSend(sent, in: conversation)
        return sent
    }

    func hasPendingPhoto(clientID: String) -> Bool {
        pendingPhotos[clientID] != nil
    }

    // MARK: Realtime

    /// Live updates for one open thread. While at least one stream is
    /// subscribed the conversation counts as open: incoming messages are
    /// marked read instead of raising the unread count.
    func threadUpdates(for conversationID: Conversation.ID) -> AsyncStream<ThreadUpdate> {
        let (stream, continuation) = AsyncStream.makeStream(of: ThreadUpdate.self, bufferingPolicy: .bufferingNewest(100))
        let token = UUID()
        threadContinuations[conversationID, default: [:]][token] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.endThreadSubscription(conversationID, token: token) }
        }
        return stream
    }

    private func endThreadSubscription(_ conversationID: Conversation.ID, token: UUID) {
        threadContinuations[conversationID]?[token] = nil
        if threadContinuations[conversationID]?.isEmpty == true {
            threadContinuations[conversationID] = nil
        }
    }

    func isThreadOpen(_ conversationID: Conversation.ID) -> Bool {
        threadContinuations[conversationID]?.isEmpty == false
    }

    /// Applies a realtime event to the list and any open thread.
    func apply(_ event: RealtimeEvent, myID: Profile.ID) {
        switch event {
        case .messageCreated(let message):
            let isOpen = isThreadOpen(message.conversationID)
            let isMine = message.senderID == myID
            if let index = conversations.firstIndex(where: { $0.id == message.conversationID }) {
                var conversation = conversations[index]
                // Ignore replays of something we already have.
                if conversation.lastMessage?.id != message.id {
                    conversation.lastMessage = message
                    conversation.updatedAt = max(conversation.updatedAt, message.sentAt)
                    if !isMine && !isOpen { conversation.unreadCount += 1 }
                }
                conversations.remove(at: index)
                conversations.insert(conversation, at: 0)
            } else if hasLoaded {
                // A new conversation: fetch it with its participant.
                Task { await load() }
            }
            broadcast(.created(message), to: message.conversationID)
            if isOpen && !isMine {
                let api = self.api
                Task { try? await api.markRead(conversationID: message.conversationID) }
            }

        case .messageUpdated(let message):
            if let index = conversations.firstIndex(where: { $0.id == message.conversationID }),
               let last = conversations[index].lastMessage, last.id == message.id {
                conversations[index].lastMessage = Self.updating(last, with: message)
            }
            broadcast(.updated(message), to: message.conversationID)

        case .messageRead(let receipt):
            if let index = conversations.firstIndex(where: { $0.id == receipt.conversationID }),
               var last = conversations[index].lastMessage,
               last.senderID == myID,
               Self.readReceipt(receipt, covers: last) {
                last.status = .read
                conversations[index].lastMessage = last
            }
            broadcast(.read(receipt), to: receipt.conversationID)

        case .conversationUpdated(let conversation):
            var updated = conversation
            if isThreadOpen(conversation.id) { updated.unreadCount = 0 }
            conversations.removeAll { $0.id == conversation.id }
            let index = conversations.firstIndex { $0.updatedAt <= updated.updatedAt } ?? conversations.endIndex
            conversations.insert(updated, at: index)

        case .tapReceived(let tap):
            latestTap = tap

        case .identityChanged, .keysLow, .unknown:
            // Encryption events are handled by `E2EStatus`.
            break
        }
    }

    private func broadcast(_ update: ThreadUpdate, to conversationID: Conversation.ID) {
        guard let continuations = threadContinuations[conversationID] else { return }
        for continuation in continuations.values {
            continuation.yield(update)
        }
    }

    /// Merges a live update into a thread's messages (oldest first).
    /// Replaces the optimistic copy of my own message by client ID.
    static func merge(_ update: ThreadUpdate, into messages: inout [Message], myID: Profile.ID) {
        switch update {
        case .created(let message):
            if let index = messages.firstIndex(where: {
                $0.id == message.id || (message.clientID != nil && $0.clientID == message.clientID && $0.senderID == message.senderID)
            }) {
                // Keep a locally newer status (e.g. read) if the event is older.
                if messages[index].status != .read || message.status == .read {
                    messages[index] = message
                }
            } else {
                let index = messages.lastIndex { $0.sentAt <= message.sentAt }.map { $0 + 1 } ?? 0
                messages.insert(message, at: index)
            }
        case .updated(let message):
            // Only ever replaces: an update for a message this thread doesn't
            // show (an older page) isn't inserted.
            if let index = messages.firstIndex(where: { $0.id == message.id }) {
                messages[index] = updating(messages[index], with: message)
            }
        case .read(let receipt):
            for index in messages.indices where messages[index].senderID == myID {
                if messages[index].status != .sending, messages[index].status != .failed,
                   readReceipt(receipt, covers: messages[index]) {
                    messages[index].status = .read
                }
            }
        case .resync:
            break
        }
    }

    /// Combines a freshly fetched page of a thread (`snapshot`, oldest
    /// first) with what the view already shows (`local`).
    ///
    /// Keeps local messages the snapshot doesn't have yet: optimistic ones
    /// still sending or failed, and live events at least as new as the
    /// snapshot's newest message (they arrived while the fetch was in
    /// flight). Older local messages missing from the snapshot are gone on
    /// the server (expired, deleted) and are dropped.
    static func reconcile(snapshot: [Message], with local: [Message], myID: Profile.ID) -> [Message] {
        var result = snapshot
        let newest = snapshot.map(\.sentAt).max()
        for message in local {
            let isInSnapshot = snapshot.contains {
                $0.id == message.id
                    || (message.clientID != nil && $0.clientID == message.clientID && $0.senderID == message.senderID)
            }
            guard !isInSnapshot else { continue }
            let isUnsent = message.status == .sending || message.status == .failed
            let isNewer = newest.map { message.sentAt >= $0 } ?? true
            guard isUnsent || isNewer else { continue }
            merge(.created(message), into: &result, myID: myID)
        }
        return result
    }

    /// `current` replaced by a newer server copy, keeping a locally newer
    /// `read` status.
    static func updating(_ current: Message, with update: Message) -> Message {
        var merged = update
        if current.status == .read && update.status != .read { merged.status = .read }
        return merged
    }

    private static func readReceipt(_ receipt: RealtimeEvent.ReadReceipt, covers message: Message) -> Bool {
        if let ids = receipt.messageIDs { return ids.contains(message.id) }
        if let readAt = receipt.readAt { return message.sentAt <= readAt }
        return true
    }
}
