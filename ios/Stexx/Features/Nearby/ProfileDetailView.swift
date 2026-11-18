import SwiftUI

/// Full profile: a glowing hero gallery (the grid tile zooms into it), glass
/// info cards, and the favorite / tap / message action bar. Block and report
/// are always one tap away in the menu.
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
    @State private var isShowingChat = false
    @State private var favoriteTaps = 0
    /// Drives the staggered entrance of the cards below the hero.
    @State private var hasAppeared = false

    init(profile: Profile) {
        _profile = State(initialValue: profile)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.m) {
                hero
                    .padding(.horizontal, Theme.Spacing.s + 2)
                    .padding(.bottom, Theme.Spacing.xs)

                VStack(spacing: Theme.Spacing.m) {
                    if hasHeaderContent {
                        headerCard
                            .modifier(DetailEntrance(index: 0, isVisible: hasAppeared))
                    }
                    if let about = profile.about, !about.isEmpty {
                        GlassCard {
                            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                                DetailCardTitle("About")
                                Text(about)
                                    .font(.body)
                                    .foregroundStyle(Theme.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .modifier(DetailEntrance(index: 1, isVisible: hasAppeared))
                    }
                    if !profile.lookingFor.isEmpty {
                        GlassCard {
                            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                                DetailCardTitle("Looking for")
                                FlowLayout {
                                    ForEach(profile.lookingFor) { item in
                                        DetailPill(systemImage: item.systemImage, text: Text(item.title))
                                    }
                                }
                            }
                        }
                        .modifier(DetailEntrance(index: 2, isVisible: hasAppeared))
                    }
                    if !profile.tags.isEmpty {
                        GlassCard {
                            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                                DetailCardTitle("Into")
                                FlowLayout {
                                    ForEach(profile.tags, id: \.self) { TagChip(text: $0) }
                                }
                            }
                        }
                        .modifier(DetailEntrance(index: 3, isVisible: hasAppeared))
                    }
                }
                .padding(.horizontal, Theme.Spacing.m)
            }
            .padding(.bottom, 96)
        }
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
        .navigationDestination(isPresented: $isShowingChat) {
            ChatThreadView(route: ChatRoute(participant: profile))
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
        .onAppear {
            if !hasAppeared { hasAppeared = true }
        }
        .task {
            if let fresh = try? await api.profile(id: profile.id) {
                profile = fresh
            }
        }
    }

    // MARK: Hero

    private var hero: some View {
        Color.clear
            .aspectRatio(4.0 / 5.0, contentMode: .fit)
            .overlay { gallery }
            .overlay(alignment: .bottom) { heroCaption }
            .overlay(alignment: .top) { pageIndicator }
            .glowFrame(cornerRadius: Theme.Radius.card + 6, glow: 1.3)
    }

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
        .tabViewStyle(.page(indexDisplayMode: .never))
        .accessibilityLabel("Photos of \(profile.displayName)")
        .accessibilityValue(photoPositionText)
    }

    private var photoPositionText: Text {
        guard profile.photos.count > 1 else { return Text(verbatim: "") }
        return Text("Photo \(photoIndex + 1) of \(profile.photos.count)")
    }

    /// Story-style page bars across the top of the photo.
    @ViewBuilder
    private var pageIndicator: some View {
        if profile.photos.count > 1 {
            HStack(spacing: 4) {
                ForEach(profile.photos.indices, id: \.self) { index in
                    Capsule()
                        .fill(index == photoIndex ? Color.white : Color.white.opacity(0.32))
                        .frame(height: 3)
                        .shadow(color: index == photoIndex ? Theme.edgeGlow : .clear, radius: 4)
                }
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.top, Theme.Spacing.m)
            .animation(Motion.snappy, value: photoIndex)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private var heroCaption: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                Text(profile.nameAndAge)
                    .font(.stexxHero)
                    .tracking(Theme.Tracking.display)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)
                if let pronouns = profile.pronouns, !pronouns.isEmpty {
                    Text(pronouns)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.72))
                }
            }
            HStack(spacing: Theme.Spacing.s) {
                if profile.isOnline {
                    OnlineGlow(size: 9)
                        .accessibilityHidden(true)
                }
                Text(StexxFormat.lastSeen(profile.lastActiveAt, isOnline: profile.isOnline))
                if let distance = profile.distanceMeters {
                    Text(verbatim: "·")
                        .accessibilityHidden(true)
                    Label(StexxFormat.distance(distance), systemImage: "location.fill")
                        .labelStyle(.titleAndIcon)
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white.opacity(0.85))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Spacing.l + 2)
        .padding(.top, 72)
        .padding(.bottom, Theme.Spacing.l + 2)
        .background(Theme.photoScrim)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    // MARK: Cards

    private var hasHeaderContent: Bool {
        (profile.headline.map { !$0.isEmpty } ?? false) || profile.heightCm != nil || profile.position != nil
    }

    private var headerCard: some View {
        GlassCard(tint: Theme.violet.opacity(0.08)) {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                if let headline = profile.headline, !headline.isEmpty {
                    Text(headline)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 14)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(Theme.accentGradient)
                                .frame(width: 4)
                                .shadow(color: Theme.edgeGlow.opacity(0.6), radius: 4)
                        }
                }
                if profile.heightCm != nil || profile.position != nil {
                    FlowLayout {
                        if let height = profile.heightCm {
                            let value = StexxFormat.height(cm: height)
                            DetailPill(
                                systemImage: "ruler",
                                text: Text(value),
                                accessibilityText: Text("Height: \(value)")
                            )
                        }
                        if let position = profile.position {
                            DetailPill(
                                systemImage: "arrow.up.arrow.down",
                                text: Text(position.title),
                                accessibilityText: Text("Position: \(String(localized: position.title))")
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: Actions

    private var actionBar: some View {
        GlassEffectContainer(spacing: Theme.Spacing.m) {
            HStack(spacing: Theme.Spacing.m) {
                GlassIconButton(
                    profile.isFavorite ? "Remove favorite" : "Favorite",
                    systemImage: profile.isFavorite ? "star.fill" : "star",
                    isProminent: profile.isFavorite
                ) {
                    favoriteTaps += 1
                    Task { await toggleFavorite() }
                }
                .sensoryFeedback(.impact(weight: .light), trigger: favoriteTaps)

                GlassIconButton(didTap ? "Tapped" : "Send a tap", systemImage: didTap ? "hand.wave.fill" : "hand.wave") {
                    Task { await sendTap() }
                }
                .disabled(didTap)
                .sensoryFeedback(.success, trigger: didTap)

                Button {
                    isShowingChat = true
                } label: {
                    WideLabel("Message", systemImage: "bubble.left.fill")
                }
                .stexxPrimaryButton()
                .sensoryFeedback(.impact(weight: .medium), trigger: isShowingChat) { _, isShowing in
                    isShowing
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.top, Theme.Spacing.xl)
        .padding(.bottom, Theme.Spacing.s)
        // Fade the scrolled cards out under the floating actions so text
        // never shows through the glass buttons.
        .background {
            LinearGradient(
                stops: [
                    .init(color: Theme.background.opacity(0), location: 0),
                    .init(color: Theme.background.opacity(0.92), location: 0.28),
                    .init(color: Theme.background, location: 0.5),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)
        }
    }

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

// MARK: - Pieces

/// Heavy card heading with a small violet accent.
private struct DetailCardTitle: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        HStack(spacing: 6) {
            Capsule()
                .fill(Theme.accentGradient)
                .frame(width: 10, height: 4)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline.weight(.heavy))
                .tracking(Theme.Tracking.tight)
                .foregroundStyle(Theme.textPrimary)
        }
        .accessibilityAddTraits(.isHeader)
    }
}

/// Violet-tinted pill for facts like height, position, or what someone is
/// looking for.
private struct DetailPill: View {
    let systemImage: String
    let text: Text
    var accessibilityText: Text?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(Theme.violetBright)
                .accessibilityHidden(true)
            text
                .foregroundStyle(Theme.textPrimary)
        }
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Theme.violet.opacity(0.16), in: .capsule)
        .overlay(Capsule().strokeBorder(Theme.violet.opacity(0.35), lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText ?? text)
    }
}

/// Cards rise into place with a staggered spring. Under Reduce Motion they
/// are simply there.
private struct DetailEntrance: ViewModifier {
    let index: Int
    let isVisible: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content
                .opacity(isVisible ? 1 : 0)
                .offset(y: isVisible ? 0 : 28)
                .scaleEffect(isVisible ? 1 : 0.96, anchor: .top)
                .animation(Motion.cardSpring.delay(0.12 + 0.06 * Double(index)), value: isVisible)
        }
    }
}

#Preview {
    NavigationStack {
        ProfileDetailView(profile: MockData.profiles[0])
    }
    .previewEnvironment()
}
