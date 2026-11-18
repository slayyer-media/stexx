import SwiftUI

/// The grid of people nearby, closest first.
///
/// The grid mixes tile sizes: every cycle starts with a featured block (one
/// 2x2 tile plus two stacked small tiles, alternating sides) followed by a
/// few dense rows of three. Within a featured block the most recently active
/// person gets the big tile, so the server's closest-first order is only
/// shuffled locally, never across blocks.
struct NearbyView: View {
    enum QuickFilter: Hashable, CaseIterable {
        case all, online, rightNow, favorites

        var title: LocalizedStringKey {
            switch self {
            case .all: "All"
            case .online: "Online"
            case .rightNow: "Right now"
            case .favorites: "Favorites"
            }
        }

        var systemImage: String? {
            switch self {
            case .all: nil
            case .online: "circle.fill"
            case .rightNow: "flame.fill"
            case .favorites: "star.fill"
            }
        }
    }

    @Environment(AppState.self) private var appState
    @Environment(\.apiClient) private var api
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var profiles: [Profile] = []
    @State private var nextCursor: String?
    @State private var quickFilter: QuickFilter = .all
    /// Stexx+ filters edited in `FilterSheet`.
    @State private var advanced = NearbyQuery()
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isShowingFilters = false
    @State private var loadedQuery: NearbyQuery?
    @State private var path = NavigationPath()

    @Namespace private var zoomNamespace

    private var visibleProfiles: [Profile] {
        profiles.filter { !appState.blockedIDs.contains($0.id) }
    }

    private var hasActiveAdvancedFilters: Bool {
        appState.hasPlus && advanced.usesAdvancedFilters
    }

    private var query: NearbyQuery {
        var query = appState.hasPlus ? advanced : NearbyQuery()
        query.cursor = nil
        query.onlineOnly = quickFilter == .online
        query.favoritesOnly = quickFilter == .favorites
        query.lookingFor = quickFilter == .rightNow ? [.rightNow] : []
        return query
    }

