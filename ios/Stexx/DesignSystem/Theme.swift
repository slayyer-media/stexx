import SwiftUI

/// Central design tokens for Stexx ("cold glass, violet rim light").
///
/// Dark-only: black frosted glass on a near-black ink base, cool steel/ice
/// neutrals and hairlines. The only colour is violet *lighting*: `rim` for
/// thin rim strokes, the "xx" and the × tick, `flare` for the one static
/// lens flare. Never use `rim`/`flare` as a fill. See `DESIGN.md`.
enum Theme {
    // MARK: Palette — base

    /// App background (#050608).
    static let ink = Color(hex: 0x050608)
    /// Flat raised surfaces: rows, their bubbles, fields, chips (#0A0C10).
    static let ink1 = Color(hex: 0x0A0C10)
    /// Pressed / selected / input fill (#12161C).
    static let ink2 = Color(hex: 0x12161C)
    /// Hairline dividers and borders, 0.5pt (white @ 0.08).
    static let line = Color.white.opacity(0.08)
    /// Top edge of glass and focused borders (white @ 0.14).
    static let lineStrong = Color.white.opacity(0.14)

    // MARK: Palette — neutrals

    /// Primary text, primary button fill, own chat bubble fill (#E8EEF5).
    static let frost = Color(hex: 0xE8EEF5)
    /// Secondary text and icons (#8B96A5).
    static let steel = Color(hex: 0x8B96A5)
    /// Tertiary text, disabled, placeholders (#545E6B).
    static let slate = Color(hex: 0x545E6B)
    /// Cool interactive tint: links, selected states, app tint (#A9C8E8).
    static let ice = Color(hex: 0xA9C8E8)

    // MARK: Palette — violet lighting (never fills)

    /// Rim light: 0.5–1pt rim strokes, the "xx", the × tick, flare streaks (#A78BFF).
    static let rim = Color(hex: 0xA78BFF)
    /// Lens-flare blobs only, at <= 0.12 opacity (#7B5CFF).
    static let flare = Color(hex: 0x7B5CFF)
    /// Cool steel light at the bottom-leading of the background (#1B2430).
    static let coolLight = Color(hex: 0x1B2430)

    // MARK: Palette — semantic

    /// The 6pt online dot. Static, no pulse, no glow (#4FE3B5).
    static let online = Color(hex: 0x4FE3B5)
    static let danger = Color(hex: 0xFF5A6A)
    static let warning = Color(hex: 0xFFC56B)

    // MARK: Legacy aliases (v1 names mapped onto the v2 palette)
    // Kept so existing feature code restyles automatically. Prefer the v2
    // names above in new code.

    /// Legacy → `ink`.
    static let background = ink
    /// Legacy → `ink1`.
    static let backgroundRaised = ink1
    /// Legacy → `ice`. v1 used violet as the interactive tint; v2 uses ice.
    static let violet = ice
    /// Legacy → `ice` (icons, highlights, tints).
    static let violetBright = ice
    /// Legacy → `ink2` (v1 deep violet fill; v2 has no violet fills).
    static let violetDeep = ink2
    /// Legacy → `ink2` (v1 background glow colour).
    static let indigo = ink2
    /// Legacy → `ink2` (v1 background glow colour).
    static let plum = ink2
    /// Legacy → `rim`. Use only for thin strokes, not glow shadows.
    static let edgeGlow = rim
    /// Legacy → `frost`.
    static let textPrimary = frost
    /// Legacy → `steel`.
    static let textSecondary = steel
    /// Legacy → `slate`.
    static let textTertiary = slate
    /// Legacy → `ink1`.
    static let surface = ink1
    /// Legacy → `ink2`.
    static let surfaceStrong = ink2
    /// Legacy → `line`.
    static let hairline = line

    // MARK: Gradients

