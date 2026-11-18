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
        PlusBadge()
        Tagline()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .stexxBackground()
    .preferredColorScheme(.dark)
}
