import SwiftUI

/// Stexx+: who viewed your profile in the last 7 days (`GET /me/viewers`).
/// A 402 from the server opens the paywall via the API client hooks.
struct ViewersView: View {
    @Environment(\.apiClient) private var api
    @Environment(AppState.self) private var appState

    @State private var viewers: [Profile] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    @Namespace private var zoomNamespace

    private var visibleViewers: [Profile] {
        viewers.filter { !appState.blockedIDs.contains($0.id) }
    }

    var body: some View {
        let visible = visibleViewers

        List {
            if !visible.isEmpty {
                summary(count: visible.count)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(visible) { profile in
                NavigationLink(value: profile) {
                    ViewerRow(profile: profile, zoomNamespace: zoomNamespace)
                }
                .listRowBackground(Color.clear)
                .listRowSeparatorTint(Theme.hairline)
            }
        }
        .listStyle(.plain)
        .overlay {
            if isLoading {
                ProgressView()
                    .controlSize(.large)
                    .tint(Theme.violetBright)
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
                .modifier(ViewersZoomTransition(sourceID: profile.id, namespace: zoomNamespace))
        }
        .navigationDestination(for: ChatRoute.self) { route in
            ChatThreadView(route: route)
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private func summary(count: Int) -> some View {
        HStack(spacing: Theme.Spacing.s) {
            XXBadge(verbatim: "\(count)")
                .accessibilityHidden(true)
            Text("\(count) people in the last 7 days")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
        }
        .accessibilityElement(children: .combine)
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

/// One viewer: glowing avatar, heavy name, last seen and distance.
private struct ViewerRow: View {
    let profile: Profile
    let zoomNamespace: Namespace.ID

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            AvatarView(profile: profile, size: 52, showsOnline: false)
                .glowFrame(cornerRadius: 26, glow: 0.6)
                .overlay(alignment: .bottomTrailing) {
                    if profile.isOnline {
                        OnlineGlow(size: 11)
                            .padding(2)
                    }
                }
                .matchedTransitionSource(id: profile.id, in: zoomNamespace)

            VStack(alignment: .leading, spacing: 3) {
                Text(profile.nameAndAge)
                    .font(.system(.headline, weight: .heavy))
                    .tracking(Theme.Tracking.tight)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(StexxFormat.lastSeen(profile.lastActiveAt, isOnline: profile.isOnline))
                    if let distance = profile.distanceMeters {
                        Text(verbatim: "·")
                            .accessibilityHidden(true)
                        Text(StexxFormat.distance(distance))
                    }
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// The profile zooms out of the avatar; plain push under Reduce Motion.
private struct ViewersZoomTransition: ViewModifier {
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

#Preview {
    NavigationStack {
        ViewersView()
    }
    .previewEnvironment(plus: true)
}
