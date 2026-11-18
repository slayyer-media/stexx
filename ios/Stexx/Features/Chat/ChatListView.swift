import SwiftUI

/// Where a chat thread is opened from: a conversation in the list, or a
/// profile (the conversation is created on demand).
struct ChatRoute: Hashable {
    let participant: Profile
    var conversationID: Conversation.ID?
}

struct ChatListView: View {
    @Environment(ChatStore.self) private var chatStore
    @Environment(AppState.self) private var appState

    private var conversations: [Conversation] {
        chatStore.conversations.filter { !appState.blockedIDs.contains($0.participant.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(conversations) { conversation in
                    NavigationLink(value: ChatRoute(participant: conversation.participant, conversationID: conversation.id)) {
                        ConversationRow(conversation: conversation, myID: appState.myID)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(Theme.hairline)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task { await chatStore.delete(conversation.id) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if chatStore.isLoading && conversations.isEmpty {
                    ProgressView()
                } else if conversations.isEmpty {
                    ContentUnavailableView(
                        "No chats yet",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Say hi to someone nearby. Worst case, you'll have a fun fact about bosons to share.")
                    )
                }
            }
            .stexxBackground(intensity: 0.7)
            .refreshable { await chatStore.load() }
            .task { await chatStore.loadIfNeeded() }
            .navigationTitle("Chats")
            .navigationDestination(for: ChatRoute.self) { route in
                ChatThreadView(route: route)
            }
            .navigationDestination(for: Profile.self) { profile in
                ProfileDetailView(profile: profile)
            }
        }
    }
}

private struct ConversationRow: View {
    let conversation: Conversation
    let myID: Profile.ID

    private var preview: String {
        guard let message = conversation.lastMessage else { return String(localized: "New conversation") }
        let body = message.text ?? String(localized: "Photo")
        return message.senderID == myID ? String(localized: "You: \(body)") : body
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            AvatarView(profile: conversation.participant, size: 54)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(conversation.participant.displayName)
                        .font(.stexxHeadline)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    Text(StexxFormat.chatTimestamp(conversation.updatedAt))
                        .font(.caption)
                        .foregroundStyle(conversation.unreadCount > 0 ? Theme.violetBright : Theme.textTertiary)
                }
                HStack {
                    Text(preview)
                        .font(.subheadline)
                        .foregroundStyle(conversation.unreadCount > 0 ? Theme.textPrimary : Theme.textSecondary)
                        .lineLimit(2)
                    Spacer(minLength: Theme.Spacing.s)
                    if conversation.unreadCount > 0 {
                        Text(conversation.unreadCount, format: .number)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Theme.violet, in: .capsule)
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }
}

#Preview {
    ChatListView()
        .previewEnvironment()
}
