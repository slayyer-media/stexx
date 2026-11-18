import SwiftUI

/// The signature Stexx backdrop: near-black with soft violet and plum light
/// drifting slowly behind the glass, breathing gently and reacting to scroll.
///
/// - Drift: four radial blobs (indigo, violet, plum and a brighter "xx"
///   violet) orbit their anchors on slow Lissajous paths.
/// - Breathing: the whole glow swells by a few percent on a ~9 s cycle and
///   each blob pulses its own radius slightly.
/// - Scroll: blobs move at different depths (parallax), the glow dims a
///   little as you scroll into content and warms toward plum; pulling down
///   past the top brightens it.
///
/// Battery notes: one `Canvas` (radial gradients only, no blur passes)
/// redrawn at most 15 times per second. Under Reduce Motion it is a static
/// frame with no parallax; when the scene is not active the timeline pauses
/// on its last frame.
struct GlowBackground: View {
    /// Scales the brightness of the glow. 1 is the default; use less behind
    /// dense content (forms, chat) and more on hero screens.
    var intensity: Double = 1
    /// Vertical scroll offset of the content above, in points (positive when
    /// scrolled down). The glow shifts gently with it. 0 = no reaction.
    var scrollOffset: CGFloat = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let isStatic = reduceMotion
        let scroll = isStatic ? 0 : Double(scrollOffset)
        // Increased Contrast: keep the glow but quieter behind text.
        let level = intensity * (contrast == .increased ? 0.7 : 1)

        TimelineView(.animation(minimumInterval: 1.0 / 15.0, paused: isPaused)) { timeline in
            let time = isStatic ? 0 : timeline.date.timeIntervalSinceReferenceDate
            Canvas(opaque: true) { context, size in
                Self.render(in: &context, size: size, time: time, intensity: level, scroll: scroll)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var isPaused: Bool {
        reduceMotion || scenePhase != .active
    }

    // MARK: Rendering

    private static func render(
        in context: inout GraphicsContext,
        size: CGSize,
        time: Double,
        intensity: Double,
        scroll: Double
    ) {
        let bounds = Path(CGRect(origin: .zero, size: size))
        context.fill(bounds, with: .color(Theme.background))

        // 0 at the top, 1 about a screen down, negative when pulled down.
        let progress: Double = min(max(scroll / 700, -0.4), 1)
        let breath: Double = 1 + 0.07 * sin(time * 2 * .pi / 9)
        let level = intensity * breath * (1 - 0.16 * progress)
        let longest = max(size.width, size.height)
        // Parallax travel, clamped so long lists don't push the glow away.
        let travel: Double = min(max(scroll, -240), 900)

        for blob in blobs {
            blob.draw(in: &context, size: size, longest: longest, time: time,
                      level: level, progress: progress, travel: travel)
        }

        // Soft vignette, like the dark falloff around the app icon.
        let center = CGPoint(x: size.width * 0.5, y: size.height * 0.45)
        context.fill(
            bounds,
            with: .radialGradient(
                Gradient(colors: [Theme.background.opacity(0), Theme.background.opacity(0.5)]),
                center: center,
                startRadius: longest * 0.35,
                endRadius: longest * 0.85
            )
        )
    }

    private static let blobs: [Blob] = [
        Blob(color: Theme.indigo, anchor: UnitPoint(x: 0.22, y: 0.16), drift: CGSize(width: 0.10, height: 0.06),
             radius: 0.62, opacity: 0.55, period: 23, phase: 0, depth: 0.10, scrollResponse: -0.3),
        Blob(color: Theme.violet, anchor: UnitPoint(x: 0.80, y: 0.44), drift: CGSize(width: 0.08, height: 0.10),
             radius: 0.50, opacity: 0.30, period: 31, phase: 2.1, depth: 0.16, scrollResponse: 0),
        Blob(color: Theme.plum, anchor: UnitPoint(x: 0.32, y: 0.90), drift: CGSize(width: 0.12, height: 0.05),
             radius: 0.58, opacity: 0.38, period: 27, phase: 4.2, depth: 0.06, scrollResponse: 0.45),
        // The "xx" violet: smaller, brighter and more restless.
        Blob(color: Theme.edgeGlow, anchor: UnitPoint(x: 0.55, y: 0.34), drift: CGSize(width: 0.16, height: 0.12),
             radius: 0.30, opacity: 0.17, period: 19, phase: 1.3, depth: 0.22, scrollResponse: 0.2),
    ]

    private struct Blob: Sendable {
        let color: Color
        /// Resting center, in unit coordinates of the canvas.
        let anchor: UnitPoint
        /// How far the center wanders, as a fraction of the canvas size.
        let drift: CGSize
        /// Radius as a fraction of the canvas' longest side.
        let radius: CGFloat
        let opacity: Double
        /// Seconds per full orbit.
        let period: Double
        let phase: Double
        /// Points moved per point scrolled (parallax depth).
        let depth: Double
        /// Relative opacity change once scrolled a screen down.
        let scrollResponse: Double

        func draw(
            in context: inout GraphicsContext,
            size: CGSize,
            longest: CGFloat,
            time: Double,
            level: Double,
            progress: Double,
            travel: Double
        ) {
            let angle: Double = (time / period) * 2 * .pi + phase
            let dx = CGFloat(cos(angle))
            let dy = CGFloat(sin(angle * 0.8 + phase))
            let lift = CGFloat(travel * depth)
            let center = CGPoint(
                x: (anchor.x + drift.width * dx) * size.width,
                y: (anchor.y + drift.height * dy) * size.height - lift
            )
            let pulse = CGFloat(1 + 0.05 * sin(angle * 1.7))
            let r: CGFloat = longest * radius * pulse
            let alpha = min(1, max(0, opacity * level * (1 + scrollResponse * max(progress, 0))))
            let gradient = Gradient(stops: [
                .init(color: color.opacity(alpha), location: 0),
                .init(color: color.opacity(alpha * 0.35), location: 0.45),
                .init(color: color.opacity(0), location: 1),
            ])
            context.fill(
                Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                with: .radialGradient(gradient, center: center, startRadius: 0, endRadius: r)
            )
        }
    }
}

extension View {
    /// Places the Stexx glow behind a view (typically a `ScrollView`, `List`
    /// or `Form`) and hides the default scroll background.
    func stexxBackground(intensity: Double = 1, scrollOffset: CGFloat = 0) -> some View {
        self
            .scrollContentBackground(.hidden)
            .background { GlowBackground(intensity: intensity, scrollOffset: scrollOffset) }
    }
}

#Preview("Glow") {
    GlowBackground()
}

#Preview("Glow – dim") {
    GlowBackground(intensity: 0.5)
}

#Preview("Glow – scrolled") {
    GlowBackground(scrollOffset: 500)
}
