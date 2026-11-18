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
                .listRowSeparatorTint(Theme.line)
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + 64 }
            }
        }
        .listStyle(.plain)
        .overlay {
            if isLoading {
                ProgressView()
                    .tint(Theme.steel)
            } else if let errorMessage {
                ContentUnavailableView("Couldn't load viewers", systemImage: "eyes", description: Text(errorMessage))
            } else if viewers.isEmpty {
                ContentUnavailableView("No views yet", systemImage: "eyes", description: Text("People who view your profile show up here for 7 days."))
            }
        }
        .stexxBackground(intensity: 0.4)
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
        SectionLabel("\(count) people in the last 7 days")
            .padding(.top, Theme.Spacing.s)
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

/// One viewer: square avatar with a static online dot, name, and a
/// mono-caps last seen / distance line.
private struct ViewerRow: View {
    let profile: Profile
    let zoomNamespace: Namespace.ID

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            AvatarView(profile: profile, size: 52)
                .matchedTransitionSource(id: profile.id, in: zoomNamespace)

            VStack(alignment: .leading, spacing: 5) {
                Text(profile.nameAndAge)
                    .font(.stexxHeadline)
                    .foregroundStyle(Theme.frost)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(StexxFormat.lastSeen(profile.lastActiveAt, isOnline: profile.isOnline))
                    if let distance = profile.distanceMeters {
                        Text(verbatim: "/")
                            .foregroundStyle(Theme.slate)
                            .accessibilityHidden(true)
                        Text(StexxFormat.distance(distance))
                    }
                }
                .stexxLabelStyle()
                .lineLimit(1)
            }
        }
        .padding(.vertical, 6)
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
