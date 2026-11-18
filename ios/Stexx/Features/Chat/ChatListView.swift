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
    @State private var scroll = ChatListScrollTracker()
    /// Flips once the first conversations are on screen, so rows spring in
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
                ChatListHeader(unread: unread, count: visible.count)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: Theme.Spacing.l + 4, bottom: Theme.Spacing.s, trailing: Theme.Spacing.l + 4))

                ForEach(Array(visible.enumerated()), id: \.element.id) { index, conversation in
                    Button {
                        openCount += 1
                        path.append(ChatRoute(participant: conversation.participant, conversationID: conversation.id))
                    } label: {
                        ConversationRow(conversation: conversation, myID: appState.myID)
                    }
                    .buttonStyle(ConversationRowButtonStyle())
                    .modifier(SpringIn(isShown: hasRevealed, index: index, reduceMotion: reduceMotion))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: Theme.Spacing.m, bottom: 4, trailing: Theme.Spacing.m))
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
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, offset in
                scroll.offset = offset
            }
            .overlay {
                if chatStore.isLoading && visible.isEmpty {
                    ProgressView()
                } else if visible.isEmpty {
                    ContentUnavailableView {
                        VStack(spacing: Theme.Spacing.m) {
                            StexxMark(size: 64)
                            Text("No chats yet")
                                .font(.stexxName)
                                .tracking(Theme.Tracking.tight)
                                .foregroundStyle(Theme.textPrimary)
                        }
                    } description: {
                        Text("Say hi to someone nearby. Worst case, you'll have a fun fact about bosons to share.")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background { ChatListGlow(scroll: scroll) }
            .refreshable { await chatStore.load() }
            .task { await chatStore.loadIfNeeded() }
            .onChange(of: visible.isEmpty, initial: true) { _, isEmpty in
                guard !isEmpty, !hasRevealed else { return }
                hasRevealed = true
            }
            .sensoryFeedback(.selection, trigger: openCount)
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The big header lives in the list; the bar only shows a
                // compact title once it has scrolled away.
                ToolbarItem(placement: .principal) {
                    ChatListCompactTitle(scroll: scroll)
                }
            }
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

private struct ChatListHeader: View {
    let unread: Int
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Chats")
                .font(.stexxHero)
                .tracking(Theme.Tracking.display)
                .foregroundStyle(Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Theme.Spacing.s)
            if unread > 0 {
                XXBadge("\(unread) new")
            } else if count > 0 {
                Text("All caught up")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.top, Theme.Spacing.s)
    }
}

/// Inline title that fades in once the big header is scrolled off. Reads the
/// scroll offset itself so scrolling doesn't re-render the list.
private struct ChatListCompactTitle: View {
    let scroll: ChatListScrollTracker

    var body: some View {
        let isVisible = scroll.offset > 44
        Text("Chats")
            .font(.headline.weight(.heavy))
            .tracking(Theme.Tracking.tight)
            .foregroundStyle(Theme.textPrimary)
            .opacity(isVisible ? 1 : 0)
            .animation(.easeOut(duration: 0.18), value: isVisible)
            .accessibilityHidden(!isVisible)
    }
}

/// The drifting glow behind the list, nudged by scrolling.
private struct ChatListGlow: View {
    let scroll: ChatListScrollTracker

    var body: some View {
        GlowBackground(intensity: 0.7, scrollOffset: scroll.offset)
    }
}

@MainActor @Observable
private final class ChatListScrollTracker {
    var offset: CGFloat = 0
}

// MARK: - Row

private struct ConversationRow: View {
    let conversation: Conversation
    let myID: Profile.ID

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var hasUnread: Bool { conversation.unreadCount > 0 }

    private var preview: String {
        guard let message = conversation.lastMessage else { return String(localized: "New conversation") }
        let body = message.text ?? String(localized: "Photo")
        return message.senderID == myID ? String(localized: "You: \(body)") : body
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            ChatListAvatar(profile: conversation.participant, size: 56, glow: hasUnread ? 0.9 : 0.45)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(conversation.participant.displayName)
                        .font(.headline.weight(.heavy))
                        .tracking(Theme.Tracking.tight)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if conversation.isMuted {
                        Image(systemName: "bell.slash.fill")
                            .font(.caption2)
                            .foregroundStyle(Theme.textTertiary)
                            .accessibilityLabel("Muted")
                    }
                    Spacer()
                    Text(StexxFormat.chatTimestamp(conversation.updatedAt))
                        .font(.caption.weight(hasUnread ? .bold : .regular))
                        .foregroundStyle(hasUnread ? Theme.violetBright : Theme.textTertiary)
                }
                HStack(alignment: .center) {
                    Text(preview)
                        .font(.subheadline.weight(hasUnread ? .semibold : .regular))
                        .foregroundStyle(hasUnread ? Theme.textPrimary : Theme.textSecondary)
                        .lineLimit(2)
                    Spacer(minLength: Theme.Spacing.s)
                    if hasUnread {
                        XXBadge(verbatim: conversation.unreadCount.formatted())
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.m - 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { surface }
        .contentShape(.rect(cornerRadius: Theme.Radius.card - 4))
        .accessibilityElement(children: .combine)
        .accessibilityValue(hasUnread ? Text("\(conversation.unreadCount) unread") : Text(verbatim: ""))
        .accessibilityHint("Opens the conversation")
    }

    @ViewBuilder
    private var surface: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card - 4)
        if reduceTransparency {
            shape
                .fill(Theme.backgroundRaised)
                .overlay(shape.strokeBorder(hasUnread ? Theme.violet.opacity(0.6) : Theme.hairline, lineWidth: 1))
        } else {
            // A tinted wash rather than live glass: dozens of rows scroll
            // here, and a flat fill keeps that cheap.
            shape
                .fill(hasUnread ? Theme.violet.opacity(0.12) : Theme.surface)
                .overlay(
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(hasUnread ? 0.22 : 0.12),
                                (hasUnread ? Theme.edgeGlow : Color.white).opacity(hasUnread ? 0.35 : 0.04),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.75
                    )
                )
        }
    }
}

/// Presses squish the row slightly; no extra chrome.
private struct ConversationRowButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

/// Rows rise in with a staggered spring on first appearance; a plain fade
/// under Reduce Motion.
private struct SpringIn: ViewModifier {
    let isShown: Bool
    let index: Int
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isShown ? 1 : 0)
            .offset(y: isShown || reduceMotion ? 0 : 22)
            .scaleEffect(isShown || reduceMotion ? 1 : 0.96, anchor: .top)
            .animation(
                reduceMotion
                    ? .easeOut(duration: 0.2)
                    : Motion.cardSpring.delay(Double(min(index, 10)) * 0.035),
                value: isShown
            )
    }
}

/// Round avatar with the glass rim, violet edge glow and pulsing online glow.
private struct ChatListAvatar: View {
    let profile: Profile
    var size: CGFloat
    var glow: Double

    var body: some View {
        ProfilePhotoView(profile: profile)
            .frame(width: size, height: size)
            .glowFrame(cornerRadius: size / 2, glow: glow)
            .overlay(alignment: .bottomTrailing) {
                if profile.isOnline {
                    OnlineGlow(size: max(10, size * 0.2))
                        .padding(2)
                        .background(Theme.background, in: .circle)
                        .offset(x: 1, y: 1)
                }
            }
    }
}

#Preview {
    ChatListView()
        .previewEnvironment()
}
