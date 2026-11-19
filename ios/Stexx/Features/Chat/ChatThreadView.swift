import PhotosUI
import SwiftUI

/// A single conversation with a black-glass composer.
struct ChatThreadView: View {
    let route: ChatRoute

    @Environment(AppState.self) private var appState
    @Environment(ChatStore.self) private var chatStore
    @Environment(E2EStatus.self) private var e2e
    @Environment(\.apiClient) private var api
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @State private var conversation: Conversation?
    @State private var messages: [Message] = []
    @State private var draft = ""
    @State private var isLoading = true
    @State private var errorMessage: String?
    /// Why the last send was refused (rate limit or new-account limit), shown above the composer.
    @State private var sendNotice: String?
    @State private var expiresPhotos = true
    /// Photos sent now are view-once (exclusive with `expiresPhotos`).
    @State private var sendsViewOnce = false
    @State private var isConfirmingBlock = false
    @State private var isReporting = false
    @State private var isPickingPhoto = false
    @State private var photoItem: PhotosPickerItem?
    /// Messages that should "land" (a short fade-up) when they first appear
    /// (sent or received while the thread is open), by `bubbleKey`. Anything
    /// loaded with the thread just appears.
    @State private var landingKeys: Set<String> = []
    /// Bumped on every send, for haptics.
    @State private var sendCount = 0
    @State private var isAcceptingKeyChange = false
    /// Blurred incoming photos the user tapped to see, while this thread is open.
    @State private var revealedPhotoIDs: Set<Message.ID> = []
    /// The view-once photo open in the full-screen viewer.
    @State private var viewOnceMessage: Message?
    /// Plaintext view-once photos `GET …/messages` listed without a URL: spent.
    @State private var spentViewOnceIDs: Set<Message.ID> = []
    @FocusState private var isComposerFocused: Bool

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
                    if e2e.isEncrypted(with: participant.id) {
                        EncryptedThreadLabel()
                            .padding(.bottom, Theme.Spacing.s)
                    }
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
                            senderName: participant.displayName,
                            // Held bubbles keep their "key" placeholder until the refetch after Accept.
                            isKeyChangePending: e2e.hasKeyChange(for: participant.id) || isAcceptingKeyChange,
                            showsTimestamp: showsTimestamp(at: index),
                            isFirstInGroup: !continues,
                            isLastInGroup: isLastInGroup(at: index),
                            showsReadReceipt: index == lastReadIndex,
                            isViewOnceSpent: spentViewOnceIDs.contains(message.id),
                            isViewOnceOpenedHere: chatStore.hasOpenedViewOnce(message.id),
                            isPhotoRevealed: revealedPhotoIDs.contains(message.id),
                            onRevealPhoto: { revealedPhotoIDs.insert(message.id) },
                            onOpenViewOnce: { Task { await openViewOnce(message) } }
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
                withAnimation(Motion.animation(Motion.standard, reduceMotion: reduceMotion)) {
                    proxy.scrollTo(lastKey, anchor: .bottom)
                }
            }
        }
        .overlay {
            if isLoading { ProgressView().tint(Theme.steel) }
        }
        .stexxBackground()
        .safeAreaInset(edge: .top, spacing: 0) {
            if e2e.hasKeyChange(for: participant.id) {
                KeyChangeBanner(name: participant.displayName, isAccepting: isAcceptingKeyChange) {
                    Task { await acceptKeyChange() }
                }
                .transition(.opacity)
            }
        }
        .animation(Motion.animation(Motion.quick, reduceMotion: reduceMotion), value: e2e.hasKeyChange(for: participant.id))
        .safeAreaInset(edge: .bottom) { composer }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                NavigationLink(value: participant) {
                    HStack(spacing: Theme.Spacing.s) {
                        AvatarView(profile: participant, size: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(participant.displayName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.frost)
                            Text(StexxFormat.lastSeen(participant.lastActiveAt, isOnline: participant.isOnline))
                                .stexxLabelStyle(.micro, color: participant.isOnline ? Theme.online : Theme.slate)
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
            ReportSheet(profile: participant, conversationID: conversation?.id, messages: messages) { didBlock in
                if didBlock { dismiss() }
            }
        }
        .task {
            await load()
            #if DEBUG
            // Screenshot-only: open the report sheet from a chat.
            if let route = ScreenshotRoute.current, [.reportFromChat, .reportPicker, .reportSent].contains(route) {
                isReporting = true
            }
            // Screenshot-only: send a message from a live (dev server) chat.
            if ScreenshotRoute.current == .liveChat, let text = ScreenshotRoute.draft, conversation != nil {
                draft = text
                send()
            }
            #endif
        }
        .task(id: conversation?.id) {
            // Realtime: new messages and read receipts while the thread is open.
            guard let id = conversation?.id else { return }
            // Encrypted chats: is there a session, and did their key change?
            Task { await e2e.threadOpened(with: participant.id) }
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
        .fullScreenCover(item: $viewOnceMessage) { message in
            ViewOnceViewer(message: message, onOpened: { markViewOnceOpened(message) }) { outcome, opened in
                Task { await closeViewOnce(message, outcome: outcome, opened: opened) }
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
        VStack(spacing: 0) {
            if let sendNotice {
                SendNoticeRow(text: sendNotice) { self.sendNotice = nil }
                    .transition(.opacity)
            }
            HStack(alignment: .bottom, spacing: Theme.Spacing.s) {
                attachmentMenu
                messageField
                if canSend {
                    sendButton
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.vertical, Theme.Spacing.s)
        }
        .background { composerBar }
        .animation(Motion.animation(Motion.quick, reduceMotion: reduceMotion), value: sendNotice)
        .animation(Motion.animation(Motion.quick, reduceMotion: reduceMotion), value: canSend)
        .animation(Motion.animation(Motion.quick, reduceMotion: reduceMotion), value: isComposerFocused)
        .animation(Motion.animation(Motion.quick, reduceMotion: reduceMotion), value: draft.isEmpty)
        .sensoryFeedback(.impact(weight: .light), trigger: sendCount)
    }

    /// Black frosted glass under the composer, with a single hairline top
    /// edge; flat ink1 under Reduce Transparency.
    private var composerBar: some View {
        ZStack {
            if reduceTransparency {
                Theme.ink1
            } else {
                Rectangle().fill(.ultraThinMaterial)
                Theme.ink.opacity(0.55)
            }
        }
        .overlay(alignment: .top) { HairlineDivider(strong: true) }
        .ignoresSafeArea(edges: .bottom)
    }

    private var attachmentMenu: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
        return Menu {
            Button {
                isPickingPhoto = true
            } label: {
                Label("Photo", systemImage: "photo")
            }
            Toggle(isOn: $expiresPhotos) {
                Label("Expiring photos", systemImage: "timer")
            }
            Toggle(isOn: $sendsViewOnce) {
                Label("View once", systemImage: "eye.slash")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.steel)
                .frame(width: 44, height: 44)
                .background(Theme.ink1, in: shape)
                .hairlineBorder(shape)
                .contentShape(shape)
                .overlay(alignment: .topTrailing) {
                    // Small badge: photos sent now are view-once, or will expire.
                    if sendsViewOnce || expiresPhotos {
                        Image(systemName: sendsViewOnce ? "eye.slash" : "timer")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Theme.ice)
                            .offset(x: -5, y: 5)
                    }
                }
        }
        .onChange(of: sendsViewOnce) { _, isOn in if isOn { expiresPhotos = false } }
        .onChange(of: expiresPhotos) { _, isOn in if isOn { sendsViewOnce = false } }
        .accessibilityLabel("Attachments")
        .accessibilityValue(
            sendsViewOnce ? Text("View-once photos on") : expiresPhotos ? Text("Expiring photos on") : Text(verbatim: "")
        )
    }

    private var messageField: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
        return HStack(alignment: .bottom, spacing: 4) {
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .font(.stexxBody)
                .foregroundStyle(Theme.frost)
                .focused($isComposerFocused)
                .tint(Theme.ice)
                .padding(.vertical, 11)

            if draft.isEmpty {
                Button {
                    isPickingPhoto = true
                } label: {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.body)
                        .foregroundStyle(Theme.steel)
                        .frame(width: 36, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(conversation == nil)
                .transition(.opacity)
                .accessibilityLabel("Send a photo")
            }
        }
        .padding(.leading, Theme.Spacing.m + 2)
        .padding(.trailing, draft.isEmpty ? 6 : Theme.Spacing.m + 2)
        .frame(minHeight: 44)
        .background(Theme.ink2, in: shape)
        .hairlineBorder(shape, strong: isComposerFocused)
        // The composer is this screen's one lit surface, and only while focused.
        .rimLight(shape, intensity: isComposerFocused ? 1 : 0)
    }

    private var sendButton: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
        return Button(action: send) {
            Image(systemName: "arrow.up")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: 44, height: 44)
                .background(Theme.frost, in: shape)
                .contentShape(shape)
        }
        // The send itself gives the light impact haptic.
        .buttonStyle(PressableButtonStyle(haptics: false))
        .accessibilityLabel("Send")
    }

    private var emptyThread: some View {
        VStack(spacing: Theme.Spacing.m) {
            AvatarView(profile: participant, size: 88)
                .rimLight(cornerRadius: Theme.Radius.avatar)
                .cellCorners()
                .padding(.bottom, Theme.Spacing.l)
            Text("Say hi to \(participant.displayName)")
                .stexxTitleStyle(.title)
                .multilineTextAlignment(.center)
            Text("Be kind, be clear, have fun. You can block or report anytime from the ••• menu.")
                .font(.stexxSub)
                .foregroundStyle(Theme.steel)
                .multilineTextAlignment(.center)
            GlassChip("Wave", systemImage: "hand.wave.fill", isSelected: true) {
                draft = String(localized: "Hi 👋")
                isComposerFocused = true
            }
            .accessibilityRemoveTraits(.isSelected)
            .padding(.top, Theme.Spacing.m)
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
        let myID = appState.myID
        // Only this listing gives the recipient a view-once URL: none here means it's spent.
        spentViewOnceIDs.formUnion(snapshot.filter {
            $0.senderID != myID && $0.attachment?.isViewOnce == true && $0.attachment?.url == nil
        }.map(\.id))
        messages = ChatStore.reconcile(snapshot: snapshot, with: messages, myID: myID)
    }

    /// A view-once photo (encrypted or plaintext) was tapped. Realtime
    /// events don't carry its URL, so the thread is refetched first if
    /// needed; if the server no longer has it, the bubble turns into "no
    /// longer available" instead. Listing doesn't open it: the viewer does,
    /// once the photo is on screen (`markViewOnceOpened`).
    private func openViewOnce(_ message: Message) async {
        guard !chatStore.hasOpenedViewOnce(message.id), !message.isViewOnceOpened else { return }
        var target = message
        if target.attachment?.url == nil, let id = conversation?.id {
            try? await refreshMessages(in: id)
            target = messages.first { $0.id == message.id } ?? target
        }
        guard target.attachment?.url != nil, !target.isViewOnceOpened else { return }
        if target.attachment?.isEncrypted == true, target.e2eAttachment == nil { return }
        viewOnceMessage = target
    }

    /// The viewer shows the photo: it's opened. The server is told (and
    /// deletes it shortly); for an encrypted photo the key goes as soon as
    /// the server confirms. The bubble says "Opened" from now on.
    private func markViewOnceOpened(_ message: Message) {
        guard let conversationID = conversation?.id else { return }
        Task {
            guard let opened = await chatStore.openViewOnce(message.id, in: conversationID),
                  let index = messages.firstIndex(where: { $0.id == opened.id })
            else { return }
            messages[index] = ChatStore.updating(messages[index], with: opened)
        }
    }

    /// The viewer closed: if the photo was opened, it's done on this phone.
    /// An encrypted photo's key is forgotten (also when the server call
    /// failed) and the bubble says "Opened"; a photo the server no longer
    /// has says "no longer available". A network error or a photo still
    /// blurred leaves it unopened, to try again.
    private func closeViewOnce(_ message: Message, outcome: ChatMediaLoader.Outcome?, opened: Bool) async {
        let removal: Message.AttachmentRemoval
        if opened {
            removal = .opened
        } else if case .gone? = outcome {
            removal = .gone
        } else {
            return
        }
        await ChatMediaLoader.shared.evict(message.id)
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        if messages[index].attachment?.isEncrypted == true {
            await e2e.forgetAttachmentKey(messageID: message.id, gone: removal == .gone)
            guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
            messages[index].e2eAttachment = nil
            messages[index].e2eAttachmentRemoval = removal
        } else if removal == .gone {
            spentViewOnceIDs.insert(message.id)
        }
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
        pending.attachment = Message.Attachment(kind: .photo, url: nil, isViewOnce: sendsViewOnce)
        landingKeys.insert(pending.bubbleKey)
        sendCount += 1
        messages.append(pending)
        deliverPhoto(jpeg, clientID: pending.clientID ?? pending.id, pendingID: pending.id, in: conversation)
    }

    private func deliverPhoto(_ jpeg: Data?, clientID: String, pendingID: Message.ID, in conversation: Conversation) {
        let expiresAfter = expiresPhotos ? Self.expiringPhotoSeconds : nil
        let viewOnce = sendsViewOnce
        Task {
            do {
                let sent = try await chatStore.sendPhoto(
                    jpegData: jpeg,
                    clientID: clientID,
                    expiresAfterSeconds: expiresAfter,
                    isViewOnce: viewOnce,
                    in: conversation
                )
                if let index = messages.firstIndex(where: { $0.id == pendingID }) {
                    messages[index] = sent
                }
            } catch {
                if let index = messages.firstIndex(where: { $0.id == pendingID }) {
                    messages[index].status = .failed
                }
                sendNotice = Self.notice(for: error)
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
                sendNotice = nil
            } catch {
                if let index = messages.firstIndex(where: { $0.id == pendingID }) {
                    messages[index].status = .failed
                }
                sendNotice = Self.notice(for: error)
            }
        }
    }

    /// The server's explanation for a refused send (429 or a 403 anti-spam
    /// limit), the app's own for encryption and the in-app text rules, or nil
    /// for plain failures, which the bubble already shows.
    static func notice(for error: any Error) -> String? {
        if error is E2EError || error is E2EContentRules.Violation {
            return error.localizedDescription
        }
        switch error as? APIError {
        case .rateLimited?:
            return error.localizedDescription
        case .server(let status, let message?)? where status == 403 || status == 400:
            return message
        case .e2e(let code, _)? where code == E2EErrorCode.encryptionRequired:
            return error.localizedDescription
        default:
            return nil
        }
    }

    /// The user accepted the new key: messages held back by it decrypt on the refetch.
    private func acceptKeyChange() async {
        isAcceptingKeyChange = true
        defer { isAcceptingKeyChange = false }
        guard await e2e.acceptKeyChange(of: participant.id) else {
            sendNotice = String(localized: "Couldn't accept the new key. Try again in a moment.")
            return
        }
        sendNotice = nil
        if let id = conversation?.id {
            do {
                try await refreshMessages(in: id)
            } catch {
                sendNotice = String(localized: "Key accepted. Couldn't load the held messages; they'll appear when the chat refreshes.")
            }
        }
        // The chat list's preview may have been a held message too.
        await chatStore.load()
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

/// A chat bubble. Own messages are frost with ink text; theirs are flat
/// ink1 with a 0.5pt line. Radius 14, with a 4pt tail corner on the last
/// bubble of a run; bubbles in a run tuck their inner corners together.
struct MessageBubble: View {
    let message: Message
    let isMine: Bool
    /// The other person's name, for the placeholder of a message held back by a key change.
    var senderName: String = ""
    /// Whether the other person's key change is waiting for the user. A
    /// message under an unknown key without one (stale or forged) can't be
    /// shown at all.
    var isKeyChangePending = true
    var showsTimestamp = false
    var isFirstInGroup = true
    var isLastInGroup = true
    /// Whether a `.read` status is spelled out under this bubble.
    var showsReadReceipt = true
    /// A plaintext view-once photo the server no longer gives a URL for.
    var isViewOnceSpent = false
    /// A view-once photo opened on this phone (before the server confirms).
    var isViewOnceOpenedHere = false
    /// A blurred incoming photo the user tapped to see.
    var isPhotoRevealed = false
    var onRevealPhoto: () -> Void = {}
    var onOpenViewOnce: () -> Void = {}

    var body: some View {
        VStack(spacing: 4) {
            if showsTimestamp {
                Text(StexxFormat.chatTimestamp(message.sentAt))
                    .stexxLabelStyle(.micro, color: Theme.slate)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.Spacing.m)
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
                            .font(.stexxBody)
                            .foregroundStyle(isMine ? Theme.ink : Theme.frost)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background { bubbleBackground }
                            .opacity(message.status == .sending ? 0.7 : 1)
                    } else if let placeholder = encryptedPlaceholder {
                        UnreadableMessageBubble(text: placeholder, systemImage: placeholderIcon, shape: bubbleShape)
                    }
                    if isMine, let status = statusText {
                        HStack(spacing: 4) {
                            if message.status == .read {
                                Image(systemName: "checkmark")
                                    .accessibilityHidden(true)
                            } else if message.status == .failed {
                                Image(systemName: "exclamationmark.circle")
                                    .accessibilityHidden(true)
                            }
                            Text(status)
                        }
                        .stexxLabelStyle(.micro, color: statusColor)
                        .padding(.trailing, 2)
                        .padding(.top, 2)
                    }
                }

                if !isMine { Spacer(minLength: 56) }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var bubbleShape: UnevenRoundedRectangle {
        let big = Theme.Radius.bubble
        let joined: CGFloat = 6
        let top = isFirstInGroup ? big : joined
        let bottom = isLastInGroup ? Theme.Radius.bubbleTail : joined
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
            shape.fill(Theme.frost)
        } else {
            shape
                .fill(Theme.ink1)
                .overlay(shape.stroke(Theme.line, lineWidth: 0.5))
        }
    }

    /// What to show instead of text for an encrypted message this device
    /// can't read (never blank).
    private var encryptedPlaceholder: String? {
        // An encrypted photo's tile already says why it can't be shown.
        if message.attachment?.isEncrypted == true, message.encryption != .awaitingKeyConfirmation {
            return nil
        }
        switch message.encryption {
        case .unavailable?:
            // Typically a reinstall or a new phone: the plaintext was only ever on the old one.
            return String(localized: "Encrypted message. Not available on this phone.")
        case .awaitingKeyConfirmation? where isKeyChangePending:
            return String(localized: "Sent with \(senderName)'s new security key. Accept the key change at the top to read it.")
        case .awaitingKeyConfirmation?:
            return String(localized: "Encrypted message. Not available on this phone.")
        case .unsupported?:
            return String(localized: "This message needs a newer version of Stexx.")
        case .decrypted?, nil:
            return nil
        }
    }

    private var placeholderIcon: String {
        message.encryption == .awaitingKeyConfirmation && isKeyChangePending ? "key" : "lock.slash"
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
        case .read: Theme.steel
        default: Theme.slate
        }
    }

    @ViewBuilder
    private func attachmentView(_ attachment: Message.Attachment) -> some View {
        if attachment.isEncrypted {
            // End-to-end encrypted: fetched, verified and decrypted on device.
            EncryptedPhotoTile(
                message: message,
                isMine: isMine,
                isRevealed: isPhotoRevealed,
                onReveal: onRevealPhoto,
                onOpenViewOnce: onOpenViewOnce
            )
        } else {
            plaintextAttachmentView(attachment)
        }
    }

    /// What a plaintext view-once photo's tile says.
    private enum ViewOnceTile {
        case closed(canOpen: Bool), opened, gone
    }

    private func viewOnceTile(_ attachment: Message.Attachment) -> ViewOnceTile {
        // The sender learns of the open only if the recipient sends read receipts.
        if isMine { return attachment.openedAt != nil ? .opened : .closed(canOpen: false) }
        if attachment.openedAt != nil || isViewOnceOpenedHere { return .opened }
        if isViewOnceSpent { return .gone }
        return .closed(canOpen: message.status != .sending)
    }

    @ViewBuilder
    private func plaintextAttachmentView(_ attachment: Message.Attachment) -> some View {
        if attachment.isViewOnce {
            plaintextViewOnceTile(viewOnceTile(attachment))
        } else {
            plaintextPhotoTile(attachment)
        }
    }

    /// A plaintext view-once photo is never fetched in the bubble: only the
    /// full-screen viewer loads it, and showing it there opens it.
    private func plaintextViewOnceTile(_ tile: ViewOnceTile) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous)
        return ZStack {
            Theme.ink1
            switch tile {
            case .closed(let canOpen):
                PhotoTileNotice(systemImage: "eye.slash", title: "View once", detail: canOpen ? "Tap to open" : nil)
                    .accessibilityAddTraits(canOpen ? .isButton : [])
            case .opened:
                PhotoTileNotice(systemImage: "checkmark.circle", title: "Opened")
            case .gone:
                PhotoTileNotice(systemImage: "hourglass", detail: "Photo no longer available")
            }
            if message.status == .sending {
                ProgressView()
                    .tint(Theme.frost)
            }
        }
        .frame(width: 180, height: 220)
        .clipShape(shape)
        .hairlineBorder(shape)
        .contentShape(shape)
        .onTapGesture {
            if case .closed(canOpen: true) = tile { onOpenViewOnce() }
        }
        .accessibilityActions {
            if case .closed(canOpen: true) = tile {
                Button("Open view-once photo", action: onOpenViewOnce)
            }
        }
    }

    private func plaintextPhotoTile(_ attachment: Message.Attachment) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous)
        return ZStack {
            Theme.ink1
            VStack(spacing: 6) {
                Image(systemName: "photo")
                    .font(.title2.weight(.light))
                Text("Photo")
                    .stexxLabelStyle(.micro, color: Theme.steel)
            }
            .foregroundStyle(Theme.steel)
            if let url = attachment.url {
                // Never through the shared URL cache: no copy on disk.
                PrivateAsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.clear
                }
            }
            if message.status == .sending {
                ProgressView()
                    .tint(Theme.frost)
            }
        }
        .frame(width: 180, height: 220)
        .clipShape(shape)
        .hairlineBorder(shape)
    }
}

