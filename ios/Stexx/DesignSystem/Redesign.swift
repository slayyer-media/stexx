import SwiftUI

// Shared API for the UI redesign. Feature screens build on these names; the
// design-system pass may restyle their implementation but keeps every
// signature below stable.

// MARK: - Motion

/// Motion tokens. Always go through `Motion.animation(_:reduceMotion:)` (or
/// check Reduce Motion yourself) so motion collapses to a cross-fade or none.
enum Motion {
    /// Springy open for cards and profile expansion.
    static let cardSpring: Animation = .spring(response: 0.44, dampingFraction: 0.76)
    /// Slight overshoot for chat bubbles landing.
    static let bubbleLand: Animation = .spring(response: 0.38, dampingFraction: 0.6)
    /// Quick UI state changes (chips, toggles, selection).
    static let snappy: Animation = .snappy(duration: 0.24)
    /// Press-down squish for tappable tiles and buttons.
    static let press: Animation = .spring(response: 0.26, dampingFraction: 0.62)
    /// The neutral fade everything collapses to under Reduce Motion.
    static let fade: Animation = .easeInOut(duration: 0.18)

    /// Returns `base`, or a short ease when Reduce Motion is on.
    static func animation(_ base: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? fade : base
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

/// Clips to a continuous rounded rect, adds a faint top sheen, a two-line
/// glass rim (specular top-leading edge fading through violet) and one violet
/// shadow cast by the rim only, so the photo itself is never re-rendered for
/// the glow and translucent cards stay translucent. No blurs.
struct GlowFrameModifier: ViewModifier {
    let cornerRadius: CGFloat
    let glow: Double

    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder
    func body(content: Content) -> some View {
        let strength = min(max(glow, 0), 2)
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let innerShape = RoundedRectangle(cornerRadius: max(cornerRadius - 1.5, 0), style: .continuous)
        let increased = contrast == .increased

        content
            .overlay {
                // Light catching the top of the glass.
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0.09), location: 0),
                        .init(color: .white.opacity(0), location: 0.32),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)
            }
            .clipShape(shape)
            .overlay {
                shape
                    .strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(increased ? 0.75 : 0.45), location: 0),
                                .init(color: Theme.edgeGlow.opacity(0.5 + 0.2 * min(strength, 1.5)), location: 0.42),
                                .init(color: Theme.edgeGlow.opacity(0.16), location: 0.78),
                                .init(color: .white.opacity(increased ? 0.3 : 0.14), location: 1),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: strength > 1 ? 1.5 : 1
                    )
                    .allowsHitTesting(false)
            }
            .overlay {
                // Inner hairline gives the rim a sense of glass thickness.
                innerShape
                    .strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5)
                    .padding(1.5)
                    .allowsHitTesting(false)
            }
            .background {
                if strength > 0 {
                    shape
                        .stroke(Theme.edgeGlow.opacity(0.5 * min(strength, 1.4)), lineWidth: 1)
                        .shadow(color: Theme.edgeGlow.opacity(0.42 * min(strength, 1.5)), radius: 5 + 7 * strength)
                }
            }
    }
}

// MARK: - Online glow

/// "Online now" as a softly pulsing green glow: a bright core with a halo
/// that swells and fades every couple of seconds. The pulse is a keyframe
/// animation on scale/opacity of a gradient (no blur), so many can run in a
/// grid. Under Reduce Motion the halo is drawn static.
struct OnlineGlow: View {
    var size: CGFloat = 10

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let size = self.size
        OnlineGlowCore(size: size)
            .background {
                if reduceMotion {
                    OnlineGlowHalo(size: size)
                        .scaleEffect(0.85)
                        .opacity(0.6)
                } else {
                    OnlineGlowHalo(size: size)
                        .keyframeAnimator(initialValue: OnlineGlowPulse(), repeating: true) { halo, pulse in
                            halo
                                .scaleEffect(CGFloat(0.45 + 0.8 * pulse.progress))
                                .opacity(1 - pulse.progress)
                        } keyframes: { _ in
                            KeyframeTrack(\.progress) {
                                LinearKeyframe(1.0, duration: 1.6, timingCurve: .easeOut)
                                LinearKeyframe(1.0, duration: 0.6)
                            }
                        }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Online")
    }
}

private struct OnlineGlowPulse {
    var progress: Double = 0
}

/// The solid center shared by `OnlineGlow` and `OnlineDot`: a lit mint core
/// with a dark ring so it reads on any photo, and one soft green shadow.
struct OnlineGlowCore: View {
    var size: CGFloat

