import SwiftUI

// Liquid Glass building blocks. Glass is reserved for the "control layer":
// cards that float over the glow, buttons, chips and bars. Dense content
// (photo grids, message bubbles) stays solid for legibility and performance.
// Every glass surface here falls back to a solid fill under Reduce
// Transparency (see `stexxGlass(in:tint:interactive:fallback:)`).

extension View {
    /// Liquid glass in `shape`, or a solid `fallback` fill with a hairline
    /// edge when Reduce Transparency is on.
    func stexxGlass<S: Shape>(
        in shape: S,
        tint: Color? = nil,
        interactive: Bool = false,
        fallback: Color = Theme.backgroundRaised
    ) -> some View {
        modifier(StexxGlassModifier(shape: shape, tint: tint, interactive: interactive, fallback: fallback))
    }
}

private struct StexxGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color?
    let interactive: Bool
    let fallback: Color

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background {
                    ZStack {
                        shape.fill(fallback)
                        if let tint { shape.fill(tint) }
                    }
                }
                .overlay(shape.stroke(Color.white.opacity(0.16), lineWidth: 1).allowsHitTesting(false))
        } else {
            content.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        }
    }
}

/// A rounded liquid-glass container for grouped content.
struct GlassCard<Content: View>: View {
    private let cornerRadius: CGFloat
    private let tint: Color?
    private let padding: CGFloat
    private let content: Content

    init(
        cornerRadius: CGFloat = Theme.Radius.card,
        tint: Color? = nil,
        padding: CGFloat = Theme.Spacing.l + 4,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.tint = tint
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .stexxGlass(in: .rect(cornerRadius: cornerRadius), tint: tint)
    }
}

/// A circular glass button with an SF Symbol.
struct GlassIconButton: View {
    let systemImage: String
    let label: LocalizedStringKey
    var isProminent = false
    var tint: Color = Theme.violet
    let action: () -> Void

    init(
        _ label: LocalizedStringKey,
        systemImage: String,
        isProminent: Bool = false,
        tint: Color = Theme.violet,
        action: @escaping () -> Void
    ) {
        self.label = label
        self.systemImage = systemImage
        self.isProminent = isProminent
        self.tint = tint
        self.action = action
    }

    var body: some View {
        let button = Button(action: action) {
            Label(label, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 24, height: 24)
        }
        .buttonBorderShape(.circle)
        .controlSize(.large)

        if isProminent {
            button.buttonStyle(.glassProminent).tint(tint)
        } else {
            button.buttonStyle(.glass)
        }
    }
}

/// A selectable glass capsule used for quick filters and multi-select options.
/// Place several inside a `GlassEffectContainer` so they blend together.
struct GlassChip: View {
    let title: Text
    var systemImage: String?
    var isSelected: Bool
    var isLocked = false
    let action: () -> Void

    init(
        _ title: LocalizedStringKey,
        systemImage: String? = nil,
        isSelected: Bool,
        isLocked: Bool = false,
        action: @escaping () -> Void
    ) {
        self.init(Text(title), systemImage: systemImage, isSelected: isSelected, isLocked: isLocked, action: action)
    }

    init(
        _ title: Text,
        systemImage: String? = nil,
        isSelected: Bool,
        isLocked: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isSelected = isSelected
        self.isLocked = isLocked
        self.action = action
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                title
                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(Theme.violetBright)
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isSelected ? Color.white : Theme.textSecondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .overlay {
                // Violet edge glow on the selected chip. Lives inside the
                // label so it moves with the interactive glass.
                Capsule()
                    .strokeBorder(Theme.violetBright.opacity(0.75), lineWidth: 1)
                    .shadow(color: Theme.edgeGlow.opacity(0.85), radius: 6)
                    .opacity(isSelected ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .stexxGlass(
            in: .capsule,
            tint: isSelected ? Theme.violet.opacity(0.55) : nil,
            interactive: true,
            fallback: isSelected ? Theme.violetDeep : Theme.backgroundRaised
        )
        .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: isSelected)
        .sensoryFeedback(.selection, trigger: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension View {
    /// Full-width violet liquid-glass call-to-action with a soft violet
    /// glow underneath (hidden while disabled).
    func stexxPrimaryButton() -> some View {
        modifier(PrimaryButtonModifier())
    }

    /// Full-width neutral liquid-glass button.
    func stexxSecondaryButton() -> some View {
        self
            .buttonStyle(.glass)
            .controlSize(.large)
    }
}

private struct PrimaryButtonModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .buttonStyle(.glassProminent)
            .tint(Theme.violetDeep)
            .controlSize(.large)
            .background {
                // Static glow pooled under the button (rendered once).
                Capsule()
                    .fill(Theme.accentGradient)
                    .blur(radius: 14)
                    .opacity(isEnabled ? 0.55 : 0)
                    .padding(.horizontal, 18)
                    .offset(y: 6)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

/// Convenience label that stretches to fill a full-width button.
struct WideLabel: View {
    let title: LocalizedStringKey
    var systemImage: String?

    init(_ title: LocalizedStringKey, systemImage: String? = nil) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Group {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
        .font(.body.weight(.semibold))
        .frame(maxWidth: .infinity)
    }
}

#Preview("Glass components") {
    ScrollView {
        VStack(spacing: 20) {
            GlassCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Glass card").font(.stexxHeadline)
                    Text("Floats over the glow.").foregroundStyle(Theme.textSecondary)
                }
            }
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    GlassChip("All", isSelected: true) {}
                    GlassChip("Online", systemImage: "circle.fill", isSelected: false) {}
                    GlassChip("Filters", isSelected: false, isLocked: true) {}
                }
            }
            HStack(spacing: 12) {
                GlassIconButton("Favorite", systemImage: "star") {}
                GlassIconButton("Send", systemImage: "arrow.up", isProminent: true) {}
            }
            Button {} label: { WideLabel("Get started") }.stexxPrimaryButton()
            Button {} label: { WideLabel("Maybe later") }.stexxSecondaryButton()
            Button {} label: { WideLabel("Disabled") }.stexxPrimaryButton().disabled(true)
        }
        .padding()
    }
    .background(GlowBackground())
    .preferredColorScheme(.dark)
}
