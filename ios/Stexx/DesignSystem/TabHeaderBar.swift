import SwiftUI

// The tab header: one compact row at the top of each tab root (Nearby, Chats,
// You) instead of a navigation bar plus a big title. Leading is the xx app
// mark, the middle is a flexible slot (a small title, or inline chips) and
// trailing holds optional icon buttons. The background is near-opaque black
// frosted glass that runs up under the status bar, with a 0.5pt hairline at
// the bottom, so content scrolling under it doesn't visibly bleed through.
//
// Use `.tabHeader { … } trailing: { … }` on the root content inside the
// tab's NavigationStack. It hides the system navigation bar for that root
// only; pushed screens keep their normal bars and back buttons.

/// The app icon (asset `StexxAppMark`: a glassy XX on a dark squircle),
/// rendered as-is (non-template). Fixed size: brand art.
struct StexxAppIconMark: View {
    var size: CGFloat = 28

    var body: some View {
        Image("StexxAppMark")
            .renderingMode(.original)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "Stexx"))
    }
}

/// One short row: xx mark, flexible middle, optional trailing buttons.
struct TabHeaderBar<Center: View, Trailing: View>: View {
    /// Height of the row itself, below the status bar.
    static var rowHeight: CGFloat { 46 }

    @ViewBuilder var center: Center
    @ViewBuilder var trailing: Trailing

    init(@ViewBuilder center: () -> Center, @ViewBuilder trailing: () -> Trailing) {
        self.center = center()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            StexxAppIconMark(size: 29)
            center
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, Theme.Spacing.l)
        .frame(minHeight: Self.rowHeight)
        .background { TabHeaderBackground() }
    }
}

extension TabHeaderBar where Trailing == EmptyView {
    init(@ViewBuilder center: () -> Center) {
        self.init(center: center, trailing: { EmptyView() })
    }
}

/// Black frosted glass, close to opaque: ultra-thin material under an ink
/// @ 0.85 veil (solid ink under Reduce Transparency), extending up under
/// the status bar, with a 0.5pt hairline along the bottom edge.
private struct TabHeaderBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            if reduceTransparency {
                Theme.ink
            } else {
                Rectangle().fill(.ultraThinMaterial)
                Theme.ink.opacity(0.85)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.line)
                .frame(height: 0.5)
        }
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
    }
}

/// The small lowercase heavy title used in the middle of a tab header
/// ("chats", "you"). Pass the localized title; it is lowercased for display
/// and read by VoiceOver as written.
struct TabHeaderTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(verbatim: title.lowercased())
            .font(.title3.weight(.heavy))
            .tracking(Theme.Tracking.tight)
            .foregroundStyle(Theme.frost)
            .lineLimit(1)
            .accessibilityLabel(Text(verbatim: title))
            .accessibilityAddTraits(.isHeader)
    }
}

/// A plain steel icon button for the header's trailing slot (44pt target).
struct TabHeaderIconLabel: View {
    let title: LocalizedStringKey
    let systemImage: String
    var tint: Color = Theme.steel

    var body: some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.iconOnly)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 44, height: 44)
            .contentShape(.rect)
    }
}

extension View {
    /// Pins a `TabHeaderBar` to the top safe area and hides the system
    /// navigation bar. Apply to a tab's root content only.
    func tabHeader<Center: View, Trailing: View>(
        @ViewBuilder center: () -> Center,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        let bar = TabHeaderBar(center: center, trailing: trailing)
        return self
            .safeAreaInset(edge: .top, spacing: 0) { bar }
            .toolbar(.hidden, for: .navigationBar)
    }

    func tabHeader<Center: View>(@ViewBuilder center: () -> Center) -> some View {
        tabHeader(center: center, trailing: { EmptyView() })
    }
}

#Preview("Tab header") {
    ScrollView {
        VStack(spacing: 2) {
            ForEach(0..<30, id: \.self) { index in
                Theme.ink2.frame(height: 80).overlay(Text(verbatim: "\(index)").foregroundStyle(Theme.steel))
            }
        }
    }
    .tabHeader {
        TabHeaderTitle("Chats")
    } trailing: {
        Text(verbatim: "3 new").stexxLabelStyle(color: Theme.frost)
    }
    .stexxBackground()
    .preferredColorScheme(.dark)
}
