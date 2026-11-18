import SwiftUI

// The tab header at the top of each tab root (Nearby, Chats, You), instead
// of a navigation bar plus a big title. Two rows on one background:
// - the logo row (~40pt): the vector xx mark (`StexxHeaderMark`, 30pt),
//   centered. It slides away when the tab's content scrolls down and comes
//   back on scroll up or near the top (Reduce Motion: a fade).
// - the compact row (~40pt): a flexible middle slot (a small title, or
//   inline chips) and optional trailing controls. It stays pinned, just under
//   the status bar while the logo row is hidden.
// The background is near-opaque black frosted glass that runs up under the
// status bar, with a 0.5pt hairline at the bottom, so content scrolling
// under it doesn't visibly bleed through.
//
// Use `.tabHeader { … } trailing: { … }` on the root content inside the
// tab's NavigationStack, and `.collapsesTabHeaderLogo()` on the tab's
// vertical ScrollView or List (inside `.tabHeader`). It hides the system
// navigation bar for that root only; pushed screens keep their normal bars
// and back buttons.

/// The tab header: a centered logo row above the middle and trailing slots.
struct TabHeaderBar<Center: View, Trailing: View>: View {
    /// Height of the centered logo row.
    static var logoRowHeight: CGFloat { 40 }
    /// Height of the row holding the middle and trailing slots.
    static var rowHeight: CGFloat { 40 }

    /// Whether the logo row is visible (drives its opacity and VoiceOver).
    var isLogoVisible = true
    /// Whether the logo row is collapsed to zero height.
    var isLogoCollapsed = false

    @ViewBuilder var center: Center
    @ViewBuilder var trailing: Trailing

    init(
        isLogoVisible: Bool = true,
        isLogoCollapsed: Bool = false,
        @ViewBuilder center: () -> Center,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.isLogoVisible = isLogoVisible
        self.isLogoCollapsed = isLogoCollapsed
        self.center = center()
        self.trailing = trailing()
    }

    var body: some View {
        VStack(spacing: 0) {
            logoRow
            HStack(spacing: Theme.Spacing.m) {
                center
                    .frame(maxWidth: .infinity, alignment: .leading)
                trailing
            }
            .padding(.horizontal, Theme.Spacing.l)
            .frame(minHeight: Self.rowHeight)
        }
        .background { TabHeaderBackground() }
    }

