import SwiftUI

/// Stexx+: who viewed your profile in the last 7 days (`GET /me/viewers`).
/// Minimal integration view; a 402 from the server opens the paywall via
/// the API client hooks.
struct ViewersView: View {
    @Environment(\.apiClient) private var api
    @Environment(AppState.self) private var appState

    @State private var viewers: [Profile] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        List(viewers.filter { !appState.blockedIDs.contains($0.id) }) { profile in
            NavigationLink(value: profile) {
                HStack(spacing: Theme.Spacing.m) {
                    AvatarView(profile: profile, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.nameAndAge)
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                        if let distance = profile.distanceMeters {
                            Text(StexxFormat.distance(distance))
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .overlay {
            if isLoading {
                ProgressView()
            } else if let errorMessage {
                ContentUnavailableView("Couldn't load viewers", systemImage: "eyes", description: Text(errorMessage))
            } else if viewers.isEmpty {
                ContentUnavailableView("No views yet", systemImage: "eyes", description: Text("People who view your profile show up here for 7 days."))
            }
        }
        .stexxBackground(intensity: 0.5)
        .navigationTitle("Who viewed you")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: Profile.self) { profile in
            ProfileDetailView(profile: profile)
        }
        .navigationDestination(for: ChatRoute.self) { route in
            ChatThreadView(route: route)
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        defer { isLoading = false }
        do {
            viewers = try await api.viewers()
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    NavigationStack {
        ViewersView()
    }
    .previewEnvironment(plus: true)
}
