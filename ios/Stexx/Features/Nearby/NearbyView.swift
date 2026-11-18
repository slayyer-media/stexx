import SwiftUI

/// The grid of people nearby, in the server's closest-first order.
///
/// A uniform grid: three equal columns of 3:4 tiles on 2pt gutters. Every
/// profile gets the same tile; nobody is featured or given extra weight.
/// The tab header's compact row holds the quick filters and the filters
/// button, under the centered xx logo row.
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
        let lastID = visible.last?.id

        NavigationStack(path: $path) {
            ScrollView {
                LazyVGrid(columns: NearbyGridMetrics.gridColumns, spacing: NearbyGridMetrics.spacing) {
                    ForEach(visible) { profile in
                        tileLink(profile)
                            .aspectRatio(NearbyGridMetrics.tileAspect, contentMode: .fit)
                            .onAppear {
                                if profile.id == lastID { Task { await loadMore() } }
                            }
                    }
                }
                .padding(.horizontal, NearbyGridMetrics.spacing)
                .padding(.top, NearbyGridMetrics.spacing)
                .padding(.bottom, Theme.Spacing.xl)

                if isLoading && profiles.isEmpty {
                    ProgressView()
                        .controlSize(.regular)
                        .tint(Theme.steel)
                        .padding(.top, 80)
                }
            }
            .collapsesTabHeaderLogo()
            .overlay {
                if !isLoading && visible.isEmpty {
                    emptyState
                }
            }
            .tabHeader {
                filterBar(onlineCount: visible.filter(\.isOnline).count)
            } trailing: {
                filtersButton
            }
            .sensoryFeedback(.selection, trigger: quickFilter)
            .stexxBackground()
            .refreshable { await reload() }
            .task(id: query) {
                // Runs on first appearance and whenever a filter changes;
                // skips reloading when popping back from a profile.
                guard query != loadedQuery || profiles.isEmpty else { return }
                await reload()
            }
            .navigationTitle("Nearby")
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

    /// Quick filters inline in the header row. The Online chip carries the
    /// live online count ("ONLINE 18") when there is one.
    private func filterBar(onlineCount: Int) -> some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(QuickFilter.allCases, id: \.self) { filter in
                        GlassChip(chipTitle(filter, onlineCount: onlineCount), systemImage: filter.systemImage, isSelected: quickFilter == filter) {
                            selectQuickFilter(filter)
                        }
                    }
                    GlassChip("More filters", isSelected: hasActiveAdvancedFilters, isLocked: !appState.hasPlus) {
                        openAdvancedFilters()
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .scrollIndicators(.hidden)
    }

    private func selectQuickFilter(_ filter: QuickFilter) {
        withAnimation(Motion.animation(Motion.quick, reduceMotion: reduceMotion)) {
            quickFilter = filter
        }
    }

    private func openAdvancedFilters() {
        if appState.requirePlus() { isShowingFilters = true }
    }

    private func chipTitle(_ filter: QuickFilter, onlineCount: Int) -> Text {
        if filter == .online, onlineCount > 0 {
            return Text("Online \(onlineCount)").monospacedDigit()
        }
        return Text(filter.title)
    }

    private var filtersButton: some View {
        Button {
            openAdvancedFilters()
        } label: {
            TabHeaderIconLabel(
                title: "Filters",
                systemImage: "line.3.horizontal.decrease",
                tint: hasActiveAdvancedFilters ? Theme.ice : Theme.steel
            )
        }
        .buttonStyle(.pressable)
        .padding(.trailing, -Theme.Spacing.s)
        .accessibilityValue(hasActiveAdvancedFilters ? Text("On") : Text(verbatim: ""))
    }

    // MARK: Grid

    private func tileLink(_ profile: Profile) -> some View {
        NavigationLink(value: profile) {
            ProfileTile(profile: profile)
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

/// A photo tile in the grid: photo, name, mono distance, a static online
/// dot and the favourite star. Every tile is identical: radius 4, no rim
/// light, no cell corners.
struct ProfileTile: View {
    let profile: Profile

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous)
    }

    var body: some View {
        Color.clear
            .overlay { ProfilePhotoView(profile: profile) }
            .overlay(alignment: .bottom) { caption }
            .overlay(alignment: .topTrailing) { favoriteMark }
            .clipShape(shape)
            .contentShape(shape)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
            .accessibilityAddTraits(.isButton)
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                if profile.isOnline {
                    OnlineDot()
                }
                Text(profile.displayName)
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(Theme.frost)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            if let distance = profile.distanceMeters {
                Text(StexxFormat.distance(distance))
                    .stexxLabelStyle(.micro, color: Theme.frost.opacity(0.7))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 7)
        .padding(.top, 24)
        .padding(.bottom, 7)
        .background(Theme.photoScrim)
    }

    @ViewBuilder
    private var favoriteMark: some View {
        if profile.isFavorite {
            Image(systemName: "star.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.frost)
                .shadow(color: .black.opacity(0.45), radius: 2)
                .padding(6)
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

// MARK: - Grid metrics

private enum NearbyGridMetrics {
    static let columns = 3
    /// 2pt gutters on ink, so the gaps read as grid lines.
    static let spacing: CGFloat = Theme.Spacing.gridGutter
    /// Width / height of a tile (3:4).
    static let tileAspect: CGFloat = 0.75
    static let gridColumns = Array(
        repeating: GridItem(.flexible(), spacing: spacing),
        count: columns
    )
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
        ProfileTile(profile: MockData.profiles[0])
            .frame(width: 115, height: 153)
        ProfileTile(profile: MockData.profiles[1])
            .frame(width: 115, height: 153)
    }
    .padding()
    .background(Theme.ink)
    .preferredColorScheme(.dark)
}
