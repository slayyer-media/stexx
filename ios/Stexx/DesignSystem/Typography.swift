import SwiftUI

/// Type ramp. Stexx uses SF Pro (the system font), heavy and tight for
/// display type so it reads close to the bold geometric wordmark, and keeps
/// Dynamic Type support everywhere except the fixed-size wordmark. Pair
/// display styles with `.tracking(Theme.Tracking.display)` / `.tight`.
extension Font {
    static let stexxLargeTitle = Font.system(.largeTitle, design: .default, weight: .heavy)
    static let stexxTitle = Font.system(.title2, design: .default, weight: .heavy)
    static let stexxHeadline = Font.system(.headline, design: .default, weight: .bold)
    static let stexxBody = Font.system(.body)
    static let stexxCaption = Font.system(.caption, design: .default, weight: .medium)

    /// Heavy display face used by the wordmark and big numbers.
    static func stexxDisplay(_ size: CGFloat) -> Font {
        .system(size: size, weight: .heavy, design: .default)
    }
}

/// Small uppercase label used above groups of content, led by a short violet
/// "xx" accent tick. Exposed to VoiceOver as a header.
struct SectionLabel: View {
    let title: LocalizedStringKey

    @ScaledMetric(relativeTo: .caption) private var tickHeight: CGFloat = 11

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        HStack(spacing: 7) {
            Capsule()
                .fill(Theme.accentGradient)
                .frame(width: 3, height: tickHeight)
                .shadow(color: Theme.edgeGlow.opacity(0.6), radius: 3)
                .accessibilityHidden(true)
            Text(title)
                .font(.caption.weight(.bold))
                .textCase(.uppercase)
                .tracking(1.2)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

#Preview("Type") {
    VStack(alignment: .leading, spacing: 14) {
        Text(verbatim: "Nearby").font(.stexxHero).tracking(Theme.Tracking.display)
        Text(verbatim: "Large title").font(.stexxLargeTitle).tracking(Theme.Tracking.display)
        Text(verbatim: "Title").font(.stexxTitle).tracking(Theme.Tracking.tight)
        Text(verbatim: "Name").font(.stexxName).tracking(Theme.Tracking.tight)
        Text(verbatim: "Headline").font(.stexxHeadline)
        SectionLabel("About")
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .background(GlowBackground())
    .preferredColorScheme(.dark)
}
