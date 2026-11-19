import SwiftUI
import UIKit

/// Shows a profile's primary photo, or a generated placeholder (cool ink
/// gradient + silhouette) when there is none. The placeholder is
/// deterministic per profile so the grid doesn't reshuffle on reload.
struct ProfilePhotoView: View {
    let profile: Profile
    var photoIndex = 0

    var body: some View {
        ZStack {
            PhotoPlaceholder(seed: profile.id)
            if let url = profile.photos[safe: photoIndex]?.url {
                ProfilePhotoImage(url: url)
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }
}

/// A remote profile photo through `ProfilePhotoLoader`: no URL cache (nothing
/// in `Library/Caches`), decoded copies in memory only. Use this, never
/// `AsyncImage`, for any photo of a person.
struct ProfilePhotoImage: View {
    let url: URL
    private let loader: ProfilePhotoLoader

    @State private var image: UIImage?

    init(url: URL, loader: ProfilePhotoLoader = .shared) {
        self.url = url
        self.loader = loader
        // Already loaded this session: show it at once, no fade or flash.
        _image = State(initialValue: loader.cached(url))
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                Color.clear
            }
        }
        .task(id: url) {
            if let cached = loader.cached(url) {
                image = cached
                return
            }
            image = nil
            let loaded = await loader.image(for: url)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { image = loaded }
        }
    }
}

/// Generated stand-in for a missing photo: cool steel/ink gradients only.
struct PhotoPlaceholder: View {
    let seed: String

    private static let palettes: [(Color, Color)] = [
        (Color(hex: 0x1B2430), Color(hex: 0x0A0C10)),
        (Color(hex: 0x222A35), Color(hex: 0x0B0D11)),
        (Color(hex: 0x1A2028), Color(hex: 0x08090C)),
        (Color(hex: 0x262C36), Color(hex: 0x0D0F13)),
        (Color(hex: 0x1E2733), Color(hex: 0x090B0E)),
        (Color(hex: 0x2A2F38), Color(hex: 0x0E1014)),
    ]

    var body: some View {
        let palette = Self.palettes[Int(seed.stableHash % UInt64(Self.palettes.count))]
        ZStack {
            LinearGradient(colors: [palette.0, palette.1], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "person.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(Theme.frost.opacity(0.10))
                .scaleEffect(0.62, anchor: .bottom)
        }
    }
}

/// Square-ish avatar (radius 6, part of the cell motif) with a 0.5pt line
/// and an optional static online dot at the bottom-trailing corner.
struct AvatarView: View {
    let profile: Profile
    var size: CGFloat = 52
    var showsOnline = true
    var cornerRadius: CGFloat = Theme.Radius.avatar

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ProfilePhotoView(profile: profile)
            .frame(width: size, height: size)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Theme.line, lineWidth: 0.5))
            .overlay(alignment: .bottomTrailing) {
                if showsOnline && profile.isOnline {
                    OnlineDot().offset(x: 3, y: 3)
                }
            }
    }
}

/// "Online now": a static 6pt `online` dot with a 1.5pt ink ring so it reads
/// on any photo. No pulse, no glow.
struct OnlineDot: View {
    var size: CGFloat = 6

    var body: some View {
        Circle()
            .fill(Theme.online)
            .frame(width: size, height: size)
            .padding(1.5)
            .background(Circle().fill(Theme.ink))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Online")
    }
}

/// Legacy adapter (v1 pulsing glow): now the static `OnlineDot`. `size` is
/// ignored so every call site gets the 6pt dot.
struct OnlineGlow: View {
    var size: CGFloat = 6

    var body: some View {
        OnlineDot()
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
    .stexxBackground()
    .preferredColorScheme(.dark)
}
