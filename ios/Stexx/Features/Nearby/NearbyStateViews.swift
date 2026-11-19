import SwiftUI
import UIKit

/// The full-screen states of the Nearby grid (`NearbyContent` other than
/// `.grid`): first run, location off, nobody nearby, and errors.
struct NearbyStateView: View {
    let content: NearbyContent
    var onRetry: () -> Void = {}
    var onClearFilters: () -> Void = {}
    var onTravelMode: () -> Void = {}

    var body: some View {
        switch content {
        case .grid:
            EmptyView()
        case .loading:
            ProgressView()
                .controlSize(.regular)
                .tint(Theme.steel)
                .accessibilityLabel("Loading people nearby")
        case .findingLocation:
            findingLocation
        case .locationOff(let restricted):
            locationOff(restricted: restricted)
        case .failed(let message):
            failed(message)
        case .empty(let filtersActive):
            empty(filtersActive: filtersActive)
        }
    }

    // MARK: States

    private var findingLocation: some View {
        ContentUnavailableView {
            Label {
                title("Finding guys near you…")
            } icon: {
                markIcon
            }
        } description: {
            description("Placing you on the grid. Only an approximate area of about 500 m leaves your phone, never your exact spot.")
        } actions: {
            ProgressView()
                .controlSize(.regular)
                .tint(Theme.steel)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }

    private func locationOff(restricted: Bool) -> some View {
        ContentUnavailableView {
            Label {
                title(restricted ? "Location isn't available" : "Location is off")
            } icon: {
                symbolIcon("location.slash")
            }
        } description: {
            if restricted {
                description("Location access is restricted on this iPhone, for example by Screen Time or a device profile, so Stexx can't place you on the grid.")
            } else {
                description("Stexx needs your approximate location to show who's nearby. Turn on Location Services and allow Stexx in Settings. Only an area of about 500 m is shared, never your exact spot.")
            }
        } actions: {
            VStack(spacing: Theme.Spacing.m) {
                if !restricted {
                    Button("Open Settings", action: Self.openSettings)
                        .stexxPrimaryButton()
                        .accessibilityHint("Opens Stexx in the Settings app")
                }
                // Travel mode places you on a cell picked on a map, so it
                // works without the phone's location.
                Button(action: onTravelMode) {
                    Label("Browse with travel mode", systemImage: "airplane")
                }
                .stexxSecondaryButton()
                .accessibilityHint("Stexx+. Pick a place on a map; no device location needed.")
                Text("Travel mode (Stexx+) works without device location.")
                    .stexxLabelStyle(.micro)
                    .multilineTextAlignment(.center)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: 320)
        }
    }

    private func failed(_ message: String) -> some View {
        ContentUnavailableView {
            Label {
                title("Couldn't load the grid")
            } icon: {
                symbolIcon("wifi.exclamationmark")
            }
        } description: {
            plainDescription(message)
        } actions: {
            Button("Try again", action: onRetry)
                .stexxSecondaryButton()
                .frame(maxWidth: 240)
        }
    }

    private func empty(filtersActive: Bool) -> some View {
        ContentUnavailableView {
            Label {
                title(filtersActive ? "Nobody matches your filters" : "Nobody here yet")
            } icon: {
                if filtersActive {
                    symbolIcon("line.3.horizontal.decrease")
                } else {
                    markIcon
                }
            }
        } description: {
            if filtersActive {
                description("Widen your filters to see more people.")
            } else {
                description("Nobody's around right now. Check back in a bit, or pull down to refresh.")
            }
        } actions: {
            if filtersActive {
                Button("Clear filters", action: onClearFilters)
                    .stexxSecondaryButton()
                    .frame(maxWidth: 240)
                    .accessibilityHint("Shows everyone nearby again")
            }
        }
    }

    // MARK: Pieces

    private func title(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .stexxTitleStyle(.title)
            .multilineTextAlignment(.center)
    }

    private func description(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.stexxSub)
            .foregroundStyle(Theme.steel)
    }

