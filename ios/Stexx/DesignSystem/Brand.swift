import SwiftUI

/// The lowercase "stexx" wordmark: heavy, tracking -0.04em, "ste" in frost
/// and a flat rim-violet "xx". `glows` adds a faint static flare under the
/// "xx" only (rim @ 0.3, radius <= 6). Fixed size (brand art).
struct Wordmark: View {
    var size: CGFloat = 34
    var glows = true

    var body: some View {
        let kerning = Theme.Tracking.wordmark(for: size)
        let xx = Text(verbatim: "xx").foregroundStyle(Theme.rim)
        Text("ste\(xx)")
            .font(.stexxDisplay(size))
            .kerning(kerning)
            .foregroundStyle(Theme.frost)
            .background {
                if glows {
                    // Same layout with only the "xx" visible, so only it carries the flare.
                    Text("ste\(Text(verbatim: "xx").foregroundStyle(Theme.rim))")
                        .foregroundStyle(Color.clear)
                        .font(.stexxDisplay(size))
                        .kerning(kerning)
                        .shadow(color: Theme.rim.opacity(0.3), radius: min(6, size * 0.12))
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "stexx"))
    }
}

/// The "XX" mark (asset `StexxMark`): frost glyph with a violet rim light
/// catching its top-leading edges. `glows` adds a faint flare (rim @ 0.3,
/// radius <= 6).
struct StexxMark: View {
    var size: CGFloat = 64
    var glows = true

    var body: some View {
        let edge = max(0.75, size * 0.014)
        ZStack {
            // Rim light: the glyph in rim, nudged up-left, fading by ~40%.
            glyph
                .foregroundStyle(
                    LinearGradient(
                        stops: [
                            .init(color: Theme.rim.opacity(0.95), location: 0),
                            .init(color: Theme.rim.opacity(0), location: 0.45),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .offset(x: -edge, y: -edge)
            glyph.foregroundStyle(Theme.markGradient)
        }
        .frame(width: size, height: size)
        .shadow(color: Theme.rim.opacity(glows ? 0.3 : 0), radius: min(6, size * 0.1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Stexx"))
    }

    private var glyph: some View {
        Image("StexxMark")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }
}

/// The header-sized mark, drawn from the VECTOR asset `StexxMark` (never the
/// raster app icon) so it stays crisp at 24–44pt: just the XX (about `size`
/// wide) in frost with the violet rim light on its top-leading edges, like
/// `StexxMark`. No tile. The tab header's logo row uses it at 30pt.
///
/// Fixed size: brand art.
struct StexxHeaderMark: View {
    var size: CGFloat = 30

    /// The XX path spans ~74% of the asset's square viewBox (132…892 of
    /// 1024); dividing by this sizes the frame from the visible glyph width.
    private static let glyphFill: CGFloat = 760.0 / 1024.0

    var body: some View {
        bare
            .frame(width: size, height: size)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "Stexx"))
    }

    private var bare: some View {
        // ~2px at 3x: enough to read as a lit edge without blurring the glyph.
        let edge = max(0.67, size * 0.016)
        return ZStack {
            glyph(visibleWidth: size)
                .foregroundStyle(
                    LinearGradient(
                        stops: [
                            .init(color: Theme.rim.opacity(0.95), location: 0),
                            .init(color: Theme.rim.opacity(0), location: 0.45),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .offset(x: -edge, y: -edge)
            glyph(visibleWidth: size)
                .foregroundStyle(Theme.frost)
        }
        .shadow(color: Theme.rim.opacity(0.22), radius: min(4, size * 0.1))
    }

    /// The vector glyph, sized so its visible XX is `visibleWidth` wide. The
    /// frame may exceed the mark's box; the overflow is transparent padding.
    private func glyph(visibleWidth: CGFloat) -> some View {
        let box = visibleWidth / Self.glyphFill
        return Image("StexxMark")
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: box, height: box)
    }
}

/// The mark on a flat ink1 square (radius 0.22 × size) with a top-lit edge
/// and the cell's corner ticks around it.
struct StexxLogoTile: View {
    var size: CGFloat = 120

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
        StexxMark(size: size * 0.62)
            .frame(width: size, height: size)
            .background(shape.fill(Theme.ink1))
            .glassEdge(shape)
            .cellCorners(outset: max(4, size * 0.05), arm: max(6, size * 0.08))
    }
}

/// "STEXX+" in mono caps: frost text with the "XX" in rim, a 0.5pt rim @ 0.6
/// border, radius 4, no fill, no glow.
struct PlusBadge: View {
    private static let label: AttributedString = {
        var label = AttributedString("STEXX+")
        if let range = label.range(of: "XX") {
            label[range].foregroundColor = Theme.rim
        }
        return label
    }()

    @ScaledMetric(relativeTo: .caption2) private var horizontalPadding: CGFloat = 6
    @ScaledMetric(relativeTo: .caption2) private var verticalPadding: CGFloat = 3

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous)
        Text(Self.label)
            .stexxLabelStyle(.micro, color: Theme.frost)
            .lineLimit(1)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .overlay(shape.strokeBorder(Theme.rim.opacity(0.6), lineWidth: 0.5))
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "Stexx Plus"))
    }
}

/// The brand tagline, "No ads. Just stexx.", set in the mono label style.
struct Tagline: View {
    var body: some View {
        Text("No ads. Just stexx.")
            .stexxLabelStyle()
    }
}

#Preview("Brand") {
    VStack(spacing: 32) {
        StexxLogoTile(size: 128)
        Wordmark(size: 56)
        Wordmark(size: 22)
        StexxMark(size: 40, glows: false)
        HStack(spacing: 20) {
            StexxHeaderMark(size: 24)
            StexxHeaderMark(size: 30)
            StexxHeaderMark(size: 44)
        }
        PlusBadge()
        Tagline()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .stexxBackground()
    .preferredColorScheme(.dark)
}