    var body: some View {
        let visible = visibleProfiles
        let blocks = NearbyGridBlock.make(from: visible)
        let lastBlockID = blocks.last?.id

        NavigationStack(path: $path) {
            ScrollView {
                header(for: visible)
                    .padding(.horizontal, Theme.Spacing.screen)
                    .padding(.top, Theme.Spacing.s)
                    .padding(.bottom, Theme.Spacing.l)

                filterBar
                    .padding(.bottom, Theme.Spacing.l)

                LazyVStack(spacing: NearbyGridMetrics.spacing) {
                    ForEach(blocks) { block in
                        blockView(block)
                            .onAppear {
                                if block.id == lastBlockID { Task { await loadMore() } }
                            }
                    }
                }
                .padding(.horizontal, NearbyGridMetrics.spacing)
                .padding(.bottom, Theme.Spacing.xl)

                if isLoading && profiles.isEmpty {
                    ProgressView()
                        .controlSize(.regular)
                        .tint(Theme.steel)
                        .padding(.top, 80)
                }
            }
            .overlay {
                if !isLoading && visible.isEmpty {
                    emptyState
                }
            }
            .stexxBackground()
            .refreshable { await reload() }
            .task(id: query) {
                // Runs on first appearance and whenever a filter changes;
                // skips reloading when popping back from a profile.
                guard query != loadedQuery || profiles.isEmpty else { return }
                await reload()
            }
            .navigationTitle("Nearby")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Wordmark(size: 22, glows: false)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        appState.isPaywallPresented = true
                    } label: {
                        Label("Stexx+", systemImage: "sparkles")
                    }
                    .tint(Theme.steel)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if appState.requirePlus() { isShowingFilters = true }
                    } label: {
                        Label(
                            "Filters",
                            systemImage: hasActiveAdvancedFilters
                                ? "line.3.horizontal.decrease.circle.fill"
                                : "line.3.horizontal.decrease"
                        )
                    }
                    .tint(hasActiveAdvancedFilters ? Theme.ice : Theme.steel)
                }
            }
            .navigationDestination(for: Profile.self) { profile in
                ProfileDetailView(profile: profile)
                    .modifier(NearbyZoomTransition(sourceID: profile.id, namespace: zoomNamespace))
            }
            .navigationDestination(for: ChatRoute.self) { route in
                ChatThreadView(route: route)
            }
            .sheet(isPresented: $isShowingFilters) {
                FilterSheet(query: $advanced)
            }
        }
        // A light tick when a profile opens from the grid.
        .sensoryFeedback(.impact(weight: .light), trigger: path.count) { old, new in
            old == 0 && new == 1
        }
    }

    // MARK: Header

    /// Lowercase heavy title with a mono-caps live count on its baseline.
    private func header(for visible: [Profile]) -> some View {
        let onlineCount = visible.filter(\.isOnline).count

        return HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.m) {
            Text("nearby")
                .stexxTitleStyle()
                .accessibilityLabel(Text("Nearby"))
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 0)

            if !visible.isEmpty {
                HStack(spacing: Theme.Spacing.s) {
                    if onlineCount > 0 {
                        OnlineDot()
                            .accessibilityHidden(true)
                        Text("\(onlineCount) online")
                            .stexxLabelStyle(color: Theme.frost)
                        Text(verbatim: "/")
                            .stexxLabelStyle(color: Theme.slate)
                            .accessibilityHidden(true)
                    }
                    Text("\(visible.count) around")
                        .stexxLabelStyle()
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .accessibilityElement(children: .combine)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var filterBar: some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(QuickFilter.allCases, id: \.self) { filter in
                        GlassChip(filter.title, systemImage: filter.systemImage, isSelected: quickFilter == filter) {
                            withAnimation(Motion.animation(Motion.quick, reduceMotion: reduceMotion)) {
                                quickFilter = filter
                            }
                        }
                    }
                    GlassChip("More filters", isSelected: hasActiveAdvancedFilters, isLocked: !appState.hasPlus) {
                        if appState.requirePlus() { isShowingFilters = true }
                    }
                }
                .padding(.horizontal, Theme.Spacing.screen)
                .padding(.vertical, 2)
            }
        }
        .scrollIndicators(.hidden)
        .sensoryFeedback(.selection, trigger: quickFilter)
    }

    // MARK: Grid

    @ViewBuilder
    private func blockView(_ block: NearbyGridBlock) -> some View {
        switch block.kind {
        case .featured(let heroLeading):
            NearbyFeaturedLayout(spacing: NearbyGridMetrics.spacing, heroLeading: heroLeading) {
                tileLink(block.profiles[0], isFeatured: true)
                tileLink(block.profiles[1])
                tileLink(block.profiles[2])
            }
        case .row:
            HStack(spacing: NearbyGridMetrics.spacing) {
                ForEach(block.profiles) { profile in
                    tileLink(profile)
                        .aspectRatio(NearbyGridMetrics.tileAspect, contentMode: .fit)
                }
                // Keep tile widths constant on a short last row.
                ForEach(0..<(NearbyGridMetrics.columns - block.profiles.count), id: \.self) { _ in
                    Color.clear
                        .aspectRatio(NearbyGridMetrics.tileAspect, contentMode: .fit)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private func tileLink(_ profile: Profile, isFeatured: Bool = false) -> some View {
        NavigationLink(value: profile) {
            ProfileTile(profile: profile, isFeatured: isFeatured)
                .matchedTransitionSource(id: profile.id, in: zoomNamespace)
        }
        .buttonStyle(NearbyTilePressStyle())
    }

    // MARK: States

    @ViewBuilder
    private var emptyState: some View {
        if let errorMessage {
            ContentUnavailableView {
                Label("Couldn't load the grid", systemImage: "wifi.exclamationmark")
            } description: {
                Text(errorMessage)
                    .font(.stexxSub)
                    .foregroundStyle(Theme.steel)
            } actions: {
                Button("Try again") { Task { await reload() } }
                    .stexxSecondaryButton()
            }
        } else {
            ContentUnavailableView {
                Label {
                    Text("Nobody here yet")
                        .stexxTitleStyle(.title)
                } icon: {
                    StexxMark(size: 40, glows: false)
                        .padding(Theme.Spacing.m)
                        .cellCorners()
                        .padding(.bottom, Theme.Spacing.s)
                        .accessibilityHidden(true)
                }
            } description: {
                Text("Try fewer filters, or check back in a bit.")
                    .font(.stexxSub)
                    .foregroundStyle(Theme.steel)
            }
        }
    }

    // MARK: Loading

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let requested = query
            let page = try await api.nearby(requested)
            // A newer reload (filter change) superseded this one.
            guard !Task.isCancelled else { return }
            profiles = page.items
            loadedQuery = requested
            nextCursor = page.nextCursor
            errorMessage = nil
        } catch is CancellationError {
            // A newer reload replaced this one.
        } catch let error as URLError where error.code == .cancelled {
            // Same, from the live HTTP client.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadMore() async {
        guard let cursor = nextCursor, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        var next = query
        next.cursor = cursor
        if let page = try? await api.nearby(next) {
            let known = Set(profiles.map(\.id))
            profiles += page.items.filter { !known.contains($0.id) }
            nextCursor = page.nextCursor
        }
    }
}

// MARK: - Tile

/// A photo tile in the grid: photo, name, mono distance and a static online
/// dot. Featured tiles are the block's hero surface: the cell corners and
/// the violet rim light, nothing else.
struct ProfileTile: View {
    let profile: Profile
    var isFeatured = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous)
    }

    var body: some View {
        Color.clear
            .overlay { ProfilePhotoView(profile: profile) }
            .overlay(alignment: .bottom) { caption }
            .overlay(alignment: .topTrailing) { favoriteMark }
            .clipShape(shape)
            .overlay {
                if isFeatured {
                    shape
                        .strokeBorder(Theme.line, lineWidth: 0.5)
                        .rimLight(shape)
                        .cellCorners(outset: -8)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(shape)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
            .accessibilityAddTraits(.isButton)
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: isFeatured ? 4 : 2) {
            HStack(spacing: 5) {
                if profile.isOnline {
                    OnlineDot()
                }
                Text(isFeatured ? profile.nameAndAge : profile.displayName)
                    .font(.system(isFeatured ? .subheadline : .footnote, weight: .semibold))
                    .foregroundStyle(Theme.frost)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            if let meta = metaText {
                Text(meta)
                    .stexxLabelStyle(.micro, color: Theme.frost.opacity(0.7))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, isFeatured ? 12 : 7)
        .padding(.top, isFeatured ? 40 : 24)
        .padding(.bottom, isFeatured ? 12 : 7)
        .background(Theme.photoScrim)
    }

    /// Mono meta under the name: distance, plus "right now" on featured tiles.
    private var metaText: String? {
        var parts: [String] = []
        if let distance = profile.distanceMeters {
            parts.append(StexxFormat.distance(distance))
        }
        if isFeatured, profile.lookingFor.contains(.rightNow) {
            parts.append(String(localized: "Right now"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var favoriteMark: some View {
        if profile.isFavorite {
            Image(systemName: "star.fill")
                .font(.system(size: isFeatured ? 11 : 9, weight: .semibold))
                .foregroundStyle(Theme.frost)
                .shadow(color: .black.opacity(0.45), radius: 2)
                .padding(isFeatured ? 12 : 6)
        }
    }

    private var accessibilityText: Text {
        var parts = [profile.nameAndAge]
        if profile.isOnline { parts.append(String(localized: "online")) }
        if let distance = profile.distanceMeters { parts.append(StexxFormat.distance(distance)) }
        if profile.isFavorite { parts.append(String(localized: "favorite")) }
        return Text(parts.joined(separator: ", "))
    }
}

// MARK: - Grid model

private enum NearbyGridMetrics {
    static let columns = 3
    /// 2pt gutters on ink, so the gaps read as grid lines.
    static let spacing: CGFloat = Theme.Spacing.gridGutter
    /// Width / height of a small tile (3:4).
    static let tileAspect: CGFloat = 0.75
    /// Dense rows between featured blocks.
    static let rowsPerCycle = 3
}

/// One horizontal band of the grid.
private struct NearbyGridBlock: Identifiable {
    enum Kind {
        /// `profiles[0]` is the big tile; `[1]` and `[2]` stack beside it.
        case featured(heroLeading: Bool)
        case row
    }

    let id: String
    let kind: Kind
    let profiles: [Profile]

    /// Splits the (already ordered) profiles into featured blocks and rows.
    static func make(from profiles: [Profile]) -> [NearbyGridBlock] {
        var blocks: [NearbyGridBlock] = []
        var index = 0
        var cycle = 0
        let columns = NearbyGridMetrics.columns

        while index < profiles.count {
            if profiles.count - index >= 3 {
                let group = Array(profiles[index ..< index + 3])
                let heroIndex = group.indices.max { isLessActive(group[$0], group[$1]) } ?? 0
                var ordered = group
                let hero = ordered.remove(at: heroIndex)
                ordered.insert(hero, at: 0)
                blocks.append(NearbyGridBlock(
                    id: "featured-\(group[0].id)",
                    kind: .featured(heroLeading: cycle.isMultiple(of: 2)),
                    profiles: ordered
                ))
                index += 3
            }
            for _ in 0 ..< NearbyGridMetrics.rowsPerCycle where index < profiles.count {
                let end = min(index + columns, profiles.count)
                blocks.append(NearbyGridBlock(
                    id: "row-\(profiles[index].id)",
                    kind: .row,
                    profiles: Array(profiles[index ..< end])
                ))
                index = end
            }
            cycle += 1
        }
        return blocks
    }

    /// A profile with a photo beats a placeholder (the big tile should show
    /// a face); then online beats offline; then the more recent activity
    /// wins. Ties keep the server order (closest first).
    private static func isLessActive(_ a: Profile, _ b: Profile) -> Bool {
        let aHasPhoto = a.primaryPhotoURL != nil
        let bHasPhoto = b.primaryPhotoURL != nil
        if aHasPhoto != bHasPhoto { return !aHasPhoto }
        if a.isOnline != b.isOnline { return !a.isOnline }
        return (a.lastActiveAt ?? .distantPast) < (b.lastActiveAt ?? .distantPast)
    }
}

/// Places a 2x2 hero tile and two stacked small tiles in a three-column
/// band whose small tiles match the dense rows exactly.
private struct NearbyFeaturedLayout: Layout {
    var spacing: CGFloat
    var heroLeading: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 360
        let small = smallSize(forWidth: width)
        return CGSize(width: width, height: small.height * 2 + spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let small = smallSize(forWidth: bounds.width)
        let hero = CGSize(width: small.width * 2 + spacing, height: small.height * 2 + spacing)

        let heroX = heroLeading ? bounds.minX : bounds.maxX - hero.width
        let sideX = heroLeading ? bounds.maxX - small.width : bounds.minX

        for (index, subview) in subviews.enumerated() {
            if index == 0 {
                subview.place(
                    at: CGPoint(x: heroX, y: bounds.minY),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(hero)
                )
            } else {
                let row = CGFloat(min(index - 1, 1))
                subview.place(
                    at: CGPoint(x: sideX, y: bounds.minY + row * (small.height + spacing)),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(small)
                )
            }
        }
    }

    private func smallSize(forWidth width: CGFloat) -> CGSize {
        let columns = CGFloat(NearbyGridMetrics.columns)
        let tileWidth = max(0, (width - spacing * (columns - 1)) / columns)
        return CGSize(width: tileWidth, height: tileWidth / NearbyGridMetrics.tileAspect)
    }
}

// MARK: - Motion helpers

/// Tiles sink slightly when pressed (no bounce); just dim under Reduce Motion.
private struct NearbyTilePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        NearbyTilePressBody(configuration: configuration)
    }
}

private struct NearbyTilePressBody: View {
    let configuration: ButtonStyleConfiguration

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(
                reduceMotion ? Motion.fade : (configuration.isPressed ? Motion.press : Motion.quick),
                value: configuration.isPressed
            )
    }
}

/// The profile zooms out of its tile; plain push under Reduce Motion.
private struct NearbyZoomTransition: ViewModifier {
    let sourceID: Profile.ID
    let namespace: Namespace.ID

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.navigationTransition(.zoom(sourceID: sourceID, in: namespace))
        }
    }
}

#Preview("Nearby") {
    NearbyView()
        .previewEnvironment()
}

#Preview("Tiles") {
    HStack(alignment: .top, spacing: 2) {
        ProfileTile(profile: MockData.profiles[0], isFeatured: true)
            .frame(width: 236, height: 306)
        ProfileTile(profile: MockData.profiles[1])
            .frame(width: 115, height: 148)
    }
    .padding()
    .background(Theme.ink)
    .preferredColorScheme(.dark)
}