    var body: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [Color(hex: 0xB4FFE0), Theme.online],
                    center: UnitPoint(x: 0.35, y: 0.32),
                    startRadius: 0,
                    endRadius: size * 0.6
                )
            )
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(Theme.background.opacity(0.85), lineWidth: max(1, size * 0.16)))
            .shadow(color: Theme.online.opacity(0.65), radius: size * 0.45)
    }
}

private struct OnlineGlowHalo: View {
    var size: CGFloat

    var body: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [Theme.online.opacity(0.6), Theme.online.opacity(0.22), Theme.online.opacity(0)],
                    center: .center,
                    startRadius: size * 0.25,
                    endRadius: size * 1.3
                )
            )
            .frame(width: size * 2.6, height: size * 2.6)
            .allowsHitTesting(false)
    }
}

// MARK: - Badge

/// Small violet capsule badge (counts, "New", "Featured"): the "xx" violet
/// as a glossy gem with a light rim and a soft glow.
struct XXBadge: View {
    let text: Text

    @ScaledMetric(relativeTo: .caption2) private var horizontalPadding: CGFloat = 7
    @ScaledMetric(relativeTo: .caption2) private var verticalPadding: CGFloat = 3

    init(_ text: LocalizedStringKey) { self.text = Text(text) }
    init(verbatim: String) { self.text = Text(verbatim: verbatim) }

    var body: some View {
        text
            .font(.caption2.weight(.heavy))
            .tracking(0.5)
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(.white)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background {
                ZStack {
                    Capsule().fill(Theme.accentGradient)
                    Capsule().fill(
                        LinearGradient(
                            colors: [.white.opacity(0.28), .white.opacity(0)],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
                }
                .shadow(color: Theme.edgeGlow.opacity(0.55), radius: 5)
            }
            .overlay {
                Capsule().strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.6), .white.opacity(0.05), Theme.violetBright.opacity(0.35)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.75
                )
            }
            .fixedSize()
    }
}

// MARK: - Pressable button style

/// A plain button style for tappable tiles and cards: squishes slightly with
/// a spring and gives a soft haptic on press. Under Reduce Motion it dims
/// instead of scaling. Use `.buttonStyle(.pressable)`.
struct PressableButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    var haptics = true

    func makeBody(configuration: Configuration) -> some View {
        PressableButtonBody(configuration: configuration, scale: scale, haptics: haptics)
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    /// Springy press-down with a soft haptic; see `PressableButtonStyle`.
    static var pressable: PressableButtonStyle { PressableButtonStyle() }
}

private struct PressableButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let scale: CGFloat
    let haptics: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let pressed = configuration.isPressed
        let haptics = self.haptics
        configuration.label
            .contentShape(.rect)
            .scaleEffect(pressed && !reduceMotion ? scale : 1)
            .opacity(pressed && reduceMotion ? 0.72 : 1)
            .animation(reduceMotion ? Motion.fade : Motion.press, value: pressed)
            .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.6), trigger: pressed) { old, new in
                haptics && !old && new
            }
    }
}

#Preview("Redesign tokens") {
    VStack(spacing: 28) {
        HStack(spacing: 12) {
            ForEach(MockData.profiles.prefix(2)) { profile in
                ProfilePhotoView(profile: profile)
                    .frame(width: 130, height: 170)
                    .glowFrame(cornerRadius: Theme.Radius.tile, glow: profile.id == MockData.profiles[0].id ? 1.5 : 1)
                    .overlay(alignment: .topLeading) {
                        OnlineGlow(size: 9).padding(10)
                    }
            }
        }
        HStack(spacing: 10) {
            XXBadge("New")
            XXBadge(verbatim: "12")
            OnlineGlow()
        }
        Button {} label: {
            Text(verbatim: "Pressable").font(.stexxName).tracking(Theme.Tracking.tight)
                .padding()
        }
        .buttonStyle(.pressable)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(GlowBackground())
    .preferredColorScheme(.dark)
}
