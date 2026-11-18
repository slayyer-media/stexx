import PhotosUI
import SwiftUI

/// A single conversation with a floating liquid-glass composer.
struct ChatThreadView: View {
    let route: ChatRoute

    @Environment(AppState.self) private var appState
    @Environment(ChatStore.self) private var chatStore
    @Environment(\.apiClient) private var api
    @Environment(\.dismiss) private var dismiss

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
    @FocusState private var isComposerFocused: Bool
    @Namespace private var composerNamespace

    private var participant: Profile { route.participant }

    private var canSend: Bool {
        conversation != nil && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    if !isLoading && messages.isEmpty {
                        emptyThread
                    }
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        MessageBubble(
                            message: message,
                            isMine: message.senderID == appState.myID,
                            showsTimestamp: showsTimestamp(at: index)
                        )
                        .id(message.id)
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
            .onChange(of: messages.last?.id) { _, lastID in
                guard let lastID else { return }
                withAnimation(.smooth) { proxy.scrollTo(lastID, anchor: .bottom) }
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
                        AvatarView(profile: participant, size: 30)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(participant.displayName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text(StexxFormat.lastSeen(participant.lastActiveAt, isOnline: participant.isOnline))
                                .font(.caption2)
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
                        .frame(width: 44, height: 44)
                        .contentShape(.circle)
                }
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("Attachments")

                TextField("Message", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($isComposerFocused)
                    .padding(.horizontal, Theme.Spacing.l)
                    .padding(.vertical, 12)
                    .frame(minHeight: 44)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: Theme.Radius.field))

                if canSend {
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
                    .accessibilityLabel("Send")
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.s)
        .animation(.smooth(duration: 0.25), value: canSend)
    }

    private var emptyThread: some View {
        VStack(spacing: Theme.Spacing.m) {
            AvatarView(profile: participant, size: 88)
            Text("Say hi to \(participant.displayName)")
                .font(.stexxHeadline)
            Text("Be kind, be clear, have fun. You can block or report anytime from the ••• menu.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
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

/// A chat bubble. Own messages use the violet gradient; theirs a dark solid
/// surface (bubbles are content, so they aren't glass).
struct MessageBubble: View {
    let message: Message
    let isMine: Bool
    var showsTimestamp = false

    var body: some View {
        VStack(spacing: 4) {
            if showsTimestamp {
                Text(StexxFormat.chatTimestamp(message.sentAt))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }

            HStack(alignment: .bottom, spacing: 6) {
                if isMine { Spacer(minLength: 56) }

                VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
                    if let attachment = message.attachment {
                        attachmentView(attachment)
                    }
                    if let text = message.text {
                        Text(text)
                            .font(.body)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(bubbleStyle, in: .rect(cornerRadius: Theme.Radius.bubble))
                            .overlay {
                                if !isMine {
                                    RoundedRectangle(cornerRadius: Theme.Radius.bubble)
                                        .strokeBorder(Theme.hairline, lineWidth: 0.5)
                                }
                            }
                            .opacity(message.status == .sending ? 0.7 : 1)
                    }
                    if isMine, let status = statusText {
                        Text(status)
                            .font(.caption2)
                            .foregroundStyle(message.status == .failed ? Theme.danger : Theme.textTertiary)
                    }
                }

                if !isMine { Spacer(minLength: 56) }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var bubbleStyle: AnyShapeStyle {
        isMine ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.backgroundRaised)
    }

    private var statusText: LocalizedStringKey? {
        switch message.status {
        case .sending: return "Sending…"
        case .failed: return "Not sent. Tap to retry."
        case .read: return "Read"
        case .sent, .delivered: return nil
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
        }
        .frame(width: 180, height: 220)
        .clipShape(.rect(cornerRadius: Theme.Radius.bubble))
    }
}

#Preview {
    NavigationStack {
        ChatThreadView(route: ChatRoute(participant: MockData.profiles[0], conversationID: "c-p01"))
    }
    .previewEnvironment()
}
