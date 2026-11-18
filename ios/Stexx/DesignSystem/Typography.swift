import SwiftUI

// Type: heavy SF Pro display (lowercase brand words, tight tracking) paired
// with an SF Mono uppercase meta layer. All sizes follow Dynamic Type.
//
// Scale: display 34 heavy · title 22 heavy · headline 17 semibold ·
// body 17 · sub 15 · label 11 mono caps · micro 10 mono caps.

extension Font {
    /// Display, 34 heavy (largeTitle). Pair with `Theme.Tracking.display`.
    static let stexxLargeTitle = Font.system(.largeTitle, design: .default, weight: .heavy)
    /// Title, 22 heavy (title2). Pair with `Theme.Tracking.title`.
    static let stexxTitle = Font.system(.title2, design: .default, weight: .heavy)
    /// Headline, 17 semibold.
    static let stexxHeadline = Font.system(.headline, design: .default, weight: .semibold)
    /// Body, 17 regular.
    static let stexxBody = Font.system(.body)
    /// Sub, 15 regular.
    static let stexxSub = Font.system(.subheadline)
    /// Label, 11 mono medium. Use via `.stexxLabelStyle()` for caps + tracking.
    static let stexxLabel = Font.system(.caption2, design: .monospaced, weight: .medium)
    /// Micro, mono medium (caption2-relative). `.stexxLabelStyle(.micro)` gives the exact scaled 10pt.
    static let stexxMicro = Font.system(.caption2, design: .monospaced, weight: .medium)
    /// Legacy caption → now the mono label face.
    static let stexxCaption = stexxLabel

    /// Legacy → display 34 heavy (was black).
    static let stexxHero = Font.system(.largeTitle, design: .default, weight: .heavy)
    /// Names on profile headers and featured tiles: 22 heavy.
    static let stexxName = Font.system(.title2, design: .default, weight: .heavy)
    /// Names on small tiles and rows: 15 heavy.
    static let stexxNameSmall = Font.system(.subheadline, design: .default, weight: .heavy)

    /// Fixed-size heavy display face (wordmark, big numbers). Not Dynamic Type.
    static func stexxDisplay(_ size: CGFloat) -> Font {
        .system(size: size, weight: .heavy, design: .default)
    }
}

// MARK: - Mono caps label

/// Size of the mono-caps meta layer.
enum StexxLabelSize: Sendable {
    /// 11pt, tracking 0.18em: section labels, meta, chips, timestamps.
    case label
    /// 10pt, tracking 0.16em: badge text, tiny meta on photos.
    case micro
}

extension View {
    /// SF Mono, medium, UPPERCASE, wide tracking, Dynamic Type scaled.
    /// The meta layer: "0.5 KM", "ONLINE", "2M AGO", counts, chips.
    func stexxLabelStyle(_ size: StexxLabelSize = .label, color: Color = Theme.steel) -> some View {
        modifier(StexxLabelModifier(size: size, color: color))
    }
}

private struct StexxLabelModifier: ViewModifier {
    let size: StexxLabelSize
    let color: Color

    @ScaledMetric(relativeTo: .caption2) private var labelSize: CGFloat = 11
    @ScaledMetric(relativeTo: .caption2) private var microSize: CGFloat = 10

    init(size: StexxLabelSize, color: Color) {
        self.size = size
        self.color = color
    }

    func body(content: Content) -> some View {
        let points = size == .label ? labelSize : microSize
        content
            .font(.system(size: points, weight: .medium, design: .monospaced))
            .textCase(.uppercase)
            .tracking(points * (size == .label ? 0.18 : 0.16))
            .foregroundStyle(color)
    }
}

// MARK: - Display titles

/// Level of heavy display type.
enum StexxTitleLevel: Sendable {
    /// 34 heavy, -1.0 tracking. Screen titles ("nearby", "chats", "you").
    case display
    /// 22 heavy, -0.66 tracking. Sheet and section titles, names.
    case title
}

extension View {
    /// Heavy display type in frost with tight tracking. Screen titles are
    /// written lowercase by the caller ("nearby"); names stay as typed.
    func stexxTitleStyle(_ level: StexxTitleLevel = .display) -> some View {
        self
            .font(level == .display ? .stexxLargeTitle : .stexxTitle)
            .tracking(level == .display ? Theme.Tracking.display : Theme.Tracking.title)
            .foregroundStyle(Theme.frost)
    }
}

// MARK: - Section label

/// "× ABOUT": mono caps section label led by a small rim-violet × tick.
/// Exposed to VoiceOver as a header (the × is hidden).
struct SectionLabel: View {
    let title: Text

    init(_ title: LocalizedStringKey) {
        self.title = Text(title)
    }

    init(verbatim title: String) {
        self.title = Text(verbatim: title)
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: "×")
                .stexxLabelStyle(color: Theme.rim)
                .accessibilityHidden(true)
            title
                .stexxLabelStyle()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

#Preview("Type") {
    VStack(alignment: .leading, spacing: 14) {
        Text(verbatim: "nearby").stexxTitleStyle()
        Text(verbatim: "chats").stexxTitleStyle(.title)
        Text(verbatim: "Name").font(.stexxName).tracking(Theme.Tracking.tight)
        Text(verbatim: "Headline").font(.stexxHeadline)
        Text(verbatim: "Body copy in frost.").font(.stexxBody).foregroundStyle(Theme.frost)
        Text(verbatim: "Sub copy in steel.").font(.stexxSub).foregroundStyle(Theme.steel)
        Text(verbatim: "0.5 km · online").stexxLabelStyle()
        Text(verbatim: "2m ago").stexxLabelStyle(.micro, color: Theme.slate)
        SectionLabel("About")
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .stexxBackground()
    .preferredColorScheme(.dark)
}
