import SwiftUI

// Surfaces. Two kinds only:
//
// 1. Black frosted glass, for things that float over scrolling content:
//    header bars once content scrolls under them, floating action bars,
//    sheets, the composer, chips over photos. `.blackGlass(in:)` (material)
//    or `.stexxGlass(in:)` (iOS 26 liquid glass, for interactive controls).
// 2. Flat ink1 with a 0.5pt line, for content on the plain background
//    (`GlassCard`, rows). Often whitespace + `HairlineDivider` is enough.
//
// Violet appears only as lighting: `.rimLight()` on the one or two hero
// surfaces of a screen. Every glass surface falls back to flat ink1 under
// Reduce Transparency.

// MARK: - Black frosted glass

extension View {
    /// Black frosted glass: ultra-thin material under an ink @ 0.55 veil,
    /// with a 0.5pt top-lit edge. Flat ink1 under Reduce Transparency.
    func blackGlass<S: Shape>(in shape: S) -> some View {
        modifier(BlackGlassModifier(shape: shape))
    }

    /// Liquid glass tinted ink @ 0.5 with a 0.5pt top-lit edge; for
    /// interactive controls. Flat `fallback` under Reduce Transparency.
    /// `tint` is a legacy parameter and is ignored (no coloured glass).
    func stexxGlass<S: Shape>(
        in shape: S,
        tint: Color? = nil,
        interactive: Bool = false,
        fallback: Color = Theme.ink1
    ) -> some View {
        modifier(StexxGlassModifier(shape: shape, interactive: interactive, fallback: fallback))
    }

    /// A 0.5pt top-lit edge (`lineStrong` → `line`) on `shape`.
    func glassEdge<S: Shape>(_ shape: S) -> some View {
        overlay {
            shape.stroke(Theme.glassEdge, lineWidth: 0.5).allowsHitTesting(false)
        }
    }

    /// A flat 0.5pt `line` (or `lineStrong`) border on `shape`.
    func hairlineBorder<S: Shape>(_ shape: S, strong: Bool = false) -> some View {
        overlay {
            shape.stroke(strong ? Theme.lineStrong : Theme.line, lineWidth: 0.5).allowsHitTesting(false)
        }
    }
}

private struct BlackGlassModifier<S: Shape>: ViewModifier {
    let shape: S

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency {
                    shape.fill(Theme.ink1)
                } else {
                    ZStack {
                        shape.fill(.ultraThinMaterial)
                        shape.fill(Theme.ink.opacity(0.55))
                    }
                }
            }
            .glassEdge(shape)
    }
}

private struct StexxGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool
    let fallback: Color

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(shape.fill(fallback))
                .glassEdge(shape)
        } else {
            content
                .glassEffect(Glass.regular.tint(Theme.ink.opacity(0.5)).interactive(interactive), in: shape)
                .glassEdge(shape)
        }
    }
}

// MARK: - Rim light

extension View {
    /// Violet rim light: a 0.75pt stroke on `shape`, `rim` @ 0.9 at the
    /// top-leading corner fading to clear within ~35% of the perimeter.
    /// Use on at most one or two hero surfaces per screen.
    func rimLight<S: InsettableShape>(_ shape: S, lineWidth: CGFloat = 0.75, intensity: Double = 1) -> some View {
        overlay {
            shape
                .strokeBorder(Theme.rimLightGradient(intensity: intensity), lineWidth: lineWidth)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// Rim light on a continuous rounded rect (default radius `md`, 10).
    func rimLight(cornerRadius: CGFloat = Theme.Radius.md, lineWidth: CGFloat = 0.75, intensity: Double = 1) -> some View {
        rimLight(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), lineWidth: lineWidth, intensity: intensity)
    }
}

// MARK: - Cards and dividers

/// A content container. Flat ink1 with a 0.5pt line by default (content on
/// the plain background is not glass); `isGlass: true` for black frosted
/// glass when it floats over content. Optional `rimLit` for a hero card.
/// Name kept from v1; `tint` is a legacy parameter and is ignored.
struct GlassCard<Content: View>: View {
    private let cornerRadius: CGFloat
    private let padding: CGFloat
    private let isGlass: Bool
    private let rimLit: Bool
    private let content: Content

    init(
        cornerRadius: CGFloat = Theme.Radius.md,
        tint: Color? = nil,
        padding: CGFloat = Theme.Spacing.l,
        isGlass: Bool = false,
        rimLit: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.isGlass = isGlass
        self.rimLit = rimLit
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let base = content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
        Group {
            if isGlass {
                base.blackGlass(in: shape)
            } else {
                base
                    .background(shape.fill(Theme.ink1))
                    .hairlineBorder(shape)
            }
        }
        .overlay {
            if rimLit {
                shape.strokeBorder(Theme.rimLightGradient(), lineWidth: 0.75).allowsHitTesting(false)
            }
        }
    }
}

/// 0.5pt hairline divider. Inset it to the text it separates.
struct HairlineDivider: View {
    var leadingInset: CGFloat = 0
    var strong = false

    var body: some View {
        Rectangle()
            .fill(strong ? Theme.lineStrong : Theme.line)
            .frame(height: 0.5)
            .padding(.leading, leadingInset)
            .accessibilityHidden(true)
    }
}

// MARK: - Legacy photo frame

extension View {
    /// Legacy adapter (v1 violet glow frame). Now: clips to a continuous
    /// rounded rect with a 0.5pt hairline; `glow >= 1` adds the violet rim
    /// light (hero surfaces). No bloom, no shadows.
    func glowFrame(cornerRadius: CGFloat, glow: Double = 1) -> some View {
        modifier(GlowFrameModifier(cornerRadius: cornerRadius, glow: glow))
    }
}

/// See `glowFrame(cornerRadius:glow:)`.
struct GlowFrameModifier: ViewModifier {
    let cornerRadius: CGFloat
    let glow: Double

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(Theme.line, lineWidth: 0.5).allowsHitTesting(false)
            }
            .overlay {
                if glow >= 1 {
                    shape.strokeBorder(Theme.rimLightGradient(), lineWidth: 0.75).allowsHitTesting(false)
                }
            }
    }
}

#Preview("Surfaces") {
    VStack(spacing: 24) {
        GlassCard {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Flat card")
                Text(verbatim: "Content on the plain background.").foregroundStyle(Theme.steel)
            }
        }
        GlassCard(isGlass: true, rimLit: true) {
            Text(verbatim: "Black glass, rim lit").font(.stexxHeadline).foregroundStyle(Theme.frost)
        }
        HairlineDivider(leadingInset: 20)
        Text(verbatim: "bar")
            .stexxLabelStyle()
            .frame(maxWidth: .infinity, minHeight: 52)
            .blackGlass(in: .rect(cornerRadius: Theme.Radius.lg))
    }
    .padding(20)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .stexxBackground()
    .preferredColorScheme(.dark)
}
