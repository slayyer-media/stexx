import Foundation
import Observation

/// Conversation list shared by the Chats tab (and its badge) and threads.
@MainActor
@Observable
final class ChatStore {
    private(set) var conversations: [Conversation] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    var errorMessage: String?

    @ObservationIgnored private let api: any APIClient

    init(api: any APIClient) {
        self.api = api
    }

    var unreadTotal: Int {
        conversations.reduce(0) { $0 + ($1.isMuted ? 0 : $1.unreadCount) }
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await load()
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            conversations = try await api.conversations()
            hasLoaded = true
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
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
        conversations.removeAll { $0.id == conversationID }
        do {
            try await api.deleteConversation(conversationID)
        } catch {
            conversations = previous
            errorMessage = error.localizedDescription
        }
    }

    /// Drops every conversation with a blocked member.
    func removeConversations(with profileID: Profile.ID) {
        conversations.removeAll { $0.participant.id == profileID }
    }

    func reset() {
        conversations = []
        hasLoaded = false
    }
}
