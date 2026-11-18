import SwiftUI

/// The "…" menu on profiles and chats. Safety actions are free and always
/// available.
struct SafetyMenu: View {
    let profile: Profile
    var onBlock: () -> Void
    var onReport: () -> Void

    var body: some View {
        Menu {
            Button(role: .destructive, action: onBlock) {
                Label("Block \(profile.displayName)", systemImage: "hand.raised.fill")
            }
            Button(action: onReport) {
                Label("Report", systemImage: "exclamationmark.bubble.fill")
            }
        } label: {
            Label("Safety options", systemImage: "ellipsis")
        }
    }
}

/// Report flow. Reports go to human moderators; the reported person is not
/// told who reported them. Blocking is on by default.
struct ReportSheet: View {
    let profile: Profile
    var conversationID: Conversation.ID?
    /// Messages already loaded in the thread, offered as optional evidence.
    /// Only used when `conversationID` is set.
    var messages: [Message] = []
    /// Called after a successful report with whether the person was blocked.
    var onComplete: (Bool) -> Void = { _ in }

    @Environment(AppState.self) private var appState
    @Environment(ChatStore.self) private var chatStore
    @Environment(\.apiClient) private var api
    @Environment(\.dismiss) private var dismiss

    @State private var reason: ReportReason?
    @State private var details = ""
    @State private var alsoBlock = true
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var selectedMessageIDs: Set<Message.ID> = []
    @State private var isPickingEvidence = false
    @State private var isSent = false

    /// The newest sent messages, oldest first, as offered in the picker.
    private var evidenceCandidates: [Message] {
        let sent = messages.filter { $0.status != .sending && $0.status != .failed }
            .filter { ($0.text?.isEmpty == false) || $0.attachment != nil }
            .sorted { $0.sentAt < $1.sentAt }
        return Array(sent.suffix(30))
    }

    var body: some View {
        NavigationStack {
            if isSent {
                confirmation
            } else {
                form
            }
        }
        .interactiveDismissDisabled(isSubmitting || isSent)
    }