/// New bubbles fade up a few points from the sender's side; a plain fade
/// under Reduce Motion. No bounce. Bubbles that were already there just appear.
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
            .scaleEffect(landed || reduceMotion ? 1 : 0.98, anchor: anchor)
            .offset(y: landed || reduceMotion ? 0 : 6)
            .opacity(landed ? 1 : 0)
            .onAppear {
                guard !landed else { return }
                withAnimation(Motion.animation(Motion.quick, reduceMotion: reduceMotion)) {
                    landed = true
                }
                onLanded()
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

/// One quiet line above the composer explaining why a message wasn't sent
/// (new-account and rate limits). Dismissible; cleared by the next send.
private struct SendNoticeRow: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
            Image(systemName: "hand.raised")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.ice)
                .accessibilityHidden(true)
            Text(text)
                .font(.stexxSub)
                .foregroundStyle(Theme.frost)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.steel)
                    .frame(width: 28, height: 28)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, Theme.Spacing.l)
        .padding(.trailing, Theme.Spacing.s)
        .padding(.top, Theme.Spacing.s)
        .accessibilityElement(children: .combine)
    }
}

/// A quiet, dashed bubble for an encrypted message that can't be shown here.
private struct UnreadableMessageBubble: View {
    let text: String
    let systemImage: String
    let shape: UnevenRoundedRectangle

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .accessibilityHidden(true)
            Text(text)
                .font(.stexxSub)
                .italic()
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Theme.steel)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background {
            shape
                .fill(Theme.ink1.opacity(0.6))
                .overlay(shape.stroke(Theme.lineStrong, style: StrokeStyle(lineWidth: 0.75, dash: [4, 3])))
        }
    }
}

