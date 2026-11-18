import SwiftUI

/// The signature Stexx backdrop: near-black with soft violet and plum light
/// drifting slowly behind the glass.
///
/// Battery notes: the glow is drawn with a single `Canvas` (three radial
/// gradients, no blur passes) and redrawn at most 15 times per second. The
/// animation pauses entirely when Reduce Motion is on or the scene is not
/// active, leaving a static frame.
struct GlowBackground: View {
    /// Scales the brightness of the glow. 1 is the default; use less behind
    /// dense content (forms, chat) and more on hero screens.
    var intensity: Double = 1

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15.0, paused: isPaused)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas(opaque: true) { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.background))
                for blob in Self.blobs {
                    blob.draw(in: &context, size: size, time: isPaused ? 0 : time, intensity: intensity)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var isPaused: Bool {
        reduceMotion || scenePhase != .active
    }

    private static let blobs: [Blob] = [
        Blob(color: Theme.indigo, anchor: UnitPoint(x: 0.22, y: 0.18), drift: CGSize(width: 0.10, height: 0.06),
             radius: 0.62, opacity: 0.55, period: 23, phase: 0),
        Blob(color: Theme.violet, anchor: UnitPoint(x: 0.78, y: 0.46), drift: CGSize(width: 0.08, height: 0.10),
             radius: 0.50, opacity: 0.30, period: 31, phase: 2.1),
        Blob(color: Theme.plum, anchor: UnitPoint(x: 0.35, y: 0.88), drift: CGSize(width: 0.12, height: 0.05),
             radius: 0.58, opacity: 0.38, period: 27, phase: 4.2),
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

        func draw(in context: inout GraphicsContext, size: CGSize, time: TimeInterval, intensity: Double) {
            let angle = (time / period) * 2 * .pi + phase
            let center = CGPoint(
                x: (anchor.x + drift.width * cos(angle)) * size.width,
                y: (anchor.y + drift.height * sin(angle * 0.8)) * size.height
            )
            let r = max(size.width, size.height) * radius
            let alpha = min(1, opacity * intensity)
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
    func stexxBackground(intensity: Double = 1) -> some View {
        self
            .scrollContentBackground(.hidden)
            .background { GlowBackground(intensity: intensity) }
    }
}

#Preview("Glow") {
    GlowBackground()
}

#Preview("Glow – dim") {
    GlowBackground(intensity: 0.5)
}
