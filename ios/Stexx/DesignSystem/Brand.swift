import SwiftUI

/// The lowercase "stexx" wordmark with the "xx" tinted violet.
struct Wordmark: View {
    var size: CGFloat = 34

    var body: some View {
        let xx = Text(verbatim: "xx").foregroundStyle(Theme.violetBright)
        Text("ste\(xx)")
            .font(.stexxDisplay(size))
            .kerning(-size * 0.035)
            .foregroundStyle(Theme.textPrimary)
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
            .glassEffect(
                .regular.tint(Theme.violet.opacity(0.16)),
                in: .rect(cornerRadius: size * 0.27)
            )
    }
}

/// Small "Stexx+" capsule used to mark premium features.
struct PlusBadge: View {
    var body: some View {
        Text(verbatim: "STEXX+")
            .font(.caption2.weight(.heavy))
            .tracking(0.8)
            .foregroundStyle(Theme.violetBright)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Theme.violet.opacity(0.18), in: .capsule)
            .overlay(Capsule().strokeBorder(Theme.violet.opacity(0.35), lineWidth: 0.5))
    }
}

#Preview("Brand") {
    VStack(spacing: 32) {
        StexxLogoTile(size: 132)
        Wordmark(size: 56)
        StexxMark(size: 40, glows: false)
        PlusBadge()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(GlowBackground())
    .preferredColorScheme(.dark)
}
