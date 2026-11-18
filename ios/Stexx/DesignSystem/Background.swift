import SwiftUI

/// The Stexx backdrop: solid ink with ONE static violet lens flare.
///
/// - A soft radial ellipse of `flare` (~0.10) near the top-trailing corner,
///   partly off-screen.
/// - A thin diagonal streak through it (`rim` @ 0.18, 1pt high, blurred
///   2pt, ~140pt wide), like light catching the edge of glass.
/// - A very faint cool steel radial (#1B2430 @ 0.35) at the bottom-leading.
///
/// Fully static: one `Canvas`, drawn only when the size changes. No drift,
/// no breathing, no scroll reaction. Reduce Transparency turns the flare off.
struct GlowBackground: View {
    /// Scales the flare (1 = default). Clamped so the flare never exceeds
    /// 0.12 opacity. Lower it behind dense content.
    var intensity: Double = 1
    /// Legacy parameter, ignored: the background no longer reacts to scroll.
    var scrollOffset: CGFloat = 0

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let showsFlare = !reduceTransparency
        let level = min(max(intensity, 0), 1.2) * (contrast == .increased ? 0.6 : 1)

        Canvas(opaque: true) { context, size in
            Self.render(in: &context, size: size, level: level, showsFlare: showsFlare)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static func render(in context: inout GraphicsContext, size: CGSize, level: Double, showsFlare: Bool) {
        let bounds = CGRect(origin: .zero, size: size)
        context.fill(Path(bounds), with: .color(Theme.ink))

        // Cool steel radial, bottom-leading.
        let coolCenter = CGPoint(x: size.width * 0.05, y: size.height * 1.02)
        let coolRadius = max(size.width, size.height) * 0.6
        context.fill(
            Path(bounds),
            with: .radialGradient(
                Gradient(colors: [Theme.coolLight.opacity(0.35), Theme.coolLight.opacity(0)]),
                center: coolCenter,
                startRadius: 0,
                endRadius: coolRadius
            )
        )

        guard showsFlare, level > 0 else { return }

        // The lens flare: a soft ellipse, partly off-screen top-trailing.
        let flareCenter = CGPoint(x: size.width * 0.9, y: size.height * 0.02)
        let flareWidth = size.width * 1.1
        let flareHeight = size.width * 0.8
        let flareAlpha = min(0.10 * level, 0.12)
        var flareContext = context
        flareContext.translateBy(x: flareCenter.x, y: flareCenter.y)
        flareContext.scaleBy(x: 1, y: flareHeight / flareWidth)
        flareContext.fill(
            Path(ellipseIn: CGRect(x: -flareWidth / 2, y: -flareWidth / 2, width: flareWidth, height: flareWidth)),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: Theme.flare.opacity(flareAlpha), location: 0),
                    .init(color: Theme.flare.opacity(flareAlpha * 0.4), location: 0.4),
                    .init(color: Theme.flare.opacity(0), location: 1),
                ]),
                center: .zero,
                startRadius: 0,
                endRadius: flareWidth / 2
            )
        )

        // The streak: a thin diagonal line of rim light through the flare.
        let streakCenter = CGPoint(x: size.width * 0.78, y: size.height * 0.075)
        let streakAlpha = min(0.18 * level, 0.22)
        var streak = context
        streak.addFilter(.blur(radius: 2))
        streak.translateBy(x: streakCenter.x, y: streakCenter.y)
        streak.rotate(by: .degrees(-24))
        streak.fill(
            Path(roundedRect: CGRect(x: -70, y: -0.5, width: 140, height: 1), cornerRadius: 0.5),
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: Theme.rim.opacity(0), location: 0),
                    .init(color: Theme.rim.opacity(streakAlpha), location: 0.5),
                    .init(color: Theme.rim.opacity(0), location: 1),
                ]),
                startPoint: CGPoint(x: -70, y: 0),
                endPoint: CGPoint(x: 70, y: 0)
            )
        )
    }
}

extension View {
    /// Places the Stexx background behind a view (typically a `ScrollView`,
    /// `List` or `Form`) and hides the default scroll background.
    /// `scrollOffset` is a legacy parameter and is ignored.
    func stexxBackground(intensity: Double = 1, scrollOffset: CGFloat = 0) -> some View {
        self
            .scrollContentBackground(.hidden)
            .background { GlowBackground(intensity: intensity) }
    }
}

#Preview("Background") {
    GlowBackground()
}
