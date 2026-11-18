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

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(ReportReason.allCases) { item in
                        Button {
                            reason = item
                        } label: {
                            HStack {
                                Label {
                                    Text(item.title).foregroundStyle(Theme.textPrimary)
                                } icon: {
                                    Image(systemName: item.systemImage).foregroundStyle(Theme.violetBright)
                                }
                                Spacer()
                                if reason == item {
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(Theme.violetBright)
                                }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(reason == item ? .isSelected : [])
                    }
                } header: {
                    Text("What's going on?")
                }

                Section("Details (optional)") {
                    TextField("Anything that helps us understand", text: $details, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section {
                    Toggle("Also block \(profile.displayName)", isOn: $alsoBlock)
                } footer: {
                    Text("Reports are reviewed by people, not just algorithms. \(profile.displayName) won't know who reported them. If you're in danger, contact local emergency services.")
                }

                if let errorMessage {
                    Text(errorMessage).foregroundStyle(Theme.danger)
                }
            }
            .stexxBackground(intensity: 0.5)
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
            .interactiveDismissDisabled(isSubmitting)
        }
    }

    private func submit() {
        guard let reason else { return }
        isSubmitting = true
        errorMessage = nil
        let request = ReportRequest(
            profileID: profile.id,
            reason: reason,
            details: details.isEmpty ? nil : details,
            conversationID: conversationID,
            alsoBlock: alsoBlock
        )
        Task {
            defer { isSubmitting = false }
            do {
                try await api.report(request)
                if alsoBlock {
                    appState.markBlocked(profile.id)
                    chatStore.removeConversations(with: profile.id)
                }
                dismiss()
                onComplete(alsoBlock)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
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
                    Spacer()
                    Button("Unblock") { Task { await unblock(profile) } }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
                .listRowBackground(Theme.surface)
            }
        }
        .overlay {
            if isLoading {
                ProgressView()
            } else if blocked.isEmpty {
                ContentUnavailableView(
                    "No one blocked",
                    systemImage: "hand.raised",
                    description: Text("People you block can't see you or message you.")
                )
            }
        }
        .stexxBackground(intensity: 0.5)
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
