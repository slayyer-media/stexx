import SwiftUI

/// Full profile: a rim-lit hero gallery in a cell frame (the grid tile zooms
/// into it), hairline-separated sections, and the favorite / tap / message
/// black-glass action bar. Block and report
/// are always one tap away in the menu.
struct ProfileDetailView: View {
    /// The profile plus favorite / tap / block and their error states.
    @State private var actions: ProfileActions
    private var profile: Profile { actions.profile }

    @Environment(AppState.self) private var appState
    @Environment(ChatStore.self) private var chatStore
    @Environment(\.apiClient) private var api
    @Environment(\.dismiss) private var dismiss

    @State private var photoIndex = 0
    @State private var isConfirmingBlock = false
    @State private var isReporting = false
    @State private var isShowingChat = false
    @State private var favoriteTaps = 0
    /// Drives the staggered entrance of the cards below the hero.
    @State private var hasAppeared = false

    init(profile: Profile) {
        _actions = State(initialValue: ProfileActions(profile: profile))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero
                    .padding(.horizontal, Theme.Spacing.m)
                    .padding(.top, Theme.Spacing.s)

                identity
                    .padding(.top, Theme.Spacing.xl)
                    .padding(.horizontal, Theme.Spacing.screen)

                VStack(alignment: .leading, spacing: 0) {
                    if hasHeaderContent {
                        headerSection
                            .modifier(DetailEntrance(index: 0, isVisible: hasAppeared))
                    }
                    if let about = profile.about, !about.isEmpty {
                        DetailSection("About") {
                            Text(about)
                                .font(.stexxBody)
                                .foregroundStyle(Theme.frost)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .modifier(DetailEntrance(index: 1, isVisible: hasAppeared))
                    }
                    if !profile.lookingFor.isEmpty {
                        DetailSection("Looking for") {
                            FlowLayout {
                                ForEach(profile.lookingFor) { item in
                                    DetailTag(systemImage: item.systemImage, text: Text(item.title))
                                }
                            }
                        }
                        .modifier(DetailEntrance(index: 2, isVisible: hasAppeared))
                    }
                    if !profile.tags.isEmpty {
                        DetailSection("Into") {
                            FlowLayout {
                                ForEach(profile.tags, id: \.self) { TagChip(text: $0) }
                            }
                        }
                        .modifier(DetailEntrance(index: 3, isVisible: hasAppeared))
                    }
                }
                .padding(.horizontal, Theme.Spacing.screen)
            }
            .padding(.bottom, 112)
        }
        .stexxBackground(intensity: 0.6)
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
                .disabled(actions.isBlocking)
            }
        }
        .errorToast($actions.toast)
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
        // A failed block must never look like it worked: the profile stays,
        // and this says so and offers Retry.
        .alert(
            "Couldn't block \(profile.displayName)",
            isPresented: Binding(
                get: { actions.blockFailure != nil },
                set: { if !$0 { actions.blockFailure = nil } }
            )
        ) {
            Button("Retry") { Task { await block() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(profile.displayName) isn't blocked yet. \(actions.blockFailure ?? "")")
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
                actions.profile = fresh
            }
        }
    }

    // MARK: Hero

    /// The screen's one hero surface: cell corners and the rim light.
    private var hero: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
        return Color.clear
            .aspectRatio(4.0 / 5.0, contentMode: .fit)
            .overlay { gallery }
            .overlay(alignment: .top) { pageIndicator }
            .clipShape(shape)
            .overlay { shape.strokeBorder(Theme.line, lineWidth: 0.5).allowsHitTesting(false) }
            .rimLight(shape)
            .cellCorners(outset: 5)
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

    /// Thin story-style page bars across the top of the photo.
    @ViewBuilder
    private var pageIndicator: some View {
        if profile.photos.count > 1 {
            HStack(spacing: 3) {
                ForEach(profile.photos.indices, id: \.self) { index in
                    Rectangle()
                        .fill(index == photoIndex ? Theme.frost : Theme.frost.opacity(0.28))
                        .frame(height: 2)
                }
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.top, Theme.Spacing.m)
            .animation(Motion.quick, value: photoIndex)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// Name in heavy display, then a mono-caps meta line.
    private var identity: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                Text(profile.nameAndAge)
                    .stexxTitleStyle()
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)
                if let pronouns = profile.pronouns, !pronouns.isEmpty {
                    Text(pronouns)
                        .font(.stexxSub)
                        .foregroundStyle(Theme.steel)
                }
            }
            HStack(spacing: Theme.Spacing.s) {
                if profile.isOnline {
                    OnlineDot()
                        .accessibilityHidden(true)
                }
                Text(StexxFormat.lastSeen(profile.lastActiveAt, isOnline: profile.isOnline))
                    .stexxLabelStyle(color: profile.isOnline ? Theme.frost : Theme.steel)
                if let distance = profile.distanceMeters {
                    Text(verbatim: "/")
                        .stexxLabelStyle(color: Theme.slate)
                        .accessibilityHidden(true)
                    Text(StexxFormat.distance(distance))
                        .stexxLabelStyle()
                }
            }
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: Sections

    private var hasHeaderContent: Bool {
        (profile.headline.map { !$0.isEmpty } ?? false) || profile.heightCm != nil || profile.position != nil
    }

    /// Headline as plain body text, then the stats as a hairline-ruled
    /// mono-caps row.
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            if let headline = profile.headline, !headline.isEmpty {
                Text(headline)
                    .font(.stexxHeadline)
                    .foregroundStyle(Theme.frost)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if profile.heightCm != nil || profile.position != nil {
                VStack(spacing: 0) {
                    HairlineDivider()
                    HStack(spacing: 0) {
                        if let height = profile.heightCm {
                            let value = StexxFormat.height(cm: height)
                            DetailStat(
                                title: Text("Height"),
                                value: Text(value),
                                accessibilityText: Text("Height: \(value)")
                            )
                        }
                        if profile.heightCm != nil && profile.position != nil {
                            Rectangle()
                                .fill(Theme.line)
                                .frame(width: 0.5)
                                .padding(.vertical, Theme.Spacing.s)
                                .accessibilityHidden(true)
                        }
                        if let position = profile.position {
                            DetailStat(
                                title: Text("Position"),
                                value: Text(position.title),
                                accessibilityText: Text("Position: \(String(localized: position.title))")
                            )
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    HairlineDivider()
                }
            }
        }
        .padding(.top, Theme.Spacing.xl)
    }

    // MARK: Actions

    /// Floating black-glass bar: favorite, tap, and the frost Message button.
    private var actionBar: some View {
        GlassEffectContainer(spacing: Theme.Spacing.s) {
            HStack(spacing: Theme.Spacing.s) {
                GlassIconButton(
                    profile.isFavorite ? "Remove favorite" : "Favorite",
                    systemImage: profile.isFavorite ? "star.fill" : "star",
                    isProminent: profile.isFavorite
                ) {
                    favoriteTaps += 1
                    Task { await actions.toggleFavorite(using: api) }
                }
                .sensoryFeedback(.selection, trigger: favoriteTaps)

                GlassIconButton(
                    actions.didTap ? "Tapped" : "Send a tap",
                    systemImage: actions.didTap ? "hand.wave.fill" : "hand.wave"
                ) {
                    Task { await actions.sendTap(using: api) }
                }
                .disabled(actions.didTap)
                .sensoryFeedback(.success, trigger: actions.didTap) { _, didTap in didTap }

                Button {
                    isShowingChat = true
                } label: {
                    WideLabel("Message", systemImage: "bubble.left.fill")
                }
                .stexxPrimaryButton()
                .sensoryFeedback(.impact(weight: .light), trigger: isShowingChat) { _, isShowing in
                    isShowing
                }
            }
            .padding(Theme.Spacing.s)
        }
        .blackGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.bottom, Theme.Spacing.s)
    }

    /// Hides the profile and leaves only once the server confirmed the
    /// block; otherwise `ProfileActions` raises the "Couldn't block" alert.
    private func block() async {
        guard await actions.block(using: api) else { return }
        appState.markBlocked(profile.id)
        chatStore.removeConversations(with: profile.id)
        dismiss()
    }
}

