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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var path = NavigationPath()
    /// Flips once the first conversations are on screen, so rows fade in
    /// on the first appearance only (not every time a lazy row is reused).
    @State private var hasRevealed = false
    @State private var openCount = 0

    private var conversations: [Conversation] {
        chatStore.conversations.filter { !appState.blockedIDs.contains($0.participant.id) }
    }

    var body: some View {
        let visible = conversations
        let unread = visible.reduce(0) { $0 + $1.unreadCount }

        NavigationStack(path: $path) {
            List {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, conversation in
                    Button {
                        openCount += 1
                        path.append(ChatRoute(participant: conversation.participant, conversationID: conversation.id))
                    } label: {
                        ConversationRow(conversation: conversation, myID: appState.myID)
                    }
                    .buttonStyle(ConversationRowButtonStyle())
                    .overlay(alignment: .bottom) {
                        // Hairline inset to the text, not the avatar.
                        HairlineDivider(leadingInset: Theme.Spacing.screen + ConversationRow.avatarSize + Theme.Spacing.m)
                    }
                    .modifier(RowReveal(isShown: hasRevealed, index: index, reduceMotion: reduceMotion))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
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
            .collapsesTabHeaderLogo()
            .overlay {
                if chatStore.isLoading && visible.isEmpty {
                    ProgressView()
                        .tint(Theme.steel)
                } else if visible.isEmpty {
                    ContentUnavailableView {
                        VStack(spacing: Theme.Spacing.l) {
                            StexxMark(size: 48, glows: false)
                                .padding(Theme.Spacing.l)
                                .cellCorners()
                                .padding(.bottom, Theme.Spacing.s)
                            Text("No chats yet")
                                .stexxTitleStyle(.title)
                        }
                    } description: {
                        Text("Say hi to someone nearby. Worst case, you'll have a fun fact about bosons to share.")
                            .font(.stexxSub)
                            .foregroundStyle(Theme.steel)
                    }
                }
            }
            .tabHeader {
                TabHeaderTitle(String(localized: "Chats"))
            } trailing: {
                ChatListCount(unread: unread, count: visible.count)
            }
            .stexxBackground()
            .refreshable { await chatStore.load() }
            .task { await chatStore.loadIfNeeded() }
            .onChange(of: visible.isEmpty, initial: true) { _, isEmpty in
                guard !isEmpty, !hasRevealed else { return }
                hasRevealed = true
            }
            .sensoryFeedback(.selection, trigger: openCount)
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

// MARK: - Header

/// The mono count on the trailing side of the tab header.
private struct ChatListCount: View {
    let unread: Int
    let count: Int

    var body: some View {
        if unread > 0 {
            Text("\(unread) new")
                .monospacedDigit()
                .stexxLabelStyle(.label, color: Theme.frost)
                .lineLimit(1)
        } else if count > 0 {
            Text("All caught up")
                .stexxLabelStyle(.label, color: Theme.slate)
                .lineLimit(1)
        }
    }
}

// MARK: - Row

private struct ConversationRow: View {
    static let avatarSize: CGFloat = 52

    let conversation: Conversation
    let myID: Profile.ID

    private var hasUnread: Bool { conversation.unreadCount > 0 }

    private var preview: String {
        guard let message = conversation.lastMessage else { return String(localized: "New conversation") }
        let body = message.text
            ?? (message.attachment != nil || message.encryption == nil
                ? String(localized: "Photo")
                : String(localized: "Encrypted message"))
        return message.senderID == myID ? String(localized: "You: \(body)") : body
    }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            AvatarView(profile: conversation.participant, size: Self.avatarSize)

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                    Text(conversation.participant.displayName)
                        .font(.stexxHeadline)
                        .foregroundStyle(Theme.frost)
                        .lineLimit(1)
                    if conversation.isMuted {
                        Image(systemName: "bell.slash")
                            .font(.caption2)
                            .foregroundStyle(Theme.slate)
                            .accessibilityLabel("Muted")
                    }
                    Spacer(minLength: Theme.Spacing.s)
                    Text(StexxFormat.chatTimestamp(conversation.updatedAt))
                        .stexxLabelStyle(.micro, color: hasUnread ? Theme.frost : Theme.slate)
                        .lineLimit(1)
                }
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                    Text(preview)
                        .font(.stexxSub)
                        .foregroundStyle(hasUnread ? Theme.frost : Theme.steel)
                        .lineLimit(2)
                    Spacer(minLength: Theme.Spacing.s)
                    if hasUnread {
                        XXBadge(verbatim: conversation.unreadCount.formatted())
                            .accessibilityHidden(true)
                    }
                }
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, Theme.Spacing.screen)
        .padding(.vertical, Theme.Spacing.m + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityValue(hasUnread ? Text("\(conversation.unreadCount) unread") : Text(verbatim: ""))
        .accessibilityHint("Opens the conversation")
    }
}

/// Presses dim the row onto ink2; no scale, no chrome.
private struct ConversationRowButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Theme.ink2.opacity(configuration.isPressed ? 1 : 0))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(Motion.animation(Motion.press, reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

/// Rows fade up a few points on first appearance; a plain fade under
/// Reduce Motion.
private struct RowReveal: ViewModifier {
    let isShown: Bool
    let index: Int
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isShown ? 1 : 0)
            .offset(y: isShown || reduceMotion ? 0 : 6)
            .animation(
                reduceMotion
                    ? Motion.fade
                    : Motion.standard.delay(Double(min(index, 10)) * 0.025),
                value: isShown
            )
    }
}

#Preview {
    ChatListView()
        .previewEnvironment()
}
