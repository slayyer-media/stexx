import SwiftUI

// Controls: flat primary/secondary buttons, glass icon buttons, mono-caps
// chips, tags and badges. No gradients, no glows, no violet fills.

// MARK: - Buttons

/// Primary: frost fill, ink text, 17 semibold, height 52, radius 10.
/// Pressed: opacity 0.85 + scale 0.98. Disabled: ink2 fill, slate text.
struct StexxPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StexxButtonBody(configuration: configuration, isPrimary: true)
    }
}

/// Secondary: ink1 fill with a 0.5pt line, frost text, same metrics as primary.
struct StexxSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StexxButtonBody(configuration: configuration, isPrimary: false)
    }
}

extension ButtonStyle where Self == StexxPrimaryButtonStyle {
    static var stexxPrimary: StexxPrimaryButtonStyle { StexxPrimaryButtonStyle() }
}

extension ButtonStyle where Self == StexxSecondaryButtonStyle {
    static var stexxSecondary: StexxSecondaryButtonStyle { StexxSecondaryButtonStyle() }
}

extension View {
    /// Full-width flat primary button (frost fill, ink text). Pair with `WideLabel`.
    func stexxPrimaryButton() -> some View {
        buttonStyle(StexxPrimaryButtonStyle())
    }

    /// Full-width flat secondary button (ink1 + hairline, frost text).
    func stexxSecondaryButton() -> some View {
        buttonStyle(StexxSecondaryButtonStyle())
    }
}

private struct StexxButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let isPrimary: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .headline) private var height: CGFloat = 52

    init(configuration: ButtonStyleConfiguration, isPrimary: Bool) {
        self.configuration = configuration
        self.isPrimary = isPrimary
    }

    var body: some View {
        let pressed = configuration.isPressed
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
        let foreground: Color = !isEnabled ? Theme.slate : (isPrimary ? Theme.ink : Theme.frost)
        let fill: Color = isPrimary ? (isEnabled ? Theme.frost : Theme.ink2) : Theme.ink1

        configuration.label
            .font(.stexxHeadline)
            .foregroundStyle(foreground)
            .tint(foreground)
            .padding(.horizontal, Theme.Spacing.screen)
            .frame(minHeight: height)
            .background(shape.fill(fill))
            .overlay {
                if !isPrimary || !isEnabled {
                    shape.strokeBorder(Theme.line, lineWidth: 0.5)
                }
            }
            .contentShape(shape)
            .opacity(pressed ? 0.85 : 1)
            .scaleEffect(pressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? Motion.fade : Motion.press, value: pressed)
    }
}

/// Label that stretches to fill a full-width button.
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
        .font(.stexxHeadline)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Icon button

/// 36pt icon button: black glass rounded rect (radius 10), steel icon, no
/// rim. `isProminent` makes it frost with an ink icon (e.g. send).
/// Name kept from v1; `tint` is a legacy parameter and is ignored.
struct GlassIconButton: View {
    let systemImage: String
    let label: LocalizedStringKey
    var isProminent = false
    let action: () -> Void

    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 36

    init(
        _ label: LocalizedStringKey,
        systemImage: String,
        isProminent: Bool = false,
        tint: Color = Theme.ice,
        action: @escaping () -> Void
    ) {
        self.label = label
        self.systemImage = systemImage
        self.isProminent = isProminent
        self.action = action
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
        let button = Button(action: action) {
            Label(label, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isProminent ? Theme.ink : Theme.steel)
                .frame(width: side, height: side)
                .contentShape(shape)
        }
        .buttonStyle(PressableButtonStyle(scale: 0.95, haptics: false))

        if isProminent {
            button.background(shape.fill(Theme.frost))
        } else {
            button.stexxGlass(in: shape)
        }
    }
}

// MARK: - Chips and tags

/// Selectable filter chip: radius 4, ink1 fill, 0.5pt line, mono caps 11
/// steel text. Selected: ink2 fill, frost text, ice border.
/// Name kept from v1 (it is no longer glass; fine inside a `GlassEffectContainer`).
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
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous)
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage).imageScale(.small)
                }
                title
                if isLocked {
                    Image(systemName: "lock.fill")
                        .imageScale(.small)
                        .foregroundStyle(Theme.slate)
                }
            }
            .stexxLabelStyle(color: isSelected ? Theme.frost : Theme.steel)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(shape.fill(isSelected ? Theme.ink2 : Theme.ink1))
            .overlay(shape.strokeBorder(isSelected ? Theme.ice.opacity(0.6) : Theme.line, lineWidth: 0.5))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .animation(Motion.animation(Motion.quick, reduceMotion: reduceMotion), value: isSelected)
        .sensoryFeedback(.selection, trigger: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Static tag (interests, attributes): radius 4, ink1, 0.5pt line, mono caps steel.
struct TagChip: View {
    let text: String
    var systemImage: String?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous)
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage).imageScale(.small)
            }
            Text(text)
        }
        .stexxLabelStyle()
        .lineLimit(1)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(shape.fill(Theme.ink1))
        .overlay(shape.strokeBorder(Theme.line, lineWidth: 0.5))
    }
}

// MARK: - Badge

/// Small mono-caps badge, radius 4. `.solid` (default): ink text on frost,
/// for unread counts and "NEW". `.outline`: steel text on ink1 + line, for
/// quieter meta ("MAIN", "CANCEL ANYTIME"). Name kept from v1 (was a violet gem).
struct XXBadge: View {
    enum Style: Sendable {
        case solid
        case outline
    }

    let text: Text
    var style: Style

    @ScaledMetric(relativeTo: .caption2) private var horizontalPadding: CGFloat = 5
    @ScaledMetric(relativeTo: .caption2) private var verticalPadding: CGFloat = 2.5

    init(_ text: LocalizedStringKey, style: Style = .solid) {
        self.text = Text(text)
        self.style = style
    }

    init(verbatim: String, style: Style = .solid) {
        self.text = Text(verbatim: verbatim)
        self.style = style
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous)
        text
            .monospacedDigit()
            .stexxLabelStyle(.micro, color: style == .solid ? Theme.ink : Theme.steel)
            .lineLimit(1)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(shape.fill(style == .solid ? Theme.frost : Theme.ink1))
            .overlay {
                if style == .outline { shape.strokeBorder(Theme.line, lineWidth: 0.5) }
            }
            .fixedSize()
    }
}

/// v2 name for `XXBadge`.
typealias StexxBadge = XXBadge

#Preview("Controls") {
    ScrollView {
        VStack(spacing: 20) {
            HStack(spacing: 8) {
                GlassChip("All", isSelected: true) {}
                GlassChip("Online", systemImage: "circle.fill", isSelected: false) {}
                GlassChip("Filters", isSelected: false, isLocked: true) {}
            }
            HStack(spacing: 8) {
                TagChip(text: "Hiking")
                TagChip(text: "Coffee", systemImage: "xmark")
            }
            HStack(spacing: 12) {
                GlassIconButton("Favorite", systemImage: "star") {}
                GlassIconButton("Send", systemImage: "arrow.up", isProminent: true) {}
                XXBadge(verbatim: "12")
                XXBadge("Main", style: .outline)
            }
            Button {} label: { WideLabel("Get started") }.stexxPrimaryButton()
            Button {} label: { WideLabel("Maybe later") }.stexxSecondaryButton()
            Button {} label: { WideLabel("Disabled") }.stexxPrimaryButton().disabled(true)
        }
        .padding(20)
    }
    .stexxBackground()
    .preferredColorScheme(.dark)
}