    private var confirmation: some View {
        VStack(spacing: Theme.Spacing.m) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Theme.ice)
                .accessibilityHidden(true)
            Text("Report sent")
                .font(.stexxHeadline)
                .foregroundStyle(Theme.frost)
            Text("Our moderators review every report. \(profile.displayName) won't know who reported them.")
                .font(.stexxSub)
                .foregroundStyle(Theme.slate)
                .multilineTextAlignment(.center)
            if alsoBlock {
                Text("You've blocked \(profile.displayName).")
                    .font(.stexxSub)
                    .foregroundStyle(Theme.steel)
            }
            Spacer()
            Button {
                dismiss()
                onComplete(alsoBlock)
            } label: {
                Text("Done")
                    .font(.stexxHeadline)
                    .foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.frost, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(Theme.Spacing.l)
        .stexxBackground(intensity: 0.4)
        .navigationBarBackButtonHidden()
        .navigationTitle("Report")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var form: some View {
            Form {
                Section {
                    ForEach(ReportReason.allCases) { item in
                        Button {
                            reason = item
                        } label: {
                            HStack {
                                Label {
                                    Text(item.title).foregroundStyle(Theme.frost)
                                } icon: {
                                    Image(systemName: item.systemImage).foregroundStyle(Theme.steel)
                                }
                                Spacer()
                                if reason == item {
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(Theme.ice)
                                }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(reason == item ? .isSelected : [])
                    }
                } header: {
                    SectionLabel("What's going on?")
                }
                .listRowBackground(Theme.ink1)

                Section {
                    TextField("Anything that helps us understand", text: $details, axis: .vertical)
                        .lineLimit(3...6)
                } header: {
                    SectionLabel("Details (optional)")
                }
                .listRowBackground(Theme.ink1)

                if conversationID != nil {
                    Section {
                        Button {
                            isPickingEvidence = true
                        } label: {
                            HStack {
                                Text("Include messages")
                                    .foregroundStyle(Theme.frost)
                                Spacer()
                                Text(selectedMessageIDs.isEmpty ? "None" : "\(selectedMessageIDs.count) selected")
                                    .foregroundStyle(Theme.slate)
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(Theme.slate)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    } header: {
                        SectionLabel("Include messages (optional)")
                    } footer: {
                        Text("Only the messages you tick are shared with our moderators.")
                            .font(.footnote)
                            .foregroundStyle(Theme.slate)
                    }
                    .listRowBackground(Theme.ink1)
                }

                Section {
                    Toggle("Also block \(profile.displayName)", isOn: $alsoBlock)
                } footer: {
                    Text("Reports are reviewed by people, not just algorithms. \(profile.displayName) won't know who reported them. If you're in danger, contact local emergency services.")
                        .font(.footnote)
                        .foregroundStyle(Theme.slate)
                }
                .listRowBackground(Theme.ink1)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.stexxSub)
                        .foregroundStyle(Theme.danger)
                        .listRowBackground(Theme.ink1)
                }
            }
            .listRowSeparatorTint(Theme.line)
            .tint(Theme.ice)
            .stexxBackground(intensity: 0.4)
            .navigationTitle("Report \(profile.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Button("Send", action: submit)
                            .disabled(reason == nil)
                    }
                }
            }
            .navigationDestination(isPresented: $isPickingEvidence) {
                ReportEvidencePicker(
                    candidates: evidenceCandidates,
                    reportedID: profile.id,
                    theirName: profile.displayName,
                    selection: $selectedMessageIDs
                )
            }
            #if DEBUG
            .task { await applyScreenshotRoute() }
            #endif
    }

    #if DEBUG
    /// Screenshot-only (compiled out of Release): pre-fills the real sheet
    /// from `-StexxScreenshotRoute`, then submits to the mock API for the
    /// confirmation state.
    private func applyScreenshotRoute() async {
        guard let route = ScreenshotRoute.current else { return }
        switch route {
        case .reportFromChat, .reportPicker, .reportSent:
            reason = .harassment
            let theirs = evidenceCandidates.filter { $0.senderID == profile.id }
            selectedMessageIDs = Set(theirs.suffix(2).map(\.id))
            if route == .reportPicker {
                try? await Task.sleep(for: .milliseconds(700))
                isPickingEvidence = true
            }
            if route == .reportSent {
                try? await Task.sleep(for: .milliseconds(500))
                submit()
            }
        default:
            break
        }
    }
    #endif

    private func submit() {
        guard let reason else { return }
        isSubmitting = true
        errorMessage = nil
        // Evidence only goes with a chat report, and only what was ticked.
        let evidence: [ReportEvidence]? = conversationID == nil ? nil : {
            let items = ReportEvidence.from(
                messages: evidenceCandidates,
                selectedIDs: selectedMessageIDs,
                reportedID: profile.id
            )
            return items.isEmpty ? nil : items
        }()
        let request = ReportRequest(
            profileID: profile.id,
            reason: reason,
            details: details.isEmpty ? nil : details,
            conversationID: conversationID,
            alsoBlock: alsoBlock,
            evidence: evidence
        )
        Task {
            defer { isSubmitting = false }
            do {
                try await api.report(request)
                if alsoBlock {
                    appState.markBlocked(profile.id)
                    chatStore.removeConversations(with: profile.id)
                }
                isSent = true
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Lets the reporter tick which recent messages to share with moderators.
struct ReportEvidencePicker: View {
    let candidates: [Message]
    let reportedID: Profile.ID
    let theirName: String
    @Binding var selection: Set<Message.ID>

    private var isFull: Bool { selection.count >= ReportEvidence.maxItems }

    var body: some View {
        List {
            Section {
                ForEach(candidates) { message in
                    let isSelected = selection.contains(message.id)
                    Button {
                        if isSelected {
                            selection.remove(message.id)
                        } else if !isFull {
                            selection.insert(message.id)
                        }
                    } label: {
                        HStack(alignment: .top, spacing: Theme.Spacing.m) {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isSelected ? Theme.ice : Theme.steel)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(message.senderID == reportedID ? theirName : String(localized: "You"))
                                    .stexxLabelStyle(.micro, color: Theme.slate)
                                if message.attachment?.kind == .photo {
                                    Label("Photo", systemImage: "photo")
                                        .font(.footnote)
                                        .foregroundStyle(Theme.steel)
                                }
                                if let text = message.text, !text.isEmpty {
                                    Text(text)
                                        .font(.stexxBody)
                                        .foregroundStyle(Theme.frost)
                                        .lineLimit(2)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(!isSelected && isFull)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
                .listRowBackground(Theme.ink1)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if isFull {
                        Text("You can share up to \(ReportEvidence.maxItems) messages.")
                    }
                    Text("Only the messages you tick are shared with our moderators. Photos aren't uploaded; moderators only see that a photo was sent.")
                }
                .font(.footnote)
                .foregroundStyle(Theme.slate)
            }
        }
        .overlay {
            if candidates.isEmpty {
                ContentUnavailableView("No messages yet", systemImage: "bubble.left")
            }
        }
        .scrollContentBackground(.hidden)
        .stexxBackground(intensity: 0.4)
        .navigationTitle("Include messages")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Lists blocked members with a way to unblock.
struct BlockedProfilesView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.apiClient) private var api
    @State private var blocked: [Profile] = []
    @State private var isLoading = true

    var body: some View {
        List {
            ForEach(blocked) { profile in
                HStack(spacing: Theme.Spacing.m) {
                    AvatarView(profile: profile, size: 40, showsOnline: false)
                    Text(profile.displayName)
                        .font(.stexxHeadline)
                        .foregroundStyle(Theme.frost)
                        .lineLimit(1)
                    Spacer()
                    Button("Unblock") { Task { await unblock(profile) } }
                        .buttonStyle(SafetyUnblockButtonStyle())
                }
                .padding(.vertical, 4)
                .listRowBackground(Color.clear)
                .listRowSeparatorTint(Theme.line)
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + 52 }
            }
        }
        .listStyle(.plain)
        .overlay {
            if isLoading {
                ProgressView()
                    .tint(Theme.steel)
            } else if blocked.isEmpty {
                ContentUnavailableView(
                    "No one blocked",
                    systemImage: "hand.raised",
                    description: Text("People you block can't see you or message you.")
                )
            }
        }
        .stexxBackground(intensity: 0.4)
        .navigationTitle("Blocked")
        .task {
            blocked = (try? await api.blockedProfiles()) ?? []
            isLoading = false
        }
    }

    private func unblock(_ profile: Profile) async {
        do {
            try await api.unblock(profileID: profile.id)
            appState.markUnblocked(profile.id)
            blocked.removeAll { $0.id == profile.id }
        } catch {}
    }
}

/// Small secondary action in a row: mono caps frost on ink1, radius 4,
/// hairline border; dims when pressed.
private struct SafetyUnblockButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous)
        configuration.label
            .stexxLabelStyle(color: Theme.frost)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(shape.fill(configuration.isPressed ? Theme.ink2 : Theme.ink1))
            .overlay(shape.strokeBorder(Theme.lineStrong, lineWidth: 0.5))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .contentShape(shape)
    }
}

#Preview("Report") {
    ReportSheet(profile: MockData.profiles[1])
        .previewEnvironment()
}

#Preview("Blocked") {
    NavigationStack {
        BlockedProfilesView()
    }
    .previewEnvironment()
}