// MARK: - Pieces

/// A content section on the plain background: hairline on top, "× TITLE"
/// mono label, then the content. No card.
private struct DetailSection<Content: View>: View {
    let title: LocalizedStringKey
    let content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HairlineDivider()
                .padding(.top, Theme.Spacing.xl)
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                SectionLabel(title)
                content
            }
            .padding(.top, Theme.Spacing.l)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One cell of the stats row: micro label over a mono-caps value.
private struct DetailStat: View {
    let title: Text
    let value: Text
    let accessibilityText: Text

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            title
                .stexxLabelStyle(.micro, color: Theme.slate)
            value
                .stexxLabelStyle(color: Theme.frost)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Theme.Spacing.m)
        .padding(.leading, Theme.Spacing.m)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }
}

/// Static tag with an icon (what someone is looking for): radius 4, ink1,
/// hairline, mono caps steel.
private struct DetailTag: View {
    let systemImage: String
    let text: Text

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous)
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .imageScale(.small)
                .accessibilityHidden(true)
            text
        }
        .stexxLabelStyle()
        .lineLimit(1)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(shape.fill(Theme.ink1))
        .overlay(shape.strokeBorder(Theme.line, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }
}

/// Sections fade up a few points into place. Under Reduce Motion they are
/// simply there.
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
                .offset(y: isVisible ? 0 : 8)
                .animation(Motion.standard.delay(0.08 + 0.04 * Double(index)), value: isVisible)
        }
    }
}

#Preview {
    NavigationStack {
        ProfileDetailView(profile: MockData.profiles[0])
    }
    .previewEnvironment()
}
