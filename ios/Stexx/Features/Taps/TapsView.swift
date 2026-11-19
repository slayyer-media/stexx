import SwiftUI

/// Pushed from the Taps row at the top of the Chats list.
struct TapsRoute: Hashable {}

/// Who tapped you (`GET /me/taps`): newest first, one row per sender, with
/// infinite scroll. Opening it marks every tap seen (`POST /me/taps/seen`),
/// which clears them from the Chats badge; the senders that were new keep
/// their dot while you're on this screen.
///
/// Tapping a row opens the profile (the host stack's `Profile` destination).
/// Swipe right, or long-press, to tap back.
struct TapsView: View {
    @Environment(ChatStore.self) private var chatStore
    @Environment(AppState.self) private var appState
    @Environment(\.apiClient) private var api

    /// Senders that were new when you opened the screen (or tapped you while
    /// it was open). The store already counts them as seen.
    @State private var highlighted: Set<Profile.ID> = []
    @State private var tappedBack: Set<Profile.ID> = []
    @State private var tapBackCount = 0
    @State private var tapBackError: String?

    private var visibleTaps: [ReceivedTap] {
        chatStore.taps.filter { !appState.blockedIDs.contains($0.id) }
    }

    var body: some View {
        let visible = visibleTaps
        let lastID = visible.last?.id

        List {
            if !visible.isEmpty {
                summary(count: visible.count, new: visible.filter { highlighted.contains($0.id) }.count)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(visible) { tap in
                NavigationLink(value: tap.from) {
                    TapRow(
                        tap: tap,
                        isNew: highlighted.contains(tap.id),
                        didTapBack: tappedBack.contains(tap.id)
                    )
                }
                .listRowBackground(Color.clear)
                .listRowSeparatorTint(Theme.line)
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + 64 }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    if !tappedBack.contains(tap.id) {
                        Button {
                            Task { await tapBack(tap.from) }
                        } label: {
                            Label("Tap back", systemImage: "hand.wave.fill")
                        }
                        .tint(Theme.ice)
                    }
                }
                .contextMenu {
                    Button {
                        Task { await tapBack(tap.from) }
                    } label: {
                        Label(tappedBack.contains(tap.id) ? "Tapped back" : "Tap back", systemImage: "hand.wave")
                    }
                    .disabled(tappedBack.contains(tap.id))
                }
                .onAppear {
                    if tap.id == lastID { Task { await chatStore.loadMoreTaps() } }
                }
            }
            if chatStore.isLoadingTaps && chatStore.tapsNextCursor != nil && !visible.isEmpty {
                ProgressView()
                    .tint(Theme.steel)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .overlay {
            if visible.isEmpty {
                if chatStore.isLoadingTaps || !chatStore.hasLoadedTaps && chatStore.tapsErrorMessage == nil {
                    ProgressView()
                        .tint(Theme.steel)
                } else if let error = chatStore.tapsErrorMessage {
                    ContentUnavailableView {
                        Label("Couldn't load taps", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(error)
                            .font(.stexxSub)
                            .foregroundStyle(Theme.steel)
                    } actions: {
                        Button("Try again") { Task { await chatStore.loadTaps() } }
                            .stexxSecondaryButton()
                    }
                } else {
                    emptyState
                }
            }
        }
        .stexxBackground(intensity: 0.4)
        .navigationTitle("Taps")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await chatStore.loadTaps() }
        .task { await open() }
        .onChange(of: chatStore.tapsUnseen) { _, unseen in
            // Someone tapped you while you're looking: show them as new and
            // keep the badge clear.
            guard unseen > 0 else { return }
            highlighted.formUnion(chatStore.taps.filter(\.isNew).map(\.id))
            Task { await chatStore.markTapsSeen() }
        }
        .sensoryFeedback(.success, trigger: tapBackCount)
        .alert("Couldn't tap back", isPresented: Binding(
            get: { tapBackError != nil },
            set: { if !$0 { tapBackError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(tapBackError ?? "")
        }
    }

    private func summary(count: Int, new: Int) -> some View {
        Group {
            if new > 0 {
                SectionLabel("\(count) taps, \(new) new")
            } else {
                SectionLabel("\(count) taps")
            }
        }
        .padding(.top, Theme.Spacing.s)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label {
                Text("No taps yet")
                    .stexxTitleStyle(.title)
            } icon: {
                Image(systemName: "hand.wave")
                    .font(.system(size: 32, weight: .regular))
                    .foregroundStyle(Theme.frost)
                    .frame(width: 64, height: 64)
                    .cellCorners()
                    .padding(.bottom, Theme.Spacing.s)
                    .accessibilityHidden(true)
            }
        } description: {
            Text("When someone taps you, they show up here, even if you were offline.")
                .font(.stexxSub)
                .foregroundStyle(Theme.steel)
        }
    }

    /// Load if needed, remember who was new, then mark everything seen.
    private func open() async {
        if !chatStore.hasLoadedTaps { await chatStore.loadTaps() }
        highlighted.formUnion(chatStore.taps.filter(\.isNew).map(\.id))
        await chatStore.markTapsSeen()
    }

    private func tapBack(_ profile: Profile) async {
        guard !tappedBack.contains(profile.id) else { return }
        tappedBack.insert(profile.id)
        do {
            try await api.sendTap(to: profile.id)
            tapBackCount += 1
        } catch {
            tappedBack.remove(profile.id)
            tapBackError = error.localizedDescription
        }
    }
}

/// One sender: square avatar with the static online dot, name and age, a
/// mono-caps "tapped … ago" line, and a dot while the tap is new.
private struct TapRow: View {
    let tap: ReceivedTap
    let isNew: Bool
    let didTapBack: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            AvatarView(profile: tap.from, size: 52)

            VStack(alignment: .leading, spacing: 5) {
                Text(tap.from.nameAndAge)
                    .font(.stexxHeadline)
                    .foregroundStyle(Theme.frost)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(tap.sentAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
                    if let distance = tap.from.distanceMeters {
                        Text(verbatim: "/")
                            .foregroundStyle(Theme.slate)
                            .accessibilityHidden(true)
                        Text(StexxFormat.distance(distance))
                    }
                }
                .stexxLabelStyle(color: isNew ? Theme.frost : Theme.steel)
                .lineLimit(1)
            }

            Spacer(minLength: Theme.Spacing.s)

            if didTapBack {
                Image(systemName: "hand.wave.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.steel)
                    .accessibilityLabel("Tapped back")
            }
            if isNew {
                Circle()
                    .fill(Theme.ice)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isNew ? Text("New") : Text(verbatim: ""))
        .accessibilityHint("Opens the profile. Swipe right to tap back.")
    }
}

#Preview {
    NavigationStack {
        TapsView()
            .navigationDestination(for: Profile.self) { ProfileDetailView(profile: $0) }
    }
    .previewEnvironment()
}
