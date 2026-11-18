import SwiftUI

/// The grid of people nearby, closest first.
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

    @State private var profiles: [Profile] = []
    @State private var nextCursor: String?
    @State private var quickFilter: QuickFilter = .all
    /// Stexx+ filters edited in `FilterSheet`.
    @State private var advanced = NearbyQuery()
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isShowingFilters = false
    @State private var loadedQuery: NearbyQuery?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 3)

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
        NavigationStack {
            ScrollView {
                filterBar
                    .padding(.bottom, Theme.Spacing.s)

                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(visibleProfiles) { profile in
                        NavigationLink(value: profile) {
                            ProfileTile(profile: profile)
                        }
                        .buttonStyle(.plain)
                        .onAppear {
                            if profile.id == visibleProfiles.last?.id { Task { await loadMore() } }
                        }
                    }
                }
                .padding(.horizontal, 4)

                if isLoading && profiles.isEmpty {
                    ProgressView()
                        .padding(.top, 80)
                }
            }
            .overlay {
                if !isLoading && visibleProfiles.isEmpty {
                    emptyState
                }
            }
            .stexxBackground(intensity: 0.8)
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
                }
            }
            .navigationDestination(for: Profile.self) { profile in
                ProfileDetailView(profile: profile)
            }
            .navigationDestination(for: ChatRoute.self) { route in
                ChatThreadView(route: route)
            }
            .sheet(isPresented: $isShowingFilters) {
                FilterSheet(query: $advanced)
            }
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(QuickFilter.allCases, id: \.self) { filter in
                        GlassChip(filter.title, systemImage: filter.systemImage, isSelected: quickFilter == filter) {
                            quickFilter = filter
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
    }

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
            ContentUnavailableView(
                "Nobody here yet",
                systemImage: "sparkles",
                description: Text("Try fewer filters, or check back in a bit.")
            )
        }
    }

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

/// A photo tile in the grid: photo, name, distance and online status.
struct ProfileTile: View {
    let profile: Profile

    var body: some View {
        Color.clear
            .aspectRatio(0.78, contentMode: .fit)
            .overlay { ProfilePhotoView(profile: profile) }
            .overlay(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        if profile.isOnline {
                            OnlineDot(size: 8)
                        }
                        Text(profile.displayName)
                            .font(.footnote.weight(.semibold))
                            .lineLimit(1)
                    }
                    if let distance = profile.distanceMeters {
                        Text(StexxFormat.distance(distance))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.top, 24)
                .padding(.bottom, 7)
                .background(Theme.photoScrim)
            }
            .overlay(alignment: .topTrailing) {
                if profile.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(Theme.warning)
                        .padding(6)
                        .shadow(radius: 3)
                }
            }
            .clipShape(.rect(cornerRadius: 10))
            .contentShape(.rect(cornerRadius: 10))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
            .accessibilityAddTraits(.isButton)
    }

    private var accessibilityText: Text {
        var parts = [profile.nameAndAge]
        if profile.isOnline { parts.append(String(localized: "online")) }
        if let distance = profile.distanceMeters { parts.append(StexxFormat.distance(distance)) }
        return Text(parts.joined(separator: ", "))
    }
}

#Preview("Nearby") {
    NearbyView()
        .previewEnvironment()
}

#Preview("Tile") {
    ProfileTile(profile: MockData.profiles[0])
        .frame(width: 130)
        .padding()
        .background(GlowBackground())
        .preferredColorScheme(.dark)
}
