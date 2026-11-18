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
    /// Scroll position for the glow, kept out of this view's body so
    /// scrolling only redraws the background, not the grid.
    @State private var scrollGlow = NearbyScrollGlow()

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
                    .padding(.horizontal, Theme.Spacing.l)
                    .padding(.top, Theme.Spacing.s)

                filterBar
                    .padding(.bottom, Theme.Spacing.m)

                LazyVStack(spacing: NearbyGridMetrics.spacing) {
                    ForEach(blocks) { block in
                        blockView(block)
                            .onAppear {
                                if block.id == lastBlockID { Task { await loadMore() } }
                            }
                    }
                }
                .padding(.horizontal, NearbyGridMetrics.spacing + 2)
                .padding(.bottom, Theme.Spacing.l)

                if isLoading && profiles.isEmpty {
                    ProgressView()
                        .controlSize(.large)
                        .tint(Theme.violetBright)
                        .padding(.top, 80)
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, newValue in
                guard !reduceMotion else { return }
                scrollGlow.update(newValue)
            }
            .overlay {
                if !isLoading && visible.isEmpty {
                    emptyState
                }
            }
            .scrollContentBackground(.hidden)
            .background { NearbyGlowBackground(glow: scrollGlow, intensity: 0.85) }
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
                    Wordmark(size: 24)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        appState.isPaywallPresented = true
                    } label: {
                        Label("Stexx+", systemImage: "sparkles")
                    }
                    .tint(Theme.violetBright)
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
                    .tint(hasActiveAdvancedFilters ? Theme.violetBright : nil)
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

    private func header(for visible: [Profile]) -> some View {
        let onlineCount = visible.filter(\.isOnline).count

        return VStack(alignment: .leading, spacing: 6) {
            Text("Nearby")
                .font(.stexxHero)
                .tracking(Theme.Tracking.display)
                .foregroundStyle(Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)

            if !visible.isEmpty {
                HStack(spacing: 8) {
                    if onlineCount > 0 {
                        OnlineGlow(size: 7)
                            .accessibilityHidden(true)
                        Text("\(onlineCount) online now")
                            .foregroundStyle(Theme.textPrimary)
                        Text(verbatim: "·")
                            .accessibilityHidden(true)
                    }
                    Text("\(visible.count) around you")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
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
                            withAnimation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion)) {
                                quickFilter = filter
                            }
                        }
                    }
                    GlassChip("More filters", isSelected: hasActiveAdvancedFilters, isLocked: !appState.hasPlus) {
                        if appState.requirePlus() { isShowingFilters = true }
                    }
                }
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.vertical, 4)
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
            } actions: {
                Button("Try again") { Task { await reload() } }
                    .stexxSecondaryButton()
            }
        } else {
            ContentUnavailableView {
                Label {
                    Text("Nobody here yet")
                        .font(.stexxName)
                        .tracking(Theme.Tracking.tight)
                } icon: {
                    StexxMark(size: 44)
                        .accessibilityHidden(true)
                }
            } description: {
                Text("Try fewer filters, or check back in a bit.")
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

/// A photo tile in the grid: photo, name, distance and online status.
/// Featured tiles are larger, glow more, and show a glass distance chip and
/// the headline.
struct ProfileTile: View {
    let profile: Profile
    var isFeatured = false

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var cornerRadius: CGFloat {
        isFeatured ? Theme.Radius.card - 2 : 14
    }

    var body: some View {
        Color.clear
            .overlay { ProfilePhotoView(profile: profile) }
            .overlay(alignment: .bottom) { caption }
            .overlay(alignment: .top) { topBar }
            .glowFrame(cornerRadius: cornerRadius, glow: isFeatured ? 1.25 : 0.35)
            .contentShape(.rect(cornerRadius: cornerRadius))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
            .accessibilityAddTraits(.isButton)
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: isFeatured ? 4 : 1) {
            if isFeatured, profile.lookingFor.contains(.rightNow) {
                XXBadge("Right now")
                    .padding(.bottom, 2)
            }
            HStack(spacing: isFeatured ? 7 : 5) {
                if profile.isOnline {
                    OnlineGlow(size: isFeatured ? 9 : 7)
                }
                Text(isFeatured ? profile.nameAndAge : profile.displayName)
                    .font(isFeatured ? .stexxName : .stexxNameSmall)
                    .tracking(isFeatured ? Theme.Tracking.display : Theme.Tracking.tight)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            if isFeatured {
                if let headline = profile.headline, !headline.isEmpty {
                    Text(headline)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(1)
                }
            } else if let distance = profile.distanceMeters {
                Text(StexxFormat.distance(distance))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, isFeatured ? 14 : 8)
        .padding(.top, isFeatured ? 48 : 26)
        .padding(.bottom, isFeatured ? 14 : 7)
        .background(Theme.photoScrim)
    }

    private var topBar: some View {
        HStack(alignment: .top) {
            if isFeatured, let distance = profile.distanceMeters {
                distanceChip(StexxFormat.distance(distance))
            }
            Spacer(minLength: 0)
            if profile.isFavorite {
                Image(systemName: "star.fill")
                    .font(isFeatured ? .footnote : .caption2)
                    .foregroundStyle(Theme.warning)
                    .shadow(color: .black.opacity(0.5), radius: 3)
                    .padding(isFeatured ? 4 : 0)
            }
        }
        .padding(isFeatured ? 10 : 6)
    }

    @ViewBuilder
    private func distanceChip(_ text: String) -> some View {
        let label = Label(text, systemImage: "location.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)

        // Glass only on featured tiles (a few per screen), never per small tile.
        if reduceTransparency {
            label.background(Color.black.opacity(0.65), in: .capsule)
        } else {
            label.glassEffect(.regular.tint(Theme.violet.opacity(0.18)), in: .capsule)
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
    static let spacing: CGFloat = 6
    /// Width / height of a small tile.
    static let tileAspect: CGFloat = 0.78
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

    /// Online beats offline; then the more recent activity wins. Ties keep
    /// the server order (closest first).
    private static func isLessActive(_ a: Profile, _ b: Profile) -> Bool {
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

/// Tiles sink slightly with a spring when pressed; just dim under Reduce Motion.
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
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.95 : 1)
            .brightness(configuration.isPressed ? -0.08 : 0)
            .animation(
                reduceMotion ? nil : (configuration.isPressed ? Motion.snappy : Motion.cardSpring),
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

// MARK: - Scroll-reactive glow

/// Holds the grid's scroll offset. Only `NearbyGlowBackground` reads it, so
/// scrolling invalidates the background and nothing else.
@MainActor
@Observable
private final class NearbyScrollGlow {
    private(set) var offset: CGFloat = 0

    func update(_ rawOffset: CGFloat) {
        // Whole points, clamped: the glow only drifts near the top, so deep
        // scrolling stops causing redraws.
        let value = min(max(rawOffset, 0), 1200).rounded()
        if value != offset { offset = value }
    }
}

private struct NearbyGlowBackground: View {
    let glow: NearbyScrollGlow
    let intensity: Double

    var body: some View {
        GlowBackground(intensity: intensity, scrollOffset: glow.offset)
    }
}

#Preview("Nearby") {
    NearbyView()
        .previewEnvironment()
}

#Preview("Tiles") {
    HStack(alignment: .top, spacing: 8) {
        ProfileTile(profile: MockData.profiles[0], isFeatured: true)
            .frame(width: 236, height: 306)
        ProfileTile(profile: MockData.profiles[1])
            .frame(width: 115, height: 148)
    }
    .padding()
    .background(GlowBackground())
    .preferredColorScheme(.dark)
}
