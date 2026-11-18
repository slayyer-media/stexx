import SwiftUI

/// Shows a profile's primary photo, or a tasteful generated placeholder
/// (violet-family gradient + silhouette) when there is none. The placeholder
/// is deterministic per profile so the grid doesn't reshuffle on reload.
struct ProfilePhotoView: View {
    let profile: Profile
    var photoIndex = 0

    var body: some View {
        ZStack {
            PhotoPlaceholder(seed: profile.id)
            if let url = profile.photos[safe: photoIndex]?.url {
                AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color.clear
                    }
                }
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }
}

/// Generated stand-in for a missing photo.
struct PhotoPlaceholder: View {
    let seed: String

    private static let palettes: [(Color, Color)] = [
        (Color(hex: 0x3F2C80), Color(hex: 0x16131F)),
        (Color(hex: 0x6A3A7A), Color(hex: 0x1A1220)),
        (Color(hex: 0x2E3A7A), Color(hex: 0x12131D)),
        (Color(hex: 0x7A3A5C), Color(hex: 0x1C1118)),
        (Color(hex: 0x4B2F6E), Color(hex: 0x0F0E14)),
        (Color(hex: 0x30506E), Color(hex: 0x11151B)),
    ]

    var body: some View {
        let palette = Self.palettes[Int(seed.stableHash % UInt64(Self.palettes.count))]
        ZStack {
            LinearGradient(colors: [palette.0, palette.1], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "person.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.white.opacity(0.14))
                .scaleEffect(0.62, anchor: .bottom)
        }
    }
}

/// Round avatar for lists and toolbars.
struct AvatarView: View {
    let profile: Profile
    var size: CGFloat = 52
    var showsOnline = true

    var body: some View {
        ProfilePhotoView(profile: profile)
            .frame(width: size, height: size)
            .clipShape(.circle)
            .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 0.5))
            .overlay(alignment: .bottomTrailing) {
                if showsOnline && profile.isOnline {
                    OnlineDot(size: max(10, size * 0.24))
                }
            }
    }
}

/// Green "online now" indicator with a dark ring so it reads on photos.
struct OnlineDot: View {
    var size: CGFloat = 10

    var body: some View {
        Circle()
            .fill(Theme.online)
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(Theme.background, lineWidth: size * 0.2))
            .shadow(color: Theme.online.opacity(0.6), radius: size * 0.4)
            .accessibilityLabel("Online")
    }
}

/// Small static tag, e.g. interests on a profile.
struct TagChip: View {
    let text: String
    var systemImage: String?

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage).font(.caption2)
            }
            Text(text)
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(Theme.surface, in: .capsule)
        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
}

/// Wrapping horizontal layout for chips and tags.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(maxWidth: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(maxWidth: bounds.width, subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                proposal: .unspecified
            )
        }
    }

    private func arrange(maxWidth: CGFloat, subviews: Subviews) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            widest = max(widest, x + size.width)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (origins, CGSize(width: widest, height: y + rowHeight))
    }
}

extension String {
    /// A hash that is stable across launches (unlike `hashValue`), used for
    /// picking deterministic placeholder colors. Not for security.
    var stableHash: UInt64 {
        unicodeScalars.reduce(5381) { ($0 &* 33) ^ UInt64($1.value) }
    }
}

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

#Preview("Profile visuals") {
    VStack(spacing: 24) {
        HStack(spacing: 8) {
            ForEach(MockData.profiles.prefix(3)) { profile in
                ProfilePhotoView(profile: profile)
                    .frame(width: 110, height: 140)
                    .clipShape(.rect(cornerRadius: Theme.Radius.tile))
            }
        }
        HStack {
            AvatarView(profile: MockData.profiles[0])
            AvatarView(profile: MockData.profiles[1], size: 36)
        }
        FlowLayout {
            ForEach(MockData.profiles[0].tags, id: \.self) { TagChip(text: $0) }
        }
        .padding()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(GlowBackground())
    .preferredColorScheme(.dark)
}
