import AppKit
import SwiftUI

/// Scanning mascot: a slowly turning faceted sphere whose tiles pick up the six brand
/// swatches, and the odd glint. The progress ring around it is drawn by the caller.
///
/// Reduce Motion: one still frame (no rotation, no twinkle); the counters below still
/// show that work is happening. It also stops turning while the window is hidden.
struct MirrorBall: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var windowVisible = true

    /// Degrees of spin per second.
    private let spin = 16.0
    private let bands = 14

    var body: some View {
        TimelineView(.animation(paused: reduceMotion || !windowVisible)) { ctx in
            let t = reduceMotion ? 1.3 : ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600)
            Canvas { g, size in draw(&g, size: size, t: t) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { note in
            guard let window = note.object as? NSWindow, !(window is NSPanel) else { return }
            windowVisible = window.occlusionState.contains(.visible)
        }
        .accessibilityHidden(true)
    }

    private func draw(_ g: inout GraphicsContext, size: CGSize, t: Double) {
        let side = min(size.width, size.height)
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let R = side * 0.27
        let dark = scheme == .dark

        // Sphere body.
        let ball = Path(ellipseIn: CGRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2))
        g.fill(ball, with: .radialGradient(
            Gradient(colors: dark ? [Color(white: 0.20), Color(white: 0.05)] : [Color(white: 0.80), Color(white: 0.52)]),
            center: CGPoint(x: c.x - R * 0.3, y: c.y - R * 0.35), startRadius: 0, endRadius: R * 1.4))

        // Facets.
        let light = normalize((-0.45, 0.55, 0.70))
        let rot = t * spin
        let latStep = 180.0 / Double(bands)
        for i in 0..<bands {
            let lat0 = -90 + Double(i) * latStep
            let lat1 = lat0 + latStep
            let latC = (lat0 + lat1) / 2
            let count = max(6, Int((36 * cos(rad(latC))).rounded()))
            let lonStep = 360.0 / Double(count)
            for j in 0..<count {
                let lon0 = Double(j) * lonStep + rot + (i.isMultiple(of: 2) ? 0 : lonStep / 2)
                let lonC = lon0 + lonStep / 2
                let n = (cos(rad(latC)) * sin(rad(lonC)), sin(rad(latC)), cos(rad(latC)) * cos(rad(lonC)))
                guard n.2 > 0.04 else { continue }  // back hemisphere

                // Quad corners, pulled toward the center to leave grout lines.
                let corners = [(lat0, lon0), (lat0, lon0 + lonStep), (lat1, lon0 + lonStep), (lat1, lon0)]
                    .map { project($0.0, $0.1, R, c) }
                let center = project(latC, lonC, R, c)
                var quad = Path()
                for (k, p) in corners.enumerated() {
                    let q = CGPoint(x: center.x + (p.x - center.x) * 0.84, y: center.y + (p.y - center.y) * 0.84)
                    if k == 0 { quad.move(to: q) } else { quad.addLine(to: q) }
                }
                quad.closeSubpath()

                let diffuse = max(0, n.0 * light.0 + n.1 * light.1 + n.2 * light.2)
                let facetID = UInt64(i * 97 + j)
                let jitter = unit(facetID)
                // Sheen hue depends on the facet's orientation, not its identity, so the
                // color field stays put while the tiles slide through it.
                let field = (0.72 + n.0 * 0.28 + n.1 * 0.22 + jitter * 0.06 + 1).truncatingRemainder(dividingBy: 1)
                let glint = !reduceMotion && unit(facetID &* 31 &+ UInt64(t * 3)) < 0.025
                let color: Color
                if glint {
                    color = .white
                } else {
                    // Lit grey, tinted toward one of the six brand swatches.
                    let swatch = Tokens.Spectrum.rgb(Int(field * 6), dark: dark)
                    let lum = (dark ? 0.20 : 0.56) + diffuse * (dark ? 0.72 : 0.40)
                    let k = (dark ? 0.50 : 0.42) + jitter * 0.2
                    func mix(_ c: Double) -> Double { min(1, lum * (1 - k) + c * lum * 1.15 * k) }
                    color = Color(.sRGB, red: mix(swatch.0), green: mix(swatch.1), blue: mix(swatch.2))
                }
                g.fill(quad, with: .color(color.opacity(0.35 + 0.65 * n.2)))
            }
        }

        // Specular bloom + rim.
        g.fill(ball, with: .radialGradient(
            Gradient(colors: [Color.white.opacity(dark ? 0.28 : 0.35), .clear]),
            center: CGPoint(x: c.x - R * 0.38, y: c.y - R * 0.42), startRadius: 0, endRadius: R * 0.75))
        g.stroke(ball, with: .color(.white.opacity(dark ? 0.14 : 0.35)), lineWidth: 1)

        // Sparkles.
        let sparkles: [(dx: Double, dy: Double, phase: Double, scale: Double)] = [
            (-0.52, -0.50, 0.0, 1.0), (0.30, -0.78, 2.1, 0.7), (-0.80, 0.18, 4.0, 0.55), (0.62, 0.40, 5.3, 0.6),
        ]
        for s in sparkles {
            let a = reduceMotion ? (s.phase == 0 ? 1 : 0) : pow(max(0, sin(t * 1.7 + s.phase)), 6)
            guard a > 0.02 else { continue }
            let p = CGPoint(x: c.x + R * s.dx, y: c.y + R * s.dy)
            let len = R * 0.32 * s.scale
            g.drawLayer { layer in
                layer.opacity = a
                layer.addFilter(.shadow(color: .white.opacity(0.9), radius: 6))
                layer.fill(star(at: p, length: len), with: .color(.white))
            }
        }
    }

    // MARK: Geometry helpers

    private func project(_ lat: Double, _ lon: Double, _ R: CGFloat, _ c: CGPoint) -> CGPoint {
        CGPoint(x: c.x + R * CGFloat(cos(rad(lat)) * sin(rad(lon))),
                y: c.y - R * CGFloat(sin(rad(lat))))
    }

    private func star(at p: CGPoint, length: CGFloat) -> Path {
        let w = length * 0.12
        var path = Path()
        path.move(to: CGPoint(x: p.x, y: p.y - length))
        path.addLine(to: CGPoint(x: p.x + w, y: p.y - w))
        path.addLine(to: CGPoint(x: p.x + length, y: p.y))
        path.addLine(to: CGPoint(x: p.x + w, y: p.y + w))
        path.addLine(to: CGPoint(x: p.x, y: p.y + length))
        path.addLine(to: CGPoint(x: p.x - w, y: p.y + w))
        path.addLine(to: CGPoint(x: p.x - length, y: p.y))
        path.addLine(to: CGPoint(x: p.x - w, y: p.y - w))
        path.closeSubpath()
        return path
    }

    private func rad(_ d: Double) -> Double { d * .pi / 180 }

    private func normalize(_ v: (Double, Double, Double)) -> (Double, Double, Double) {
        let l = (v.0 * v.0 + v.1 * v.1 + v.2 * v.2).squareRoot()
        return (v.0 / l, v.1 / l, v.2 / l)
    }

    /// Stable pseudo-random value in 0..<1.
    private func unit(_ x: UInt64) -> Double {
        var z = x &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z % 10_000) / 10_000
    }
}