    /// Bottom-aligned in a clipped frame, so as the height collapses the mark
    /// rides up and out under the status bar while it fades.
    private var logoRow: some View {
        StexxHeaderMark(size: 30)
            .frame(maxWidth: .infinity)
            .frame(height: Self.logoRowHeight)
            .frame(height: isLogoCollapsed ? 0 : Self.logoRowHeight, alignment: .bottom)
            .clipped()
            .opacity(isLogoVisible ? 1 : 0)
            .accessibilityHidden(!isLogoVisible)
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

// MARK: - Logo row collapse

/// Shared between `.tabHeader` (which draws the bar) and
/// `.collapsesTabHeaderLogo()` (which watches the tab's scroll view).
@MainActor @Observable
final class TabHeaderLogoState {
    /// The logo row is visible (opacity, VoiceOver).
    private(set) var isVisible = true
    /// The logo row is collapsed to zero height.
    private(set) var isCollapsed = false

    /// The logo row always shows within this distance of the top.
    static let topZone: CGFloat = 10
    /// Scroll this far against the current state before it flips, so small
    /// jitters don't make the row flicker.
    static let threshold: CGFloat = 8

    /// The offset direction changes are measured from: the furthest point
    /// reached in the current direction.
    @ObservationIgnored private var anchor: CGFloat = 0

    func scrolled(from old: TabHeaderScrollSample, to new: TabHeaderScrollSample, reduceMotion: Bool) {
        // The header's own height change moves the content inset (and with
        // it the relative offset); that isn't the user scrolling.
        guard old.insetTop == new.insetTop else {
            anchor = new.offset
            return
        }
        let offset = new.offset
        if offset <= Self.topZone {
            anchor = offset
            setHidden(false, reduceMotion: reduceMotion)
            return
        }
        if isVisible {
            // Shown: the anchor follows the lowest offset; scrolling down
            // past the threshold from there hides the row.
            if offset < anchor {
                anchor = offset
            } else if offset - anchor > Self.threshold {
                anchor = offset
                setHidden(true, reduceMotion: reduceMotion)
            }
        } else {
            // Hidden: the anchor follows the highest offset; scrolling up
            // past the threshold from there brings the row back.
            if offset > anchor {
                anchor = offset
            } else if anchor - offset > Self.threshold {
                anchor = offset
                setHidden(false, reduceMotion: reduceMotion)
            }
        }
    }

    private func setHidden(_ hidden: Bool, reduceMotion: Bool) {
        guard isVisible == hidden else { return }
        if !reduceMotion {
            withAnimation(.easeInOut(duration: 0.25)) {
                isVisible = !hidden
                isCollapsed = hidden
            }
        } else if hidden {
            // Fade out in place, then drop the height without animation.
            withAnimation(Motion.fade) {
                isVisible = false
            } completion: { [weak self] in
                guard let self, !self.isVisible else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { self.isCollapsed = true }
            }
        } else {
            // Restore the height without animation, then fade in.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { isCollapsed = false }
            withAnimation(Motion.fade) { isVisible = true }
        }
    }
}

/// What `.collapsesTabHeaderLogo()` reads from the scroll geometry.
struct TabHeaderScrollSample: Equatable {
    /// Distance scrolled from the top, clamped at the bottom so the
    /// bottom rubber band doesn't read as scrolling up.
    var offset: CGFloat
    var insetTop: CGFloat

    init(_ geometry: ScrollGeometry) {
        let raw = geometry.contentOffset.y + geometry.contentInsets.top
        let maxOffset = max(
            0,
            geometry.contentSize.height + geometry.contentInsets.top
                + geometry.contentInsets.bottom - geometry.containerSize.height
        )
        offset = min(raw, maxOffset)
        insetTop = geometry.contentInsets.top
    }
}

extension EnvironmentValues {
    @Entry var tabHeaderLogoState: TabHeaderLogoState?
}

private struct TabHeaderModifier<Center: View, Trailing: View>: ViewModifier {
    let center: Center
    let trailing: Trailing

    @State private var logo = TabHeaderLogoState()

    func body(content: Content) -> some View {
        content
            .environment(\.tabHeaderLogoState, logo)
            .safeAreaInset(edge: .top, spacing: 0) {
                TabHeaderBar(isLogoVisible: logo.isVisible, isLogoCollapsed: logo.isCollapsed) {
                    center
                } trailing: {
                    trailing
                }
            }
            .toolbar(.hidden, for: .navigationBar)
    }
}

private struct CollapsesTabHeaderLogo: ViewModifier {
    @Environment(\.tabHeaderLogoState) private var logo
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.onScrollGeometryChange(for: TabHeaderScrollSample.self) { geometry in
            TabHeaderScrollSample(geometry)
        } action: { old, new in
            logo?.scrolled(from: old, to: new, reduceMotion: reduceMotion)
        }
    }
}

extension View {
    /// Pins a `TabHeaderBar` to the top safe area and hides the system
    /// navigation bar. Apply to a tab's root content only, and mark its
    /// vertical scroll view with `.collapsesTabHeaderLogo()`.
    func tabHeader<Center: View, Trailing: View>(
        @ViewBuilder center: () -> Center,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        modifier(TabHeaderModifier(center: center(), trailing: trailing()))
    }

    func tabHeader<Center: View>(@ViewBuilder center: () -> Center) -> some View {
        tabHeader(center: center, trailing: { EmptyView() })
    }

    /// Apply to a tab root's vertical ScrollView or List (inside
    /// `.tabHeader`): the header's logo row hides while scrolling down and
    /// returns on scroll up or near the top.
    func collapsesTabHeaderLogo() -> some View {
        modifier(CollapsesTabHeaderLogo())
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
    .collapsesTabHeaderLogo()
    .tabHeader {
        TabHeaderTitle("Chats")
    } trailing: {
        Text(verbatim: "3 new").stexxLabelStyle(color: Theme.frost)
    }
    .stexxBackground()
    .preferredColorScheme(.dark)
}
