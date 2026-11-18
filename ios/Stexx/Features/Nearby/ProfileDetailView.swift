import SwiftUI

/// Full profile: photo gallery, details, and the message / tap / favorite
/// action bar. Block and report are always one tap away in the menu.
struct ProfileDetailView: View {
    @State private var profile: Profile

    @Environment(AppState.self) private var appState
    @Environment(ChatStore.self) private var chatStore
    @Environment(\.apiClient) private var api
    @Environment(\.dismiss) private var dismiss

    @State private var photoIndex = 0
    @State private var didTap = false
    @State private var isConfirmingBlock = false
    @State private var isReporting = false

    init(profile: Profile) {
        _profile = State(initialValue: profile)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.l) {
                gallery

                VStack(spacing: Theme.Spacing.m) {
                    headerCard
                    if let about = profile.about, !about.isEmpty {
                        GlassCard {
                            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                                SectionLabel("About")
                                Text(about)
                                    .font(.body)
                                    .foregroundStyle(Theme.textPrimary)
                            }
                        }
                    }
                    detailsCard
                    if !profile.tags.isEmpty {
                        GlassCard {
                            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                                SectionLabel("Into")
                                FlowLayout {
                                    ForEach(profile.tags, id: \.self) { TagChip(text: $0) }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.m)
            }
            .padding(.bottom, 96)
        }
        .ignoresSafeArea(.container, edges: .top)
        .stexxBackground(intensity: 0.7)
        .safeAreaInset(edge: .bottom) { actionBar }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                SafetyMenu(
                    profile: profile,
                    onBlock: { isConfirmingBlock = true },
                    onReport: { isReporting = true }
                )
            }
        }
        .confirmationDialog(
            "Block \(profile.displayName)?",
            isPresented: $isConfirmingBlock,
            titleVisibility: .visible
        ) {
            Button("Block", role: .destructive) { Task { await block() } }
        } message: {
            Text("They won't be able to see you or message you, and won't be notified.")
        }
        .sheet(isPresented: $isReporting) {
            ReportSheet(profile: profile) { didBlock in
                if didBlock { dismiss() }
            }
        }
        .task {
            if let fresh = try? await api.profile(id: profile.id) {
                profile = fresh
            }
        }
    }

    // MARK: Sections

    private var gallery: some View {
        TabView(selection: $photoIndex) {
            ForEach(Array(profile.photos.indices), id: \.self) { index in
                ProfilePhotoView(profile: profile, photoIndex: index)
                    .tag(index)
            }
            if profile.photos.isEmpty {
                PhotoPlaceholder(seed: profile.id).tag(0)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: profile.photos.count > 1 ? .always : .never))
        .frame(height: 480)
        .overlay(alignment: .bottom) {
            LinearGradient(colors: [.clear, Theme.background.opacity(0.9)], startPoint: .top, endPoint: .bottom)
                .frame(height: 120)
                .allowsHitTesting(false)
        }
        .accessibilityLabel("Photos of \(profile.displayName)")
    }

    private var headerCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                    Text(profile.nameAndAge)
                        .font(.stexxTitle)
                        .foregroundStyle(Theme.textPrimary)
                    if let pronouns = profile.pronouns {
                        Text(pronouns)
                            .font(.subheadline)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                HStack(spacing: Theme.Spacing.m) {
                    HStack(spacing: 6) {
                        if profile.isOnline { OnlineDot(size: 8) }
                        Text(StexxFormat.lastSeen(profile.lastActiveAt, isOnline: profile.isOnline))
                    }
                    if let distance = profile.distanceMeters {
                        Label(StexxFormat.distance(distance), systemImage: "location")
                    }
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.textSecondary)

                if let headline = profile.headline {
                    Text(headline)
                        .font(.body.italic())
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.top, 4)
                }
            }
        }
    }

    private var detailsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                SectionLabel("Details")
                Grid(alignment: .leading, horizontalSpacing: Theme.Spacing.l, verticalSpacing: Theme.Spacing.s) {
                    if let height = profile.heightCm {
                        detailRow("Height", value: Text(StexxFormat.height(cm: height)))
                    }
                    if let position = profile.position {
                        detailRow("Position", value: Text(position.title))
                    }
                    if !profile.lookingFor.isEmpty {
                        detailRow(
                            "Looking for",
                            value: Text(profile.lookingFor.map { String(localized: $0.title) }.formatted(.list(type: .and)))
                        )
                    }
                }
                .font(.subheadline)
            }
        }
    }

    private func detailRow(_ label: LocalizedStringKey, value: Text) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(Theme.textTertiary)
            value
                .foregroundStyle(Theme.textPrimary)
        }
    }

    private var actionBar: some View {
        GlassEffectContainer(spacing: Theme.Spacing.m) {
            HStack(spacing: Theme.Spacing.m) {
                GlassIconButton(
                    profile.isFavorite ? "Remove favorite" : "Favorite",
                    systemImage: profile.isFavorite ? "star.fill" : "star"
                ) {
                    Task { await toggleFavorite() }
                }
                GlassIconButton(didTap ? "Tapped" : "Send a tap", systemImage: didTap ? "hand.wave.fill" : "hand.wave") {
                    Task { await sendTap() }
                }
                .disabled(didTap)
                .sensoryFeedback(.success, trigger: didTap)

                NavigationLink(value: ChatRoute(participant: profile)) {
                    WideLabel("Message", systemImage: "bubble.left.fill")
                }
                .stexxPrimaryButton()
            }
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.bottom, Theme.Spacing.s)
    }

    // MARK: Actions

    private func toggleFavorite() async {
        let newValue = !profile.isFavorite
        profile.isFavorite = newValue
        do {
            try await api.setFavorite(newValue, profileID: profile.id)
        } catch {
            profile.isFavorite = !newValue
        }
    }

    private func sendTap() async {
        didTap = true
        do {
            try await api.sendTap(to: profile.id)
        } catch {
            didTap = false
        }
    }

    private func block() async {
        do {
            try await api.block(profileID: profile.id)
            appState.markBlocked(profile.id)
            chatStore.removeConversations(with: profile.id)
            dismiss()
        } catch {
            // Keep the profile visible; the user can retry from the menu.
        }
    }
}

#Preview {
    NavigationStack {
        ProfileDetailView(profile: MockData.profiles[0])
    }
    .previewEnvironment()
}
