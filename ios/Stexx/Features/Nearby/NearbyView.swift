import SwiftUI

/// The grid of people nearby, in the server's closest-first order.
///
/// A uniform grid: three equal columns of 3:4 tiles on 2pt gutters. Every
/// profile gets the same tile; nobody is featured or given extra weight.
/// The tab header's compact row holds the quick filters and the filters
/// button, under the centered xx logo row.
///
/// When there's nothing to show, `NearbyContent.resolve` picks the state:
/// first run (no location uploaded yet), location off, nobody nearby (with
/// a filter reset), or a load error with Retry. A failed page shows a Retry
/// cell at the end of the grid.
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

        /// What the chip does, for VoiceOver.
        var accessibilityHint: LocalizedStringKey {
            switch self {
            case .all: "Shows everyone nearby"
            case .online: "Shows only people online now"
            case .rightNow: "Shows only people looking right now"
            case .favorites: "Shows only your favorites"
            }
        }
    }

    @Environment(AppState.self) private var appState
    @Environment(AppServices.self) private var services
    @Environment(\.apiClient) private var api
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var feed = NearbyFeedModel()
    @State private var quickFilter: QuickFilter
    /// Stexx+ filters edited in `FilterSheet`.
    @State private var advanced = NearbyQuery()
    @State private var isShowingFilters = false
    @State private var path = NavigationPath()
    @State private var isTurningOffTravel = false
    @State private var travelError: String?
    /// The first location upload is taking long: stop waiting for it and
    /// show what the grid has.
    @State private var locatingTimedOut = false

    @Namespace private var zoomNamespace

    init() {
        #if DEBUG
        _quickFilter = State(initialValue: NearbyDebugScenario.current?.startsWithOnlineFilter == true ? .online : .all)
        #else
        _quickFilter = State(initialValue: .all)
        #endif
    }

    private var visibleProfiles: [Profile] {
        feed.profiles.filter { !appState.blockedIDs.contains($0.id) }
    }

    private var hasActiveAdvancedFilters: Bool {
        appState.hasPlus && advanced.usesAdvancedFilters
    }

    /// Any filter that can hide people: a quick filter other than All, or
    /// Stexx+ filters.
    private var hasActiveFilters: Bool {
        quickFilter != .all || hasActiveAdvancedFilters
    }

    private var loadKey: NearbyLoadKey {
        NearbyLoadKey(query: query, travelRevision: appState.travelRevision, isTravelActive: appState.isTravelActive)
    }

    private var query: NearbyQuery {
        var query = appState.hasPlus ? advanced : NearbyQuery()
        query.cursor = nil
        query.onlineOnly = quickFilter == .online
        query.favoritesOnly = quickFilter == .favorites
        query.lookingFor = quickFilter == .rightNow ? [.rightNow] : []
        return query
    }

    /// The phone's location as far as the grid cares (never a coordinate).
    private var locationState: NearbyLocationState {
        #if DEBUG
        if let scenario = NearbyDebugScenario.current { return scenario.location }
        #endif
        let location = services.location
        return NearbyLocationState(status: location?.status, hasUploaded: location?.lastUploadedCell != nil)
    }

    private var fetch: NearbyFetch {
        let api = api
        let live: NearbyFetch = { query in try await api.nearby(query) }
        #if DEBUG
        if let scenario = NearbyDebugScenario.current { return scenario.fetch(live) }
        #endif
        return live
    }

    var body: some View {
        let visible = visibleProfiles
        let lastID = visible.last?.id
        let location = locationState
        let content = NearbyContent.resolve(
            hasProfiles: !visible.isEmpty,
            isLoading: feed.isPending,
            failure: feed.failure,
            location: location,
            locatingTimedOut: locatingTimedOut,
            isTravelActive: appState.isTravelActive,
            filtersActive: hasActiveFilters
        )

        NavigationStack(path: $path) {
            ScrollView {
                if appState.isTravelActive || appState.isTravelPaused {
                    // Paused: Stexx+ lapsed and the server shows you near
                    // home again; say so here, where it matters most.
                    TravelBanner(
                        placeName: appState.travel?.name,
                        isPaused: appState.isTravelPaused,
                        isBusy: isTurningOffTravel,
                        onOpen: {
                            if appState.requirePlus() { path.append(TravelRoute()) }
                        },
                        onTurnOff: { Task { await turnOffTravel() } }
                    )
                    .padding(.horizontal, NearbyGridMetrics.spacing)
                    .padding(.top, NearbyGridMetrics.spacing)
                    .transition(.opacity)
                }
                if content == .grid {
                    notices(location: location)
                }
                LazyVGrid(columns: NearbyGridMetrics.gridColumns, spacing: NearbyGridMetrics.spacing) {
                    Section {
                        ForEach(visible) { profile in
                            tileLink(profile)
                                .aspectRatio(NearbyGridMetrics.tileAspect, contentMode: .fit)
                                .onAppear {
                                    if profile.id == lastID { Task { await feed.loadMore(using: fetch) } }
                                }
                        }
                    } footer: {
                        if content == .grid, feed.showsFooter {
                            NearbyPageFooter(state: feed.nextPage) {
                                Task { await feed.retryNextPage(using: fetch) }
                            }
                            .onAppear { Task { await feed.loadMore(using: fetch) } }
                        }
                    }
                }
                .padding(.horizontal, NearbyGridMetrics.spacing)
                .padding(.top, NearbyGridMetrics.spacing)
                .padding(.bottom, Theme.Spacing.xl)
            }
            .collapsesTabHeaderLogo()
            .overlay {
                if content != .grid {
                    NearbyStateView(
                        content: content,
                        onRetry: { Task { await feed.reload(loadKey, using: fetch) } },
                        onClearFilters: clearFilters,
                        onTravelMode: openTravelMode
                    )
                    .transition(.opacity)
                }
            }
            .animation(Motion.animation(Motion.standard, reduceMotion: reduceMotion), value: content)
            .tabHeader {
                filterBar(onlineCount: visible.filter(\.isOnline).count)
            } trailing: {
                filtersButton
            }
            .sensoryFeedback(.selection, trigger: quickFilter)
            .stexxBackground()
            .refreshable { await feed.reload(loadKey, using: fetch) }
            .task(id: loadKey) {
                // Runs on first appearance, whenever a filter or travel mode
                // changes; skips reloading when popping back from a profile.
                guard feed.needsReload(for: loadKey) else { return }
                await feed.reload(loadKey, using: fetch)
            }
            // First run: the grid usually loads before the first location
            // upload, so load it again once the phone is placed (also after
            // location is turned back on in Settings).
            .onChange(of: location) { old, new in
                guard new == .located, old != .located else { return }
                Task { await feed.reload(loadKey, using: fetch) }
            }
            .task(id: location == .locating) {
                locatingTimedOut = false
                guard location == .locating else { return }
                #if DEBUG
                if NearbyDebugScenario.current == .firstRun { return }
                #endif
                try? await Task.sleep(for: NearbyContent.locatingTimeout)
                if !Task.isCancelled { locatingTimedOut = true }
            }
            .onChange(of: feed.nextPage) { _, new in
                if case .failed = new {
                    AccessibilityNotification.Announcement(String(localized: "Couldn't load more people")).post()
                }
            }
            .animation(Motion.animation(Motion.standard, reduceMotion: reduceMotion), value: appState.travel != nil)
            .alert(
                "Couldn't turn off travel mode",
                isPresented: Binding(get: { travelError != nil }, set: { if !$0 { travelError = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(travelError ?? "")
            }
            .navigationTitle("Nearby")
            .navigationDestination(for: Profile.self) { profile in
                ProfileDetailView(profile: profile)
                    .modifier(NearbyZoomTransition(sourceID: profile.id, namespace: zoomNamespace))
            }
            .navigationDestination(for: ChatRoute.self) { route in
                ChatThreadView(route: route)
            }
            .navigationDestination(for: TravelRoute.self) { _ in
                TravelModeView()
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
    /// online count of the tiles loaded so far ("ONLINE 18") when there is one.
    private func filterBar(onlineCount: Int) -> some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(QuickFilter.allCases, id: \.self) { filter in
                        GlassChip(chipTitle(filter, onlineCount: onlineCount), systemImage: filter.systemImage, isSelected: quickFilter == filter) {
                            selectQuickFilter(filter)
                        }
                        .accessibilityLabel(Text(filter.title))
                        .accessibilityValue(chipAccessibilityValue(filter, onlineCount: onlineCount))
                        .accessibilityHint(Text(filter.accessibilityHint))
                    }
                    GlassChip("More filters", isSelected: hasActiveAdvancedFilters, isLocked: !appState.hasPlus) {
                        openAdvancedFilters()
                    }
                    .accessibilityValue(hasActiveAdvancedFilters ? Text("On") : Text(verbatim: ""))
                    .accessibilityHint(appState.hasPlus ? Text("Age, distance, position and tags") : Text("Stexx+. Opens the Stexx+ offer"))
                }
                .padding(.vertical, 2)
            }
        }
        .scrollIndicators(.hidden)
        // Chips stay one row; very large sizes would push the grid away.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
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

    /// The Online count is only for the tiles loaded so far, so VoiceOver
    /// says so rather than reading it as everyone online.
    private func chipAccessibilityValue(_ filter: QuickFilter, onlineCount: Int) -> Text {
        if filter == .online, onlineCount > 0 {
            return Text("\(onlineCount) in the grid")
        }
        return Text(verbatim: "")
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
        .accessibilityHint(appState.hasPlus ? Text("Age, distance, position and tags") : Text("Stexx+. Opens the Stexx+ offer"))
    }

    // MARK: Grid

    private func tileLink(_ profile: Profile) -> some View {
        NavigationLink(value: profile) {
            ProfileTile(profile: profile)
                .matchedTransitionSource(id: profile.id, in: zoomNamespace)
        }
        .buttonStyle(NearbyTilePressStyle())
    }

    /// Slim notices above a grid that does have tiles.
    @ViewBuilder
    private func notices(location: NearbyLocationState) -> some View {
        VStack(spacing: NearbyGridMetrics.spacing) {
            if let refreshFailure = feed.refreshFailure {
                NearbyNotice(
                    systemImage: "wifi.exclamationmark",
                    text: Text("Couldn't refresh. \(refreshFailure)"),
                    actionTitle: "Retry",
                    action: { Task { await feed.reload(loadKey, using: fetch) } },
                    onDismiss: { feed.dismissRefreshFailure() }
                )
            }
            // Denied after an earlier upload: the server still places you
            // where you last were. Travel mode places you itself.
            if location.isOff, !appState.isTravelActive {
                NearbyNotice(
                    systemImage: "location.slash",
                    text: Text("Location is off. You're seeing people near your last known area."),
                    actionTitle: location == .denied ? "Settings" : nil,
                    action: NearbyStateView.openSettings
                )
            }
        }
        .padding(.horizontal, NearbyGridMetrics.spacing)
        .padding(.top, NearbyGridMetrics.spacing)
    }

    // MARK: Actions

    private func clearFilters() {
        withAnimation(Motion.animation(Motion.quick, reduceMotion: reduceMotion)) {
            quickFilter = .all
            advanced = NearbyQuery()
        }
    }

    /// Travel mode works without device location (Stexx+; the paywall
    /// otherwise).
    private func openTravelMode() {
        if appState.requirePlus() { path.append(TravelRoute()) }
    }

    private func turnOffTravel() async {
        isTurningOffTravel = true
        defer { isTurningOffTravel = false }
        let model = TravelModeModel(appState: appState, api: api)
        if await !model.turnOff() { travelError = model.errorMessage }
    }
}

// MARK: - Tile

/// A photo tile in the grid: photo, name, mono distance, a static online
/// dot and the favourite star. Every tile is identical: radius 4, no rim
/// light, no cell corners.
///
/// Text scales with Dynamic Type up to XXXL; past that the tile (a fixed
/// 3:4 cell a third of the screen wide) would be all caption, and VoiceOver
/// reads the whole label anyway.
struct ProfileTile: View {
    let profile: Profile

    @ScaledMetric(relativeTo: .caption2) private var starSize: CGFloat = 9

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous)
    }

    var body: some View {
        Color.clear
            .overlay { ProfilePhotoView(profile: profile) }
            .overlay(alignment: .bottom) { caption }
            .overlay(alignment: .topTrailing) { favoriteMark }
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .clipShape(shape)
            .contentShape(shape)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
            .accessibilityHint("Opens the profile")
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
                .font(.system(size: starSize, weight: .semibold))
                .foregroundStyle(Theme.frost)
                .shadow(color: .black.opacity(0.45), radius: 2)
                .padding(6)
        }
    }

    private var accessibilityText: Text {
        Text(Self.accessibilityLabel(for: profile))
    }

    /// "Eigenbro, 29, online, 200 m away, favorite": name, age, online, the
    /// server's distance bucket and the star, in the order they're seen.
    static func accessibilityLabel(for profile: Profile, locale: Locale = .current) -> String {
        var parts = [profile.nameAndAge]
        if profile.isOnline { parts.append(String(localized: "online")) }
        if let distance = profile.distanceMeters {
            let formatted = StexxFormat.distance(distance, locale: locale)
            parts.append(String(localized: "\(formatted) away"))
        }
        if profile.isFavorite { parts.append(String(localized: "favorite")) }
        return parts.joined(separator: ", ")
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
