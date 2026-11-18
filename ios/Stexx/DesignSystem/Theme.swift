import SwiftUI

/// Central design tokens for Stexx. Dark-only: the app always renders in a
/// dark color scheme with violet light bleeding through liquid glass.
enum Theme {
    // MARK: Base

    /// Near-black with a hint of blue, matching the logo background.
    static let background = Color(hex: 0x0A0A0E)
    /// Slightly raised dark surface for non-glass content (bubbles, rows).
    static let backgroundRaised = Color(hex: 0x15141B)

    // MARK: Brand

    /// Primary accent, used for prominent buttons and own chat bubbles.
    static let violet = Color(hex: 0x8B5CF6)
    /// Lighter violet for the wordmark "xx", highlights and icons.
    static let violetBright = Color(hex: 0xB89CFF)
    /// Deeper violet for filled controls; white text on it stays above 4.5:1.
    static let violetDeep = Color(hex: 0x7442E0)
    /// Deep violet used in the background glow.
    static let indigo = Color(hex: 0x3F2C80)
    /// Warm plum used in the background glow (the mauve in the icon).
    static let plum = Color(hex: 0x7A3A6E)

    // MARK: Semantic

    static let online = Color(hex: 0x3EE6A0)
    static let danger = Color(hex: 0xFF5A6E)
    static let warning = Color(hex: 0xFFC56B)

    // MARK: Text

    static let textPrimary = Color.white.opacity(0.94)
    static let textSecondary = Color.white.opacity(0.62)
    static let textTertiary = Color.white.opacity(0.40)

    // MARK: Surfaces

    static let surface = Color.white.opacity(0.06)
    static let surfaceStrong = Color.white.opacity(0.10)
    static let hairline = Color.white.opacity(0.10)

    // MARK: Gradients

    static var accentGradient: LinearGradient {
        LinearGradient(
            colors: [Color(hex: 0x9D6BFF), Color(hex: 0x7442E0)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var markGradient: LinearGradient {
        LinearGradient(
            colors: [Color.white.opacity(0.96), violetBright],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Scrim used at the bottom of photo tiles so text stays legible.
    static var photoScrim: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0), location: 0),
                .init(color: .black.opacity(0.35), location: 0.45),
                .init(color: .black.opacity(0.75), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: Metrics

    enum Radius {
        static let tile: CGFloat = 18
        static let card: CGFloat = 26
        static let bubble: CGFloat = 20
        static let field: CGFloat = 22
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }
}

extension Color {
    /// Creates an sRGB color from a 24-bit hex literal, e.g. `Color(hex: 0x8B5CF6)`.
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
