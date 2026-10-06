import AppKit

/// The one highlight language shared by the CGContext canvases (Floor, Layers, and the
/// Ball). Callers hand it the item's outline as a `CGPath`, the item's own fill colour and
/// which states apply; it paints the highlight over whatever is already drawn. Colours and
/// stroke style follow `Theme.current` (Ocean, Sunset and Forest draw like Studio, in
/// their own accent):
///
/// | State | Studio / Iridescent | Neon |
/// |---|---|---|
/// | `hovered` | glow in the item's hue, a slight lift, a 2 pt inner ring sweeping hue → accent (Iridescent: a hue-shifted holographic sweep) over a 1 pt contrast hairline | glow, lift, a 1.25 pt inner hairline sweeping the signature pink → violet → acid over a 0.75 pt contrast hairline |
/// | `selected` | a 2 pt accent ring 2 pt outside the shape, faint halo, 1 pt inner text-colour hairline | a 1.25 pt violet → acid hairline 2 pt outside, faint halo, 0.75 pt inner text-colour hairline |
/// | `ancestor` | a 1.25 pt rim in the item's hue, 1 pt outside | a 1 pt rim 1 pt outside, fading along the diagonal |
/// | `emphasized` | a glow and a 1.5 pt inner ring in the item's hue | a glow and a 1.25 pt inner hairline brightening along the diagonal |
///
/// States combine (`[.hovered, .selected]` paints the selection ring outside and the hover
/// ring inside). Nothing here animates: callers cross-fade through `opacity`, instantly
/// under Reduce Motion, so nothing runs at rest.
/// Under Increase Contrast every glow and gradient is replaced by solid, thicker strokes:
/// text colour for hover and lineage, the accent for selection and emphasis (all themes).
enum CanvasHighlight {
    struct State: OptionSet, Hashable {
        let rawValue: UInt8
        static let hovered = State(rawValue: 1 << 0)
        static let selected = State(rawValue: 1 << 1)
        static let ancestor = State(rawValue: 1 << 2)
        static let emphasized = State(rawValue: 1 << 3)
    }

    // MARK: Metrics

    /// How far outside the path a highlight can paint (glow radius plus rings). Pad dirty
    /// rects, clips or hit slop by this much.
    static let outset: CGFloat = 18

    /// Stroke widths and glow radii of one theme's highlight style.
    struct Metrics {
        let hoverRingWidth: CGFloat
        let hoverGlowBlur: CGFloat
        let selectedRingWidth: CGFloat
        let selectedRingOffset: CGFloat
        let ancestorRimWidth: CGFloat
        let ancestorRimOffset: CGFloat
        let emphasisRingWidth: CGFloat
        let emphasisGlowBlur: CGFloat
        /// The backing line under the hover ring, so it reads on any fill.
        let contrastHairline: CGFloat
    }

    static func metrics(for theme: Theme) -> Metrics {
        switch theme {
        case .studio, .iridescent, .ocean, .sunset, .forest:
            return Metrics(hoverRingWidth: 2, hoverGlowBlur: 14, selectedRingWidth: 2, selectedRingOffset: 2,
                           ancestorRimWidth: 1.25, ancestorRimOffset: 1, emphasisRingWidth: 1.5, emphasisGlowBlur: 10,
                           contrastHairline: 1)
        case .neon:
            return Metrics(hoverRingWidth: 1.25, hoverGlowBlur: 12, selectedRingWidth: 1.25, selectedRingOffset: 2,
                           ancestorRimWidth: 1, ancestorRimOffset: 1, emphasisRingWidth: 1.25, emphasisGlowBlur: 9,
                           contrastHairline: 0.75)
        }
    }

