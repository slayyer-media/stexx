import SwiftUI

// The signature motif: the 500 m cell. Stexx snaps everyone's location to a
// grid cell; the UI echoes it with viewfinder-style corner ticks around hero
// surfaces, the top-leading tick lit in rim violet.

/// Which corners of a cell carry a tick.
struct CellCorners: OptionSet, Sendable {
    let rawValue: Int

    static let topLeading = CellCorners(rawValue: 1 << 0)
    static let topTrailing = CellCorners(rawValue: 1 << 1)
    static let bottomLeading = CellCorners(rawValue: 1 << 2)
    static let bottomTrailing = CellCorners(rawValue: 1 << 3)
    static let all: CellCorners = [.topLeading, .topTrailing, .bottomLeading, .bottomTrailing]
}

/// L-shaped corner ticks at the corners of the rect it is given.
struct CellCornerTicks: Shape {
    var arm: CGFloat = 6
    var corners: CellCorners = .all

    func path(in rect: CGRect) -> Path {
        let a = max(0, min(arm, rect.width / 2, rect.height / 2))
        var path = Path()
        func tick(_ corner: CGPoint, _ dx: CGFloat, _ dy: CGFloat) {
            path.move(to: CGPoint(x: corner.x, y: corner.y + dy * a))
            path.addLine(to: corner)
            path.addLine(to: CGPoint(x: corner.x + dx * a, y: corner.y))
        }
        if corners.contains(.topLeading) { tick(CGPoint(x: rect.minX, y: rect.minY), 1, 1) }
        if corners.contains(.topTrailing) { tick(CGPoint(x: rect.maxX, y: rect.minY), -1, 1) }
        if corners.contains(.bottomLeading) { tick(CGPoint(x: rect.minX, y: rect.maxY), 1, -1) }
        if corners.contains(.bottomTrailing) { tick(CGPoint(x: rect.maxX, y: rect.maxY), -1, -1) }
        return path
    }
}

/// Four corner ticks (6pt arms, 0.75pt, frost @ 0.35) filling its frame,
/// with the top-leading tick lit `rim` when `lit`. Decorative only.
struct CellFrame: View {
    var arm: CGFloat = 6
    var lineWidth: CGFloat = 0.75
    var lit = true

    var body: some View {
        let style = StrokeStyle(lineWidth: lineWidth, lineCap: .square)
        ZStack {
            CellCornerTicks(arm: arm, corners: lit ? [.topTrailing, .bottomLeading, .bottomTrailing] : .all)
                .stroke(Theme.frost.opacity(0.35), style: style)
            if lit {
                CellCornerTicks(arm: arm, corners: .topLeading)
                    .stroke(Theme.rim, style: style)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    /// Draws the cell's corner ticks around this view. `outset` > 0 places
    /// them outside the frame (default 4pt); pass a negative value to inset
    /// them on top of a photo (e.g. -8). Make sure no ancestor clips the
    /// outset ticks. Use on hero surfaces only: profile hero photo, your
    /// profile photo, logo tile, paywall card, empty states.
    func cellCorners(outset: CGFloat = 4, arm: CGFloat = 6, lineWidth: CGFloat = 0.75, lit: Bool = true) -> some View {
        overlay {
            CellFrame(arm: arm, lineWidth: lineWidth, lit: lit)
                .padding(-outset)
        }
    }
}

#Preview("Cell") {
    VStack(spacing: 40) {
        Theme.ink1
            .frame(width: 160, height: 200)
            .clipShape(.rect(cornerRadius: Theme.Radius.xs))
            .cellCorners()
        Theme.ink2
            .frame(width: 160, height: 120)
            .cellCorners(outset: -8, lit: false)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .stexxBackground()
}
