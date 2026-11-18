import SwiftUI

/// The lowercase "stexx" wordmark: heavy and tight, with the "xx" in a
/// violet gradient that carries a soft glow (static, drawn once).
struct Wordmark: View {
    var size: CGFloat = 34
    var glows = true

    var body: some View {
        let kerning = -size * 0.04
        let xx = Text(verbatim: "xx").foregroundStyle(
            LinearGradient(
                colors: [Theme.violetBright, Theme.edgeGlow],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        Text("ste\(xx)")
            .font(.stexxDisplay(size))
            .kerning(kerning)
            .foregroundStyle(Theme.textPrimary)
            .background {
                if glows {
                    // Same layout with only the "xx" visible, so only it glows.
                    Text("ste\(Text(verbatim: "xx").foregroundStyle(Theme.violet))")
                        .foregroundStyle(Color.clear)
                        .font(.stexxDisplay(size))
                        .kerning(kerning)
                        .shadow(color: Theme.edgeGlow.opacity(0.75), radius: size * 0.16)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "stexx"))
    }
}

/// The "XX" mark from `brand/v6c_mark_white.svg`, rendered as a template so
/// it can take any style. Defaults to a white-to-violet gradient with a soft
/// violet glow.
struct StexxMark: View {
    var size: CGFloat = 64
    var glows = true

    var body: some View {
        Image("StexxMark")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(Theme.markGradient)
            .shadow(color: Theme.violet.opacity(glows ? 0.55 : 0), radius: size * 0.22)
            .accessibilityLabel(Text(verbatim: "Stexx"))
    }
}

/// The mark sitting on a liquid-glass squircle, echoing the app icon.
struct StexxLogoTile: View {
    var size: CGFloat = 120

    var body: some View {
        StexxMark(size: size * 0.66)
            .frame(width: size, height: size)
            .stexxGlass(
                in: .rect(cornerRadius: size * 0.27),
                tint: Theme.violet.opacity(0.16),
                fallback: Color(hex: 0x1C1630)
            )
    }
}

/// Small "Stexx+" capsule used to mark premium features, with the "XX" lit
/// violet like the wordmark.
struct PlusBadge: View {
    private static let label: AttributedString = {
        var label = AttributedString("STEXX+")
        if let range = label.range(of: "XX") {
            label[range].foregroundColor = Theme.violetBright
        }
        return label
    }()

    @ScaledMetric(relativeTo: .caption2) private var horizontalPadding: CGFloat = 8
    @ScaledMetric(relativeTo: .caption2) private var verticalPadding: CGFloat = 3

    var body: some View {
        Text(Self.label)
            .font(.caption2.weight(.black))
            .tracking(0.9)
            .lineLimit(1)
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Theme.violet.opacity(0.34), Theme.indigo.opacity(0.42)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: Theme.edgeGlow.opacity(0.4), radius: 5)
            }
            .overlay {
                Capsule().strokeBorder(
                    LinearGradient(
                        colors: [Theme.violetBright.opacity(0.8), Theme.violet.opacity(0.25)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.75
                )
            }
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "Stexx Plus"))
    }
}

#Preview("Brand") {
    VStack(spacing: 32) {
        StexxLogoTile(size: 132)
        Wordmark(size: 56)
        Wordmark(size: 22)
        StexxMark(size: 40, glows: false)
        PlusBadge()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(GlowBackground())
    .preferredColorScheme(.dark)
}
