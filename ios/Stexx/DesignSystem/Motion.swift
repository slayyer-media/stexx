import SwiftUI

/// Motion tokens. Subtle: ease-outs of 0.2–0.28s or springs with
/// dampingFraction >= 0.9. No bounce, no pulsing, no ambient animation.
/// Always go through `Motion.animation(_:reduceMotion:)` (or check Reduce
/// Motion yourself) so motion collapses to a short fade.
enum Motion {
    /// Quick UI state changes: chips, toggles, selection (0.2s ease-out).
    static let quick: Animation = .easeOut(duration: 0.2)
    /// Default transition for appearing content (0.26s ease-out).
    static let standard: Animation = .easeOut(duration: 0.26)
    /// Settling spring for cards and sheets; critically damped feel, no overshoot.
    static let settle: Animation = .spring(response: 0.34, dampingFraction: 0.92)
    /// The neutral fade everything collapses to under Reduce Motion.
    static let fade: Animation = .easeOut(duration: 0.18)

    // Legacy names, mapped onto the v2 rules (no bounce).
    /// Legacy → `settle`.
    static let cardSpring: Animation = settle
    /// Legacy → `standard` (no landing bounce).
    static let bubbleLand: Animation = standard
    /// Legacy → `quick`.
    static let snappy: Animation = quick
    /// Press feedback for buttons and tiles (fast, no overshoot).
    static let press: Animation = .easeOut(duration: 0.14)

    /// Returns `base`, or a short fade when Reduce Motion is on.
    static func animation(_ base: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? fade : base
    }
}

// MARK: - Pressable button style

/// Plain button style for tappable tiles and cards: dims to 0.85 and scales
/// to `scale` on press, with an optional soft haptic. Under Reduce Motion it
/// only dims. Use `.buttonStyle(.pressable)`.
struct PressableButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.98
    var haptics = true

    func makeBody(configuration: Configuration) -> some View {
        PressableButtonBody(configuration: configuration, scale: scale, haptics: haptics)
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    /// Subtle press-down with a soft haptic; see `PressableButtonStyle`.
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
            .opacity(pressed ? 0.85 : 1)
            .animation(reduceMotion ? Motion.fade : Motion.press, value: pressed)
            .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.5), trigger: pressed) { old, new in
                haptics && !old && new
            }
    }
}