    /// The rim-light stroke: `rim` @ 0.9 at the top-leading corner fading to
    /// clear within ~35% of the perimeter. Used by `.rimLight()`.
    static func rimLightGradient(intensity: Double = 1) -> AngularGradient {
        let peak = min(max(0.9 * intensity, 0), 1)
        return AngularGradient(
            stops: [
                .init(color: rim.opacity(0), location: 0),
                .init(color: rim.opacity(peak), location: 0.34),
                .init(color: rim.opacity(0), location: 1),
            ],
            center: .center,
            // 0° is trailing, clockwise. 225° is top-leading.
            startAngle: .degrees(170),
            endAngle: .degrees(330)
        )
    }

    /// Top-lit glass edge: `lineStrong` at the top fading to `line`.
    static var glassEdge: LinearGradient {
        LinearGradient(colors: [lineStrong, line], startPoint: .top, endPoint: .bottom)
    }

    /// Legacy adapter: v1 violet accent gradient, now a flat cool steel so
    /// small glyph backgrounds and ticks stay legible without violet fills.
    static var accentGradient: LinearGradient {
        LinearGradient(
            colors: [Color(hex: 0x2A323D), Color(hex: 0x1A2029)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Fill for the "XX" mark: frost with a hint of ice at the bottom.
    static var markGradient: LinearGradient {
        LinearGradient(
            colors: [frost, frost.mix(with: ice, by: 0.35)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Legacy adapter: v1 violet own-bubble fill, now a cool steel glass tone
    /// so existing white bubble text stays legible. The v2 target is a flat
    /// `frost` bubble with `ink` text (feature phase).
    static var ownBubbleGradient: LinearGradient {
        LinearGradient(
            colors: [Color(hex: 0x262E39), Color(hex: 0x1B2129)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Scrim at the bottom of photo tiles so text stays legible.
    static var photoScrim: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: ink.opacity(0), location: 0),
                .init(color: ink.opacity(0.35), location: 0.45),
                .init(color: ink.opacity(0.8), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: Metrics

    /// Radius scale: xs 4 · sm 6 · md 10 · lg 14 · pill.
    enum Radius {
        /// Tiles, chips, tags, badges.
        static let xs: CGFloat = 4
        /// Small buttons, square avatars.
        static let sm: CGFloat = 6
        /// Cards, primary buttons, fields, icon buttons.
        static let md: CGFloat = 10
        /// Sheets, bubbles.
        static let lg: CGFloat = 14
        /// Segmented controls / tab only. Prefer `Capsule()`.
        static let pill: CGFloat = 999

        /// Square-ish avatars (part of the cell motif).
        static let avatar: CGFloat = sm
        /// The tail corner of a chat bubble.
        static let bubbleTail: CGFloat = xs

        // Legacy names, mapped onto the v2 scale.
        /// Legacy → `xs` (grid tiles).
        static let tile: CGFloat = xs
        /// Legacy → `md`.
        static let card: CGFloat = md
        /// Legacy → `lg`.
        static let bubble: CGFloat = lg
        /// Legacy → `md`.
        static let field: CGFloat = md
    }

    /// Spacing scale: 4 · 8 · 12 · 16 · 24 · 32 · 48. Screen margins 20.
    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let xxxl: CGFloat = 48
        /// Horizontal screen margin.
        static let screen: CGFloat = 20
        /// Default gap between sections (24–32).
        static let section: CGFloat = 28
        /// Gutter of the Nearby grid (gaps read as grid lines).
        static let gridGutter: CGFloat = 2
    }

    /// Letter-spacing (apply with `.tracking`).
    enum Tracking {
        /// Display, -0.03em at 34pt.
        static let display: CGFloat = -1.0
        /// Title, -0.03em at 22pt.
        static let title: CGFloat = -0.66
        /// Headline / names.
        static let tight: CGFloat = -0.4
        /// Mono caps label, 0.18em at 11pt.
        static let label: CGFloat = 2.0
        /// Mono caps micro, 0.16em at 10pt.
        static let micro: CGFloat = 1.6

        /// -0.03em for heavy display type at `size`.
        static func display(for size: CGFloat) -> CGFloat { -0.03 * size }
        /// -0.04em, the wordmark.
        static func wordmark(for size: CGFloat) -> CGFloat { -0.04 * size }
    }
}

extension Color {
    /// Creates an sRGB color from a 24-bit hex literal, e.g. `Color(hex: 0xA78BFF)`.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
