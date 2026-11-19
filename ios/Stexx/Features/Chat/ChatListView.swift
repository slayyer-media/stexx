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
    /// Height of the rows above the conversations (error banner, Taps row),
    /// so the empty and error states sit below them instead of on top.
    @State private var headerRowsHeight: CGFloat = 0

    private var conversations: [Conversation] {
        chatStore.conversations.filter { !appState.blockedIDs.contains($0.participant.id) }
    }

    var body: some View {
        let visible = conversations
        // Muted chats keep their own count but stay out of the total (like the tab badge).
        let unread = visible.reduce(0) { $0 + ($1.isMuted ? 0 : $1.unreadCount) }

        NavigationStack(path: $path) {
            List {
                VStack(spacing: 0) {
                    if let error = chatStore.errorMessage, !visible.isEmpty {
                        ChatListErrorBanner(message: error) {
                            Task { await chatStore.refresh() }
                        }
                    }
                    Button {
                        openCount += 1
                        path.append(TapsRoute())
                    } label: {
                        TapsRow(
                            taps: tapsPreview,
                            unseen: chatStore.tapsUnseen,
                            hasLoaded: chatStore.hasLoadedTaps,
                            failed: chatStore.tapsErrorMessage != nil
                        )
                    }
                    .buttonStyle(ConversationRowButtonStyle())
                    .overlay(alignment: .bottom) {
                        HairlineDivider(leadingInset: Theme.Spacing.screen + ConversationRow.avatarSize + Theme.Spacing.m)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerRowsHeight = $0 }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())

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
                        Button {
                            Task { await chatStore.setMuted(!conversation.isMuted, conversationID: conversation.id) }
                        } label: {
                            if conversation.isMuted {
                                Label("Unmute", systemImage: "bell")
                            } else {
                                Label("Mute", systemImage: "bell.slash")
                            }
                        }
                        .tint(Theme.slate)
                    }
                }
            }
            .listStyle(.plain)
            .collapsesTabHeaderLogo()
            .overlay {
                if chatStore.isLoading && visible.isEmpty {
                    ProgressView()
                        .tint(Theme.steel)
                        .padding(.top, headerRowsHeight)
                } else if visible.isEmpty, let error = chatStore.errorMessage {
                    ContentUnavailableView {
                        Label("Couldn't load chats", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(error)
                            .font(.stexxSub)
                            .foregroundStyle(Theme.steel)
                    } actions: {
                        Button("Try again") { Task { await chatStore.refresh() } }
                            .stexxSecondaryButton()
                    }
                    .padding(.top, headerRowsHeight)
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
                    .padding(.top, headerRowsHeight)
                }
            }
            .tabHeader {
                TabHeaderTitle(String(localized: "Chats"))
            } trailing: {
                ChatListCount(unread: unread, count: visible.count)
            }
            .stexxBackground()
            .refreshable { await chatStore.refresh() }
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
            .navigationDestination(for: TapsRoute.self) { _ in
                TapsView()
            }
        }
    }

    /// The newest senders for the Taps row, without blocked people.
    private var tapsPreview: [ReceivedTap] {
        chatStore.taps.lazy.filter { !appState.blockedIDs.contains($0.id) }.prefix(3).map { $0 }
    }
}

// MARK: - Taps row

/// The entry to the taps inbox, above the conversations: the newest
/// senders' avatars, a one-line summary and a count pill (solid while
/// something is new).
private struct TapsRow: View {
    let taps: [ReceivedTap]
    let unseen: Int
    /// A taps load has succeeded at least once.
    let hasLoaded: Bool
    /// The last taps fetch failed.
    let failed: Bool

    private var summary: String {
        TapsCopy.rowSummary(latest: taps.first, unseen: unseen, hasLoaded: hasLoaded, failed: failed)
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            avatars
                .frame(width: ConversationRow.avatarSize, height: ConversationRow.avatarSize)

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Taps")
                    .font(.stexxHeadline)
                    .foregroundStyle(Theme.frost)
                Text(summary)
                    .font(.stexxSub)
                    .foregroundStyle(unseen > 0 ? Theme.frost : Theme.steel)
                    .lineLimit(1)
            }

            Spacer(minLength: Theme.Spacing.s)

            if unseen > 0 {
                XXBadge(verbatim: unseen.formatted())
                    .accessibilityHidden(true)
            }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.slate)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, Theme.Spacing.screen)
        .padding(.vertical, Theme.Spacing.m + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityValue(unseen > 0 ? Text("\(unseen) new") : Text(verbatim: ""))
        .accessibilityHint("Opens who tapped you")
    }

    /// Up to three overlapping avatars of the newest senders, or a hand in
    /// a flat tile when nobody has tapped yet.
    @ViewBuilder
    private var avatars: some View {
        if taps.isEmpty {
            RoundedRectangle(cornerRadius: Theme.Radius.avatar, style: .continuous)
                .fill(Theme.ink1)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.avatar, style: .continuous)
                        .strokeBorder(Theme.line, lineWidth: 0.5)
                )
                .overlay {
                    Image(systemName: "hand.wave")
                        .font(.title3)
                        .foregroundStyle(Theme.steel)
                }
        } else {
            let size: CGFloat = taps.count == 1 ? ConversationRow.avatarSize : 36
            ZStack(alignment: .topLeading) {
                ForEach(Array(taps.enumerated().reversed()), id: \.element.id) { index, tap in
                    AvatarView(profile: tap.from, size: size, showsOnline: false)
                        .offset(x: CGFloat(index) * 8, y: CGFloat(index) * 8)
                }
            }
            .frame(width: ConversationRow.avatarSize, height: ConversationRow.avatarSize, alignment: .topLeading)
        }
    }
}

// MARK: - Error banner

/// Shown above cached conversations when a refresh failed: the list stays,
/// with a way to retry.
private struct ChatListErrorBanner: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
            Image(systemName: "wifi.exclamationmark")
                .font(.footnote)
                .foregroundStyle(Theme.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Couldn't refresh chats")
                    .font(.stexxSub.weight(.semibold))
                    .foregroundStyle(Theme.frost)
                Text(message)
                    .font(.stexxSub)
                    .foregroundStyle(Theme.steel)
                    .lineLimit(2)
            }
            Spacer(minLength: Theme.Spacing.s)
            Button("Retry", action: retry)
                .font(.stexxSub.weight(.semibold))
                .foregroundStyle(Theme.ice)
                .buttonStyle(.borderless)
        }
        .padding(Theme.Spacing.m)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .fill(Theme.ink1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 0.5)
        )
        .padding(.horizontal, Theme.Spacing.screen)
        .padding(.top, Theme.Spacing.s)
        .accessibilityElement(children: .combine)
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
                        // Muted: the count stays, but quiet (outlined, not solid).
                        XXBadge(verbatim: conversation.unreadCount.formatted(), style: conversation.isMuted ? .outline : .solid)
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
