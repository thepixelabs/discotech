import AppKit

/// The Neon theme's static "deep space" surface for a CGContext canvas: two faint nebula
/// glows (pink-violet from the top left, acid-cyan from the bottom right, the brand's
/// split signature) and a sparse, fixed field of star dust. Drawn once into a canvas's
/// cached bitmap — nothing animates, so it costs nothing at rest.
///
/// The glows fade out toward the top and bottom edges (`edgeFade`), so the canvas meets
/// the flat `chartSurface` of the legend and hover strip above and below it without a seam.
/// Any canvas may adopt it: `if SpaceBackdrop.isActive { SpaceBackdrop.draw(in:rect:dark:background:) }`
/// right after filling its background.
enum SpaceBackdrop {
    /// Only the Neon theme has a space surface.
    static var isActive: Bool { Theme.current == .neon }

    /// Nebula strength at its centre.
    static func nebulaAlpha(dark: Bool) -> (violet: CGFloat, acid: CGFloat) {
        dark ? (0.13, 0.075) : (0.07, 0.05)
    }
    /// Points over which the nebula fades to the flat surface at the top and bottom edges.
    static let edgeFade: CGFloat = 56
    /// About one star per this many square points.
    static let starDensity: CGFloat = 2600

    static func draw(in ctx: CGContext, rect: CGRect, dark: Bool, background: CGColor) {
        guard rect.width > 1, rect.height > 1 else { return }
        let space = CGColorSpace(name: CGColorSpace.sRGB)
        let (violetA, acidA) = nebulaAlpha(dark: dark)
        let violet = NSColor.hex(dark ? 0xBE48E0 : 0xB020D0)
        let pink = NSColor.hex(dark ? 0xFF1493 : 0xD4107A)
        let acid = NSColor.hex(dark ? 0x39FF14 : 0x00C020)
        let cyan = NSColor.hex(dark ? 0x00F0FF : 0x0090B0)
        let reach = max(rect.width, rect.height)

        func glow(center: CGPoint, radius: CGFloat, inner: NSColor, outer: NSColor, alpha: CGFloat) {
            guard let g = CGGradient(colorsSpace: space,
                                     colors: [inner.withAlphaComponent(alpha).cgColor,
                                              outer.withAlphaComponent(alpha * 0.45).cgColor,
                                              outer.withAlphaComponent(0).cgColor] as CFArray,
                                     locations: [0, 0.4, 1]) else { return }
            ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
        }

        ctx.saveGState()
        ctx.clip(to: rect)
        glow(center: CGPoint(x: rect.minX + rect.width * 0.12, y: rect.maxY - rect.height * 0.22),
             radius: reach * 0.62, inner: pink.blended(withFraction: 0.5, of: violet) ?? violet, outer: violet, alpha: violetA)
        glow(center: CGPoint(x: rect.maxX - rect.width * 0.1, y: rect.minY + rect.height * 0.18),
             radius: reach * 0.55, inner: acid, outer: cyan, alpha: acidA)

        // Fade back to the flat surface at the top and bottom edges.
        if let fade = CGGradient(colorsSpace: space, colors: [background, background.copy(alpha: 0) ?? background] as CFArray,
                                 locations: [0, 1]) {
            let f = min(edgeFade, rect.height / 3)
            ctx.drawLinearGradient(fade, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.maxY - f), options: [])
            ctx.drawLinearGradient(fade, start: CGPoint(x: rect.midX, y: rect.minY), end: CGPoint(x: rect.midX, y: rect.minY + f), options: [])
        }

        // Star dust: a fixed pseudo-random field (same stars at the same size every time).
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> CGFloat {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            return CGFloat(seed % 100_000) / 100_000
        }
        let count = Int(rect.width * rect.height / starDensity)
        let starInk: NSColor = dark ? .white : NSColor.hex(0x6A2C8A)
        for _ in 0..<count {
            let p = CGPoint(x: rect.minX + next() * rect.width, y: rect.minY + next() * rect.height)
            let r = 0.35 + next() * 0.55
            let a = (dark ? 0.12 : 0.08) + next() * (dark ? 0.32 : 0.14)
            ctx.setFillColor(starInk.withAlphaComponent(a).cgColor)
            ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        }
        ctx.restoreGState()
    }
}