    static var metrics: Metrics { metrics(for: Theme.current) }
    static var hoverRingWidth: CGFloat { metrics.hoverRingWidth }
    static var hoverGlowBlur: CGFloat { metrics.hoverGlowBlur }
    static var selectedRingWidth: CGFloat { metrics.selectedRingWidth }
    static var selectedRingOffset: CGFloat { metrics.selectedRingOffset }
    static var ancestorRimWidth: CGFloat { metrics.ancestorRimWidth }
    static var ancestorRimOffset: CGFloat { metrics.ancestorRimOffset }
    static var emphasisRingWidth: CGFloat { metrics.emphasisRingWidth }
    static var emphasisGlowBlur: CGFloat { metrics.emphasisGlowBlur }

    static var systemIncreaseContrast: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["DISCOTECH_INCREASE_CONTRAST"] != nil { return true }
        #endif
        return NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }
    /// DEBUG: `DISCOTECH_INCREASE_CONTRAST=1` / `DISCOTECH_REDUCE_MOTION=1` force these on
    /// for screenshots (canvases that read them through here follow).
    static var systemReduceMotion: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["DISCOTECH_REDUCE_MOTION"] != nil { return true }
        #endif
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// True when `appearance` is one of the high-contrast variants (the DEBUG `*-hc`
    /// appearances), so a canvas can pass `increaseContrast` without reading the system.
    static func isHighContrast(_ appearance: NSAppearance) -> Bool {
        let match = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
        return match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua
    }

    // MARK: Drawing

    /// Paints `state` for the shape `path` (in `ctx`'s current coordinates).
    /// - Parameters:
    ///   - tint: the item's own fill; its hue drives the glow and the start of the ring
    ///     gradient. `nil` or a colourless fill (Free, "Everything else") uses the accent.
    ///   - dark: the canvas is in dark mode.
    ///   - opacity: 0...1 for the caller's cross-fade.
    static func draw(_ state: State, path: CGPath, tint: NSColor?, dark: Bool, in ctx: CGContext,
                     increaseContrast: Bool = systemIncreaseContrast, opacity: CGFloat = 1) {
        guard !state.isEmpty, opacity > 0.001, !path.isEmpty else { return }
        let colors = Colors(tint: tint, dark: dark, increaseContrast: increaseContrast)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let faded = opacity < 0.999
        if faded {
            ctx.setAlpha(opacity)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        if state.contains(.ancestor) { drawAncestor(path, colors, ctx, increaseContrast) }
        if state.contains(.emphasized) { drawEmphasized(path, colors, ctx, increaseContrast) }
        if state.contains(.selected) { drawSelected(path, colors, ctx, increaseContrast) }
        if state.contains(.hovered) { drawHovered(path, colors, ctx, increaseContrast) }
        if faded { ctx.endTransparencyLayer() }
    }

    /// Convenience for the common case: a rounded rectangle.
    static func draw(_ state: State, rect: CGRect, radius: CGFloat, tint: NSColor?, dark: Bool, in ctx: CGContext,
                     increaseContrast: Bool = systemIncreaseContrast, opacity: CGFloat = 1) {
        guard rect.width > 0.5, rect.height > 0.5 else { return }
        let r = max(0, min(radius, min(rect.width, rect.height) / 2))
        draw(state, path: CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil), tint: tint,
             dark: dark, in: ctx, increaseContrast: increaseContrast, opacity: opacity)
    }

    // MARK: States

    private static func drawHovered(_ path: CGPath, _ c: Colors, _ ctx: CGContext, _ hc: Bool) {
        if hc {
            // One thick text-colour ring: the accent stays reserved for selection.
            ring(path, inside: true, offset: 0, width: 3, ctx) { ctx.setFillColor(c.text); ctx.fill($0) }
            return
        }
        let m = c.metrics
        let neon = c.theme == .neon
        glow(path, color: c.glow.copy(alpha: neon ? (c.dark ? 0.6 : 0.42) : (c.dark ? 0.8 : 0.6)) ?? c.glow, blur: m.hoverGlowBlur, ctx)
        // Lift: brighten the item a touch.
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: 1, alpha: neon ? (c.dark ? 0.07 : 0.14) : (c.dark ? 0.08 : 0.16)))
        ctx.fillPath()
        ctx.restoreGState()
        // Contrast hairline under the ring, then the ring's sweep.
        ring(path, inside: true, offset: m.hoverRingWidth, width: m.contrastHairline, ctx) {
            ctx.setFillColor(c.dark ? CGColor(gray: 0, alpha: neon ? 0.4 : 0.35) : CGColor(gray: 1, alpha: neon ? 0.8 : 0.75))
            ctx.fill($0)
        }
        ring(path, inside: true, offset: 0, width: m.hoverRingWidth, ctx) { _ in gradient(path, c.hoverStops, ctx) }
    }

    private static func drawSelected(_ path: CGPath, _ c: Colors, _ ctx: CGContext, _ hc: Bool) {
        let m = c.metrics
        if hc {
            ring(path, inside: false, offset: m.selectedRingOffset, width: 3, ctx) { ctx.setFillColor(c.accent); ctx.fill($0) }
            ring(path, inside: true, offset: 0, width: 1.5, ctx) { ctx.setFillColor(c.text); ctx.fill($0) }
            return
        }
        if c.theme == .neon {
            glow(path, color: c.accent.copy(alpha: c.dark ? 0.38 : 0.24) ?? c.accent, blur: 7, ctx)
            ring(path, inside: false, offset: m.selectedRingOffset, width: m.selectedRingWidth, ctx) { _ in
                gradient(path, c.selectionStops, ctx)
            }
            ring(path, inside: true, offset: 0, width: m.contrastHairline, ctx) {
                ctx.setFillColor(c.text.copy(alpha: 0.6) ?? c.text)
                ctx.fill($0)
            }
            return
        }
        glow(path, color: c.accent.copy(alpha: c.dark ? 0.4 : 0.28) ?? c.accent, blur: 8, ctx)
        ring(path, inside: false, offset: m.selectedRingOffset, width: m.selectedRingWidth, ctx) {
            ctx.setFillColor(c.accent)
            ctx.fill($0)
        }
        ring(path, inside: true, offset: 0, width: 1, ctx) {
            ctx.setFillColor(c.text.copy(alpha: 0.9) ?? c.text)
            ctx.fill($0)
        }
    }

    private static func drawAncestor(_ path: CGPath, _ c: Colors, _ ctx: CGContext, _ hc: Bool) {
        let m = c.metrics
        if hc || c.theme != .neon {
            let color = hc ? (c.text.copy(alpha: 0.85) ?? c.text) : (c.glow.copy(alpha: c.dark ? 0.75 : 0.7) ?? c.glow)
            ring(path, inside: false, offset: m.ancestorRimOffset, width: hc ? 1.5 : m.ancestorRimWidth, ctx) {
                ctx.setFillColor(color)
                ctx.fill($0)
            }
            return
        }
        let strong = c.glow.copy(alpha: c.dark ? 0.85 : 0.8) ?? c.glow
        let faint = c.glow.copy(alpha: c.dark ? 0.25 : 0.3) ?? c.glow
        ring(path, inside: false, offset: m.ancestorRimOffset, width: m.ancestorRimWidth, ctx) { _ in
            gradient(path, [(0, strong), (1, faint)], ctx)
        }
    }

    private static func drawEmphasized(_ path: CGPath, _ c: Colors, _ ctx: CGContext, _ hc: Bool) {
        let m = c.metrics
        if hc {
            ring(path, inside: true, offset: 0, width: 2, ctx) { ctx.setFillColor(c.accent); ctx.fill($0) }
            return
        }
        if c.theme == .neon {
            glow(path, color: c.glow.copy(alpha: c.dark ? 0.55 : 0.4) ?? c.glow, blur: m.emphasisGlowBlur, ctx)
            ring(path, inside: true, offset: 0, width: m.emphasisRingWidth, ctx) { _ in gradient(path, c.hueStops, ctx) }
            return
        }
        glow(path, color: c.glow.copy(alpha: c.dark ? 0.7 : 0.5) ?? c.glow, blur: m.emphasisGlowBlur, ctx)
        ring(path, inside: true, offset: 0, width: m.emphasisRingWidth, ctx) {
            ctx.setFillColor(c.glow)
            ctx.fill($0)
        }
    }

    // MARK: Primitives

    /// Sets up a clip to the band `offset ..< offset + width` inside or outside `path`
    /// and calls `paint` with a box covering the band (fill it, or draw a gradient).
    private static func ring(_ path: CGPath, inside: Bool, offset: CGFloat, width: CGFloat, _ ctx: CGContext,
                             paint: (CGRect) -> Void) {
        let outer = path.copy(strokingWithWidth: (offset + width) * 2, lineCap: .round, lineJoin: .round, miterLimit: 10)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if inside {
            ctx.addPath(path)
            ctx.clip()
        } else {
            clipOutside(path, ctx)
        }
        ctx.addPath(outer)
        ctx.clip()
        if offset > 0 {
            // Knock out the first `offset` points next to the edge.
            let inner = path.copy(strokingWithWidth: offset * 2, lineCap: .round, lineJoin: .round, miterLimit: 10)
            ctx.addRect(outer.boundingBoxOfPath.insetBy(dx: -2, dy: -2))
            ctx.addPath(inner)
            ctx.clip(using: .evenOdd)
        }
        paint(outer.boundingBoxOfPath.insetBy(dx: -2, dy: -2))
    }

    /// Glow outside the shape only (the shape's own pixels are untouched).
    private static func glow(_ path: CGPath, color: CGColor, blur: CGFloat, _ ctx: CGContext) {
        ctx.saveGState()
        clipOutside(path, ctx, pad: blur * 2)
        ctx.setShadow(offset: .zero, blur: blur, color: color)
        ctx.addPath(path)
        ctx.setFillColor(color.copy(alpha: 1) ?? color)
        ctx.fillPath()
        ctx.restoreGState()
    }

    private static func clipOutside(_ path: CGPath, _ ctx: CGContext, pad: CGFloat = outset) {
        ctx.addRect(path.boundingBoxOfPath.insetBy(dx: -pad - 4, dy: -pad - 4))
        ctx.addPath(path)
        ctx.clip(using: .evenOdd)
    }

    /// Fills the current clip with a diagonal gradient across `path`'s bounds (top-left →
    /// bottom-right in a y-up context).
    private static func gradient(_ path: CGPath, _ stops: [(CGFloat, CGColor)], _ ctx: CGContext) {
        let box = path.boundingBoxOfPath
        guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: stops.map(\.1) as CFArray,
                                 locations: stops.map(\.0)) else { return }
        // Keep the sweep's angle calm on long thin shapes: never steeper than 45°.
        let d = min(box.width, box.height)
        let start = CGPoint(x: box.minX, y: box.maxY)
        let end = CGPoint(x: box.minX + max(box.width, d), y: box.maxY - max(box.height, d))
        ctx.drawLinearGradient(g, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    // MARK: Colours

    /// Resolved colours for one draw. Accent, text and the signature pink/acid come from
    /// the tokens, resolved for the requested appearance (and its high-contrast variant).
    private struct Colors {
        let theme: Theme
        let metrics: Metrics
        let dark: Bool
        let glow: CGColor
        let accent: CGColor
        let text: CGColor
        /// The hover ring's sweep: hue → accent (Studio), a holographic hue shift
        /// (Iridescent), or the signature pink → violet → acid (Neon).
        let hoverStops: [(CGFloat, CGColor)]
        /// Neon selection: violet → acid green (the palette's two anchors).
        let selectionStops: [(CGFloat, CGColor)]
        /// Neon emphasis: the item's own hue, brightening along the diagonal.
        let hueStops: [(CGFloat, CGColor)]

        init(tint: NSColor?, dark: Bool, increaseContrast: Bool) {
            theme = Theme.current
            metrics = CanvasHighlight.metrics(for: theme)
            self.dark = dark
            let appearance = NSAppearance(named: increaseContrast
                                          ? (dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
                                          : (dark ? .darkAqua : .aqua))
            var accent = NSColor.hex(dark ? 0xBE48E0 : 0xB020D0)
            var text = NSColor.hex(dark ? 0xE8EAF2 : 0x1A1B26)
            var pink = NSColor.hex(dark ? 0xFF1493 : 0xD4107A)
            var acid = NSColor.hex(dark ? 0x39FF14 : 0x00C020)
            appearance?.performAsCurrentDrawingAppearance {
                accent = NSColor(Tokens.Colors.accent).usingColorSpace(.sRGB) ?? accent
                text = NSColor(Tokens.Colors.textPrimary).usingColorSpace(.sRGB) ?? text
                pink = NSColor(Tokens.Colors.brandPink).usingColorSpace(.sRGB) ?? pink
                acid = NSColor(Tokens.Colors.brandAcid).usingColorSpace(.sRGB) ?? acid
            }
            self.accent = accent.cgColor
            self.text = text.cgColor
            let glowNS = CanvasHighlight.glowColor(for: tint, dark: dark) ?? accent
            self.glow = glowNS.cgColor
            switch theme {
            case .studio, .ocean, .sunset, .forest:
                // Hue → a lighter mid → accent: reads as one luminous sweep, not two colours.
                // (Each theme's own accent: violet, azure, rose, pine.)
                let mid = glowNS.blended(withFraction: 0.35, of: dark ? .white : accent) ?? glowNS
                hoverStops = [(0, glowNS.cgColor), (0.45, mid.cgColor), (1, accent.cgColor)]
            case .iridescent:
                hoverStops = CanvasHighlight.holographicStops(from: glowNS)
            case .neon:
                hoverStops = CanvasHighlight.signatureStops(pink: pink, violet: accent, acid: acid)
            }
            selectionStops = [(0, accent.cgColor), (0.55, accent.cgColor), (1, acid.cgColor)]
            let light = glowNS.blended(withFraction: dark ? 0.45 : 0.25, of: dark ? .white : accent) ?? glowNS
            hueStops = [(0, glowNS.cgColor), (1, light.cgColor)]
        }
    }

    /// The Neon signature sweep (pink → violet → acid green) as gradient stops, for any
    /// canvas that wants the same hairline.
    static func signatureStops(dark: Bool) -> [(CGFloat, CGColor)] {
        signatureStops(pink: NSColor.hex(dark ? 0xFF1493 : 0xD4107A), violet: NSColor.hex(dark ? 0xBE48E0 : 0xB020D0),
                       acid: NSColor.hex(dark ? 0x39FF14 : 0x00C020))
    }

    private static func signatureStops(pink: NSColor, violet: NSColor, acid: NSColor) -> [(CGFloat, CGColor)] {
        [(0, pink.cgColor), (0.5, violet.cgColor), (1, acid.cgColor)]
    }

    /// Iridescent: the item's hue sliding −30° → +40° → +100° around the wheel, like light
    /// across a holographic foil.
    private static func holographicStops(from color: NSColor) -> [(CGFloat, CGColor)] {
        guard let rgb = color.usingColorSpace(.sRGB) else { return [(0, color.cgColor), (1, color.cgColor)] }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        func shifted(_ degrees: CGFloat) -> CGColor {
            var x = (h + degrees / 360).truncatingRemainder(dividingBy: 1)
            if x < 0 { x += 1 }
            return NSColor(hue: x, saturation: s, brightness: b, alpha: 1).cgColor
        }
        return [(0, shifted(-30)), (0.5, shifted(40)), (1, shifted(100))]
    }

    /// The luminous version of an item's fill: same hue, lifted for a dark canvas or deepened
    /// for a light one. `nil` for a colourless fill.
    static func glowColor(for tint: NSColor?, dark: Bool) -> NSColor? {
        guard let rgb = tint?.usingColorSpace(.sRGB) else { return nil }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        guard s > 0.08, a > 0.05 else { return nil }
        return dark ? NSColor(hue: h, saturation: 0.58, brightness: 1, alpha: 1)
                    : NSColor(hue: h, saturation: 0.82, brightness: 0.74, alpha: 1)
    }
}
