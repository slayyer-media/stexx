import PhotosUI
import SwiftUI

/// A single conversation with a floating liquid-glass composer.
struct ChatThreadView: View {
    let route: ChatRoute

    @Environment(AppState.self) private var appState
    @Environment(ChatStore.self) private var chatStore
    @Environment(\.apiClient) private var api
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var conversation: Conversation?
    @State private var messages: [Message] = []
    @State private var draft = ""
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var expiresPhotos = true
    @State private var isConfirmingBlock = false
    @State private var isReporting = false
    @State private var isPickingPhoto = false
    @State private var photoItem: PhotosPickerItem?
    /// Messages that should "land" with a bounce when they first appear
    /// (sent or received while the thread is open), by `bubbleKey`. Anything
    /// loaded with the thread just appears.
    @State private var landingKeys: Set<String> = []
    /// Bumped on every send, for haptics.
    @State private var sendCount = 0
    @FocusState private var isComposerFocused: Bool
    @Namespace private var composerNamespace

    private var participant: Profile { route.participant }

    private var canSend: Bool {
        conversation != nil && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        let myID = appState.myID
        // "Read" shows once, under the newest of my messages that was read.
        let lastReadIndex = messages.lastIndex { $0.senderID == myID && $0.status == .read }

        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if !isLoading && messages.isEmpty {
                        emptyThread
                    }
                    ForEach(Array(messages.enumerated()), id: \.element.bubbleKey) { index, message in
                        let key = message.bubbleKey
                        let isMine = message.senderID == myID
                        let continues = continuesGroup(at: index)
                        MessageBubble(
                            message: message,
                            isMine: isMine,
                            showsTimestamp: showsTimestamp(at: index),
                            isFirstInGroup: !continues,
                            isLastInGroup: isLastInGroup(at: index),
                            showsReadReceipt: index == lastReadIndex
                        )
                        .id(key)
                        .padding(.top, continues ? 2 : Theme.Spacing.s)
                        .modifier(BubbleLanding(
                            animatesIn: landingKeys.contains(key),
                            anchor: isMine ? .bottomTrailing : .bottomLeading,
                            reduceMotion: reduceMotion,
                            onLanded: { landingKeys.remove(key) }
                        ))
                        .onTapGesture {
                            if message.status == .failed { retry(message) }
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.m)
                .padding(.vertical, Theme.Spacing.m)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.last?.bubbleKey) { _, lastKey in
                guard let lastKey else { return }
                withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .smooth) {
                    proxy.scrollTo(lastKey, anchor: .bottom)
                }
            }
        }
        .overlay {
            if isLoading { ProgressView() }
        }
        .stexxBackground(intensity: 0.55)
        .safeAreaInset(edge: .bottom) { composer }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                NavigationLink(value: participant) {
                    HStack(spacing: Theme.Spacing.s) {
                        ThreadAvatar(profile: participant, size: 32, glow: 0.5)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(participant.displayName)
                                .font(.subheadline.weight(.heavy))
                                .tracking(Theme.Tracking.tight)
                                .foregroundStyle(Theme.textPrimary)
                            Text(StexxFormat.lastSeen(participant.lastActiveAt, isOnline: participant.isOnline))
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(participant.isOnline ? Theme.online : Theme.textTertiary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens profile")
            }
            ToolbarItem(placement: .topBarTrailing) {
                SafetyMenu(
                    profile: participant,
                    onBlock: { isConfirmingBlock = true },
                    onReport: { isReporting = true }
                )
            }
        }
        .confirmationDialog(
            "Block \(participant.displayName)?",
            isPresented: $isConfirmingBlock,
            titleVisibility: .visible
        ) {
            Button("Block", role: .destructive) { Task { await block() } }
        } message: {
            Text("This conversation will be removed and they won't be able to contact you.")
        }
        .sheet(isPresented: $isReporting) {
            ReportSheet(profile: participant, conversationID: conversation?.id) { didBlock in
                if didBlock { dismiss() }
            }
        }
        .task { await load() }
        .task(id: conversation?.id) {
            // Realtime: new messages and read receipts while the thread is open.
            guard let id = conversation?.id else { return }
            for await update in chatStore.threadUpdates(for: id) {
                if update == .resync {
                    // The socket was down: refetch what was missed.
                    try? await refreshMessages(in: id)
                } else {
                    if case .created(let message) = update,
                       !messages.contains(where: { $0.id == message.id || $0.bubbleKey == message.bubbleKey }) {
                        landingKeys.insert(message.bubbleKey)
                    }
                    ChatStore.merge(update, into: &messages, myID: appState.myID)
                }
            }
        }
        .photosPicker(isPresented: $isPickingPhoto, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            Task { await sendPhoto(item) }
        }
    }

    // MARK: Composer

    private var composer: some View {
        GlassEffectContainer(spacing: Theme.Spacing.s) {
            HStack(alignment: .bottom, spacing: Theme.Spacing.s) {
                attachmentMenu
                messageField
                if canSend {
                    sendButton
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.s)
        .animation(Motion.animation(Motion.cardSpring, reduceMotion: reduceMotion), value: canSend)
        .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: isComposerFocused)
        .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: draft.isEmpty)
        .sensoryFeedback(.impact(weight: .medium), trigger: sendCount)
    }

    private var attachmentMenu: some View {
        Menu {
            Button {
                isPickingPhoto = true
            } label: {
                Label("Photo", systemImage: "photo")
            }
            Toggle(isOn: $expiresPhotos) {
                Label("Expiring photos", systemImage: "timer")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 44, height: 44)
                .contentShape(.circle)
                .overlay(alignment: .topTrailing) {
                    // Small violet timer: photos sent now will expire.
                    if expiresPhotos {
                        Image(systemName: "timer")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(3)
                            .background(Theme.accentGradient, in: .circle)
                            .offset(x: -1, y: 3)
                    }
                }
        }
        .glassEffect(.regular.interactive(), in: .circle)
        .glassEffectID("attach", in: composerNamespace)
        .accessibilityLabel("Attachments")
        .accessibilityValue(expiresPhotos ? Text("Expiring photos on") : Text(verbatim: ""))
    }

    private var messageField: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.field)
        return HStack(alignment: .bottom, spacing: 4) {
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($isComposerFocused)
                .tint(Theme.violetBright)
                .padding(.vertical, 12)

            if draft.isEmpty {
                Button {
                    isPickingPhoto = true
                } label: {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.violetBright)
                        .frame(width: 36, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(conversation == nil)
                .transition(.opacity)
                .accessibilityLabel("Send a photo")
            }
        }
        .padding(.leading, Theme.Spacing.l)
        .padding(.trailing, draft.isEmpty ? 6 : Theme.Spacing.l)
        .frame(minHeight: 44)
        .glassEffect(.regular.interactive(), in: shape)
        .glassEffectID("field", in: composerNamespace)
        // Violet focus glow: a soft halo behind the glass plus a crisp rim.
        .background {
            shape
                .stroke(Theme.edgeGlow, lineWidth: 2)
                .blur(radius: 7)
                .opacity(isComposerFocused ? 0.85 : 0)
        }
        .overlay {
            shape
                .strokeBorder(
                    LinearGradient(
                        colors: [Theme.violetBright.opacity(0.9), Theme.edgeGlow.opacity(0.35)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
                .opacity(isComposerFocused ? 1 : 0)
                .allowsHitTesting(false)
        }
    }

    private var sendButton: some View {
        Button(action: send) {
            Image(systemName: "arrow.up")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(Theme.violet).interactive(), in: .circle)
        .glassEffectID("send", in: composerNamespace)
        .shadow(color: Theme.edgeGlow.opacity(0.55), radius: 10)
        .accessibilityLabel("Send")
    }

    private var emptyThread: some View {
        VStack(spacing: Theme.Spacing.m) {
            ThreadAvatar(profile: participant, size: 96, glow: 1.4)
                .padding(.bottom, Theme.Spacing.s)
            Text("Say hi to \(participant.displayName)")
                .font(.stexxName)
                .tracking(Theme.Tracking.tight)
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
            Text("Be kind, be clear, have fun. You can block or report anytime from the ••• menu.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            GlassChip("Wave", systemImage: "hand.wave.fill", isSelected: true) {
                draft = String(localized: "Hi 👋")
                isComposerFocused = true
            }
            .accessibilityRemoveTraits(.isSelected)
            .padding(.top, Theme.Spacing.s)
            .disabled(conversation == nil)
        }
        .padding(.top, 80)
        .padding(.horizontal, Theme.Spacing.xl)
    }

    // MARK: Logic

    /// Show a timestamp above the first message and after gaps of 15+ minutes.
    private func showsTimestamp(at index: Int) -> Bool {
        guard index > 0 else { return true }
        return messages[index].sentAt.timeIntervalSince(messages[index - 1].sentAt) > 15 * 60
    }

    /// Consecutive messages from the same sender, within a couple of
    /// minutes and without a timestamp between them, form a group.
    private func continuesGroup(at index: Int) -> Bool {
        guard index > 0, !showsTimestamp(at: index) else { return false }
        let previous = messages[index - 1], current = messages[index]
        return previous.senderID == current.senderID
            && current.sentAt.timeIntervalSince(previous.sentAt) < 2 * 60
    }

    private func isLastInGroup(at index: Int) -> Bool {
        index == messages.count - 1 || !continuesGroup(at: index + 1)
    }

    private func load() async {
        expiresPhotos = appState.privacy.expiringPhotosByDefault
        defer { isLoading = false }
        do {
            let resolved: Conversation
            if let id = route.conversationID,
               let existing = chatStore.conversations.first(where: { $0.id == id }) {
                resolved = existing
            } else {
                resolved = try await api.openConversation(with: participant.id)
            }
            conversation = resolved
            try await refreshMessages(in: resolved.id)
            await chatStore.markRead(resolved.id)
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Fetches the latest page and reconciles it with what's shown, keeping
    /// live events that arrived while the request was in flight.
    private func refreshMessages(in conversationID: Conversation.ID) async throws {
        let snapshot = try await api.messages(in: conversationID, before: nil).items
        messages = ChatStore.reconcile(snapshot: snapshot, with: messages, myID: appState.myID)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let conversation, !text.isEmpty else { return }
        draft = ""

        let messageDraft = MessageDraft(clientID: UUID().uuidString, text: text)
        let pending = Message.pending(from: messageDraft, conversationID: conversation.id, senderID: appState.myID)
        landingKeys.insert(pending.bubbleKey)
        sendCount += 1
        messages.append(pending)
        deliver(messageDraft, pendingID: pending.id, in: conversation)
    }

    /// Re-sends a failed message with the same client ID, so the server can
    /// deduplicate if the first attempt actually arrived.
    private func retry(_ message: Message) {
        guard let conversation, let clientID = message.clientID,
              let index = messages.firstIndex(where: { $0.id == message.id })
        else { return }
        messages[index].status = .sending
        if message.attachment != nil {
            deliverPhoto(nil, clientID: clientID, pendingID: message.id, in: conversation)
            return
        }
        deliver(MessageDraft(clientID: clientID, text: message.text), pendingID: message.id, in: conversation)
    }

    /// Photo messages: metadata is stripped on device (`ImageSanitizer`),
    /// then the photo is uploaded and sent as `attachmentPhotoID`.
    private func sendPhoto(_ item: PhotosPickerItem) async {
        guard let conversation,
              let data = try? await item.loadTransferable(type: Data.self),
              let jpeg = ImageSanitizer.strippedJPEG(from: data)
        else { return }
        var pending = Message.pending(
            from: MessageDraft(clientID: UUID().uuidString),
            conversationID: conversation.id,
            senderID: appState.myID
        )
        pending.attachment = Message.Attachment(kind: .photo, url: nil)
        landingKeys.insert(pending.bubbleKey)
        sendCount += 1
        messages.append(pending)
        deliverPhoto(jpeg, clientID: pending.clientID ?? pending.id, pendingID: pending.id, in: conversation)
    }

    private func deliverPhoto(_ jpeg: Data?, clientID: String, pendingID: Message.ID, in conversation: Conversation) {
        let expiresAfter = expiresPhotos ? Self.expiringPhotoSeconds : nil
        Task {
            do {
                let sent = try await chatStore.sendPhoto(
                    jpegData: jpeg,
                    clientID: clientID,
                    expiresAfterSeconds: expiresAfter,
                    in: conversation
                )
                if let index = messages.firstIndex(where: { $0.id == pendingID }) {
                    messages[index] = sent
                }
            } catch {
                if let index = messages.firstIndex(where: { $0.id == pendingID }) {
                    messages[index].status = .failed
                }
            }
        }
    }

    /// How long an expiring photo stays after it's been read.
    private static let expiringPhotoSeconds = 60

    private func deliver(_ messageDraft: MessageDraft, pendingID: Message.ID, in conversation: Conversation) {
        Task {
            do {
                let sent = try await api.send(messageDraft, in: conversation.id)
                if let index = messages.firstIndex(where: { $0.id == pendingID }) {
                    messages[index] = sent
                } else if let index = messages.firstIndex(where: { $0.id == sent.id }) {
                    // The realtime echo arrived first and replaced the pending copy.
                    messages[index] = sent
                }
                chatStore.didSend(sent, in: conversation)
            } catch {
                if let index = messages.firstIndex(where: { $0.id == pendingID }) {
                    messages[index].status = .failed
                }
            }
        }
    }

    private func block() async {
        do {
            try await api.block(profileID: participant.id)
            appState.markBlocked(participant.id)
            chatStore.removeConversations(with: participant.id)
            dismiss()
        } catch {}
    }
}

/// A chat bubble. Own messages use the violet gradient with a soft glow;
/// theirs sit on liquid glass (a solid surface under Reduce Transparency).
/// Bubbles in a run from the same sender tuck their inner corners together.
struct MessageBubble: View {
    let message: Message
    let isMine: Bool
    var showsTimestamp = false
    var isFirstInGroup = true
    var isLastInGroup = true
    /// Whether a `.read` status is spelled out under this bubble.
    var showsReadReceipt = true

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(spacing: 4) {
            if showsTimestamp {
                Text(StexxFormat.chatTimestamp(message.sentAt))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Theme.surface, in: .capsule)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.Spacing.s)
            }

            HStack(alignment: .bottom, spacing: 6) {
                if isMine { Spacer(minLength: 56) }

                VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
                    if let attachment = message.attachment {
                        attachmentView(attachment)
                            .opacity(message.status == .sending ? 0.7 : 1)
                    }
                    if let text = message.text {
                        Text(text)
                            .font(.body)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background { bubbleBackground }
                            .opacity(message.status == .sending ? 0.7 : 1)
                    }
                    if isMine, let status = statusText {
                        HStack(spacing: 3) {
                            if message.status == .read {
                                Image(systemName: "checkmark")
                                    .fontWeight(.bold)
                                    .accessibilityHidden(true)
                            } else if message.status == .failed {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .accessibilityHidden(true)
                            }
                            Text(status)
                        }
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(statusColor)
                        .padding(.trailing, 4)
                    }
                }

                if !isMine { Spacer(minLength: 56) }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var bubbleShape: UnevenRoundedRectangle {
        let big = Theme.Radius.bubble
        let small: CGFloat = 6
        let top = isFirstInGroup ? big : small
        let bottom = isLastInGroup ? big : small
        if isMine {
            return UnevenRoundedRectangle(
                topLeadingRadius: big, bottomLeadingRadius: big,
                bottomTrailingRadius: bottom, topTrailingRadius: top,
                style: .continuous
            )
        } else {
            return UnevenRoundedRectangle(
                topLeadingRadius: top, bottomLeadingRadius: bottom,
                bottomTrailingRadius: big, topTrailingRadius: big,
                style: .continuous
            )
        }
    }

    @ViewBuilder
    private var bubbleBackground: some View {
        let shape = bubbleShape
        if isMine {
            shape
                .fill(Theme.ownBubbleGradient)
                .shadow(color: Theme.edgeGlow.opacity(isLastInGroup ? 0.4 : 0.22), radius: 10, y: 3)
        } else if reduceTransparency {
            shape
                .fill(Theme.backgroundRaised)
                .overlay(shape.stroke(Theme.hairline, lineWidth: 0.5))
        } else {
            Color.clear
                .glassEffect(.regular, in: shape)
        }
    }

    private var statusText: LocalizedStringKey? {
        switch message.status {
        case .sending: return "Sending…"
        case .failed: return "Not sent. Tap to retry."
        case .read: return showsReadReceipt ? "Read" : nil
        case .sent, .delivered: return nil
        }
    }

    private var statusColor: Color {
        switch message.status {
        case .failed: Theme.danger
        case .read: Theme.violetBright
        default: Theme.textTertiary
        }
    }

    private func attachmentView(_ attachment: Message.Attachment) -> some View {
        ZStack {
            Theme.backgroundRaised
            VStack(spacing: 6) {
                Image(systemName: attachment.isViewOnce ? "eye.slash" : "photo")
                    .font(.title2)
                Text(attachment.isViewOnce ? "View once" : "Photo")
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(Theme.textSecondary)
            // View-once photos aren't fetched automatically: the first fetch
            // counts as opening them.
            if let url = attachment.url, !attachment.isViewOnce {
                // Never through the shared URL cache: no copy on disk.
                PrivateAsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.clear
                }
            }
            if message.status == .sending {
                ProgressView()
                    .tint(.white)
            }
        }
        .frame(width: 180, height: 220)
        .glowFrame(cornerRadius: Theme.Radius.bubble, glow: isMine ? 0.7 : 0.3)
    }
}

/// New bubbles land with a slight bounce from the sender's side; a plain
/// fade under Reduce Motion. Bubbles that were already there just appear.
private struct BubbleLanding: ViewModifier {
    let anchor: UnitPoint
    let reduceMotion: Bool
    let onLanded: () -> Void
    @State private var landed: Bool

    init(animatesIn: Bool, anchor: UnitPoint, reduceMotion: Bool, onLanded: @escaping () -> Void) {
        self.anchor = anchor
        self.reduceMotion = reduceMotion
        self.onLanded = onLanded
        _landed = State(initialValue: !animatesIn)
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(landed || reduceMotion ? 1 : 0.85, anchor: anchor)
            .offset(y: landed || reduceMotion ? 0 : 14)
            .opacity(landed ? 1 : 0)
            .onAppear {
                guard !landed else { return }
                withAnimation(reduceMotion ? .easeOut(duration: 0.2) : Motion.bubbleLand) {
                    landed = true
                }
                onLanded()
            }
    }
}

/// Round avatar with the glass rim, violet edge glow and online glow.
private struct ThreadAvatar: View {
    let profile: Profile
    var size: CGFloat
    var glow: Double

    var body: some View {
        ProfilePhotoView(profile: profile)
            .frame(width: size, height: size)
            .glowFrame(cornerRadius: size / 2, glow: glow)
            .overlay(alignment: .bottomTrailing) {
                if profile.isOnline {
                    OnlineGlow(size: max(8, size * 0.2))
                        .padding(1.5)
                        .background(Theme.background, in: .circle)
                }
            }
    }
}

fileprivate extension Message {
    /// Stable identity across the optimistic → sent swap (the server's copy
    /// gets a new `id` but keeps the client ID).
    var bubbleKey: String { "\(senderID)|\(clientID ?? id)" }
}

#Preview {
    NavigationStack {
        ChatThreadView(route: ChatRoute(participant: MockData.profiles[0], conversationID: "c-p01"))
    }
    .previewEnvironment()
}
