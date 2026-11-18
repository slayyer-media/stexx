import SwiftUI

// Shared API for the UI redesign. Feature screens build on these names; the
// design-system pass may restyle their implementation but keeps every
// signature below stable.

// MARK: - Motion

/// Motion tokens. Always go through `Motion.animation(_:reduceMotion:)` (or
/// check Reduce Motion yourself) so motion collapses to a cross-fade or none.
enum Motion {
    /// Springy open for cards and profile expansion.
    static let cardSpring: Animation = .spring(response: 0.42, dampingFraction: 0.78)
    /// Slight overshoot for chat bubbles landing.
    static let bubbleLand: Animation = .spring(response: 0.36, dampingFraction: 0.62)
    /// Quick UI state changes (chips, toggles, selection).
    static let snappy: Animation = .snappy(duration: 0.24)

    /// Returns `base`, or a short ease when Reduce Motion is on.
    static func animation(_ base: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : base
    }
}

// MARK: - Type

extension Font {
    /// Heavy, tight display type for screen headers.
    static let stexxHero = Font.system(.largeTitle, design: .default, weight: .black)
    /// Heavy name type for profile headers and featured tiles.
    static let stexxName = Font.system(.title2, design: .default, weight: .heavy)
    /// Heavy name type for small tiles and rows.
    static let stexxNameSmall = Font.system(.subheadline, design: .default, weight: .heavy)
}

extension Theme {
    /// Letter-spacing for display type (apply with `.tracking`).
    enum Tracking {
        static let display: CGFloat = -0.9
        static let tight: CGFloat = -0.4
    }

    /// Glow color for photo edges and accents.
    static let edgeGlow = Color(hex: 0x9D6BFF)

    /// Fill for the user's own chat bubbles.
    static var ownBubbleGradient: LinearGradient {
        LinearGradient(
            colors: [Color(hex: 0xA67CFF), Color(hex: 0x7442E0), Color(hex: 0x5B2FC4)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - Photo frame

extension View {
    /// Soft glass rim plus a violet edge glow around a photo or card.
    /// `glow` scales the glow (0 = rim only, 1 = default, >1 = featured).
    func glowFrame(cornerRadius: CGFloat, glow: Double = 1) -> some View {
        modifier(GlowFrameModifier(cornerRadius: cornerRadius, glow: glow))
    }
}

struct GlowFrameModifier: ViewModifier {
    let cornerRadius: CGFloat
    let glow: Double

    func body(content: Content) -> some View {
        content
            .clipShape(.rect(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.35), Theme.edgeGlow.opacity(0.5), Color.white.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .shadow(color: Theme.edgeGlow.opacity(0.35 * glow), radius: 12 * glow)
    }
}

// MARK: - Online glow

/// "Online now" as a softly pulsing green glow. Static under Reduce Motion.
struct OnlineGlow: View {
    var size: CGFloat = 10

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(Theme.online)
            .frame(width: size, height: size)
            .background {
                Circle()
                    .fill(Theme.online.opacity(0.45))
                    .scaleEffect(pulsing ? 2.4 : 1.2)
                    .opacity(pulsing ? 0 : 0.8)
                    .blur(radius: size * 0.25)
            }
            .shadow(color: Theme.online.opacity(0.7), radius: size * 0.5)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
                    pulsing = true
                }
            }
            .accessibilityLabel("Online")
    }
}

// MARK: - Badge

/// Small violet capsule badge (counts, "New", "Featured").
struct XXBadge: View {
    let text: Text

    init(_ text: LocalizedStringKey) { self.text = Text(text) }
    init(verbatim: String) { self.text = Text(verbatim: verbatim) }

    var body: some View {
        text
            .font(.caption2.weight(.heavy))
            .tracking(0.4)
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Theme.accentGradient, in: .capsule)
            .shadow(color: Theme.edgeGlow.opacity(0.5), radius: 6)
    }
}