/// One centered line at the top of an encrypted thread.
private struct EncryptedThreadLabel: View {
    var body: some View {
        Label("Messages are end-to-end encrypted", systemImage: "lock.fill")
            .stexxLabelStyle(.micro, color: Theme.slate)
            .frame(maxWidth: .infinity)
            .padding(.top, Theme.Spacing.xs)
            .accessibilityElement(children: .combine)
    }
}

/// Warning that the other person's identity key changed. Until the user
/// accepts it, nothing is sent to them and messages under the new key stay
/// hidden (`E2EEngine`). The full safety-number comparison comes later.
struct KeyChangeBanner: View {
    let name: String
    var isAccepting = false
    let accept: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Label {
                Text("\(name)'s security key changed")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.frost)
            } icon: {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(Theme.warning)
            }
            Text("This usually means they reinstalled Stexx or got a new phone. It could also mean someone else is trying to join this chat. Messages to and from \(name) are on hold until you accept the new key.")
                .font(.stexxSub)
                .foregroundStyle(Theme.steel)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: accept) {
                HStack(spacing: Theme.Spacing.s) {
                    if isAccepting { ProgressView().tint(Theme.ink) }
                    Text("Accept new key")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 40)
                .background(Theme.frost, in: shape)
            }
            .buttonStyle(.plain)
            .disabled(isAccepting)
        }
        .padding(Theme.Spacing.m)
        .background(Theme.ink1, in: shape)
        .overlay(shape.stroke(Theme.warning.opacity(0.45), lineWidth: 0.75))
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.s)
        .accessibilityElement(children: .contain)
    }
}

#Preview("Key change") {
    KeyChangeBanner(name: "Alex") {}
        .stexxBackground()
}