    private func plainDescription(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.stexxSub)
            .foregroundStyle(Theme.steel)
    }

    private var markIcon: some View {
        StexxMark(size: 40, glows: false)
            .padding(Theme.Spacing.m)
            .cellCorners()
            .padding(.bottom, Theme.Spacing.s)
            .accessibilityHidden(true)
    }

    private func symbolIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(.largeTitle, weight: .regular))
            .foregroundStyle(Theme.steel)
            .padding(.bottom, Theme.Spacing.s)
            .accessibilityHidden(true)
    }

    /// Opens Stexx's page in the Settings app (location permission).
    static func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

/// The cell at the end of the grid: a spinner while the next page loads, or
/// Retry after it failed (instead of the grid silently ending).
struct NearbyPageFooter: View {
    let state: NearbyFeedModel.NextPage
    let onRetry: () -> Void

    var body: some View {
        Group {
            switch state {
            case .idle, .loading:
                ProgressView()
                    .controlSize(.small)
                    .tint(Theme.steel)
                    .accessibilityLabel("Loading more people")
            case .failed:
                HStack(spacing: Theme.Spacing.m) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Theme.steel)
                        .accessibilityHidden(true)
                    Text("Couldn't load more")
                        .font(.stexxSub)
                        .foregroundStyle(Theme.frost)
                    Spacer(minLength: 0)
                    Button("Retry", action: onRetry)
                        .buttonStyle(.stexxSecondary)
                        .fixedSize()
                        .accessibilityHint("Loads more people nearby")
                }
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.vertical, Theme.Spacing.m)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous).fill(Theme.ink1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous)
                        .strokeBorder(Theme.line, lineWidth: 0.5)
                )
                .accessibilityElement(children: .contain)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 56)
        .padding(.vertical, Theme.Spacing.s)
    }
}

/// A slim notice above the grid: location off while tiles still show (the
/// server's last known area), or a failed refresh.
struct NearbyNotice: View {
    let systemImage: String
    let text: Text
    var actionTitle: LocalizedStringKey?
    var action: () -> Void = {}
    var onDismiss: (() -> Void)?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous)
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: systemImage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.steel)
                .accessibilityHidden(true)
            text
                .font(.footnote)
                .foregroundStyle(Theme.frost)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle {
                Button(actionTitle, action: action)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.ice)
                    .buttonStyle(.plain)
                    .fixedSize()
            }
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.steel)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, onDismiss == nil ? 10 : 2)
        .padding(.vertical, 8)
        .background(shape.fill(Theme.ink1))
        .overlay(shape.strokeBorder(Theme.line, lineWidth: 0.5))
        .accessibilityElement(children: .contain)
    }
}

#Preview("States") {
    TabView {
        Tab("First run", systemImage: "1.circle") { NearbyStateView(content: .findingLocation) }
        Tab("Off", systemImage: "2.circle") { NearbyStateView(content: .locationOff(restricted: false)) }
        Tab("Restricted", systemImage: "3.circle") { NearbyStateView(content: .locationOff(restricted: true)) }
        Tab("Filtered", systemImage: "4.circle") { NearbyStateView(content: .empty(filtersActive: true)) }
        Tab("Error", systemImage: "5.circle") {
            NearbyStateView(content: .failed("The Internet connection appears to be offline."))
        }
    }
    .stexxBackground()
    .preferredColorScheme(.dark)
}

#Preview("Footer and notice") {
    VStack(spacing: 12) {
        NearbyNotice(
            systemImage: "location.slash",
            text: Text("Location is off. Showing people near your last known area."),
            actionTitle: "Settings"
        )
        NearbyPageFooter(state: .loading) {}
        NearbyPageFooter(state: .failed("Timed out")) {}
    }
    .padding()
    .background(Theme.ink)
    .preferredColorScheme(.dark)
}
