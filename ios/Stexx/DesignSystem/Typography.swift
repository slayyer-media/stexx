import SwiftUI

/// Type ramp. Stexx uses SF Pro (the system font) with tight tracking for
/// headlines, which reads close to the bold geometric wordmark, and keeps
/// Dynamic Type support everywhere except the fixed-size wordmark.
extension Font {
    static let stexxLargeTitle = Font.system(.largeTitle, design: .default, weight: .bold)
    static let stexxTitle = Font.system(.title2, design: .default, weight: .bold)
    static let stexxHeadline = Font.system(.headline, design: .default, weight: .semibold)
    static let stexxBody = Font.system(.body)
    static let stexxCaption = Font.system(.caption, design: .default, weight: .medium)

    /// Bold display face used by the wordmark and big numbers.
    static func stexxDisplay(_ size: CGFloat) -> Font {
        .system(size: size, weight: .bold, design: .default)
    }
}

/// Small uppercase label used above groups of content.
struct SectionLabel: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .tracking(1.2)
            .foregroundStyle(Theme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
