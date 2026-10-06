import SwiftUI
import AppKit

/// Discotech's node colour: the **single source of truth** shared by the Ball
/// (`SunburstLayout`/`SunburstNSView`), Layers, Floor and any other UI that wants a matching
/// swatch (sidebar dots, hover card, legend).
///
/// Colour is two decisions, kept apart:
/// 1. **Which step** of the current theme's ramp a node takes (`paint(for:in:)`): from its
///    size (`SizeRamp`, the default), its kind of content (`ContentKind`) or its top-level
///    folder, per the user's "Colour by" setting (`ColorMode`). The result, a `Paint`, is
///    appearance-independent and cheap to store in a layout.
/// 2. **What that step looks like** (`fill`, `gradientStops`, `labelInk`): the active
///    `ThemeRamp` (`Palette.ramp`) for the current appearance. Gradient ramps are monotonic
///    in lightness (pale → deep in light mode, dim → luminous in dark mode); Multicolour ramps
///    walk a meaningful hue order (green → red, cool → hot), so a stronger or hotter colour
///    always means more.
///
/// Everything reads `Theme.current` and `ColorMode.current`; a switch of either posts
/// `.discotechThemeDidChange`, and canvases rebuild what they cached.
enum Palette {
    /// Steps in every theme ramp.
    static let steps = 8

    /// A node's colour, before appearance: a ramp step, plus how far it is softened
    /// (desaturated at constant luminance) to show depth in the kind and folder modes.
    struct Paint: Hashable {
        var step: Int
        var soften: Int = 0
    }

    /// Desaturation per soften level, and the most levels applied.
    static let softenUnit = 0.13
    static let maxSoften = 4

    // MARK: - Mapping (which step)

    /// The paint for `node` seen inside `focus`, or `nil` for a synthetic node (Free,
    /// Purgeable, Unseen and its snapshots), which keeps its fixed tint (`syntheticColor`).
    static func paint(for node: FileNode, in focus: FileNode) -> Paint? {
        guard node.kind == .item else { return nil }
        switch ColorMode.current {
        case .size:
            guard node !== focus, focus.size > 0 else { return Paint(step: steps - 1) }
            return Paint(step: SizeRamp.step(share: Double(node.size) / Double(focus.size)))
        case .kind:
            return Paint(step: (node.contentKind ?? .other).step, soften: soften(node, focus))
        case .folder:
            return Paint(step: folderStep(for: node), soften: soften(node, focus))
        }
    }

    /// Size mode's paint for an item holding `share` of the folder in view.
    static func paint(forShare share: Double) -> Paint { Paint(step: SizeRamp.step(share: share)) }

    /// Deeper rings and files read a little quieter in the categorical modes, without
    /// changing lightness (so label contrast never moves).
    private static func soften(_ node: FileNode, _ focus: FileNode) -> Int {
        min(maxSoften, min(3, depthBelow(node, focus)) + (node.isDirectory ? 0 : 1))
    }

    /// Top-level folder mode: the step of the scan root's direct child that holds `node`
    /// (the strongest for the biggest, spread down the ramp for the rest). The root itself
    /// takes the strongest step.
    static func folderStep(for node: FileNode) -> Int {
        var top = node
        while let parent = top.parent, parent.parent != nil { top = parent }
        guard let root = top.parent else { return steps - 1 }
        if folderRoot !== root || folderIndexCount != root.children.count {
            folderIndex = [:]
            var i = 0
            for child in root.children where !child.isSynthetic {
                folderIndex[ObjectIdentifier(child)] = i
                i += 1
            }
            folderRealCount = i
            folderIndexCount = root.children.count
            folderRoot = root
        }
        return spreadStep(index: folderIndex[ObjectIdentifier(top)] ?? 0, count: folderRealCount)
    }

    private static weak var folderRoot: FileNode?
    private static var folderIndexCount = -1
    private static var folderRealCount = 0
    private static var folderIndex: [ObjectIdentifier: Int] = [:]

    /// The step for category `index` of `count` (largest first): the first `steps - 1` are
    /// spread evenly from the strongest step down to step 1, wide apart when there are few;
    /// any more cycle through the ramp.
    static func spreadStep(index i: Int, count n: Int) -> Int {
        let slots = min(max(n, 1), steps - 1)
        if i < slots {
            guard slots > 1 else { return steps - 1 }
            return (steps - 1) - Int((Double(i) * Double(steps - 2) / Double(slots - 1)).rounded())
        }
        let cycle = [6, 4, 2, 5, 3, 1, 7]
        return cycle[(i - slots) % cycle.count]
    }

    /// Ball ring depth of `node` relative to `focus` (0 = direct child).
    static func depthBelow(_ node: FileNode, _ focus: FileNode) -> Int {
        max(0, node.depth - focus.depth - 1)
    }

    // MARK: - Resolving (what it looks like)

    private struct FillKey: Hashable {
        let ramp: String
        let dark: Bool
        let paint: Paint
    }
    private static var fillCache: [FillKey: NSColor] = [:]

    /// The ramp everything draws with: the current theme's of the active palette style
    /// (a Gradient theme's, or a Multicolour theme's multi-hue one).
    static var ramp: ThemeRamp {
        PaletteStyle.current == .signal ? SignalTheme.current.ramp : Theme.selected.ramp
    }

    /// The ramp step itself, unsoftened.
    static func stepColor(_ step: Int, dark: Bool, ramp: ThemeRamp = Palette.ramp) -> NSColor {
        NSColor.hex(ramp.hex(step: step, dark: dark))
    }

    /// The resting fill for `paint` (opaque sRGB).
    static func fill(_ paint: Paint, dark: Bool, ramp: ThemeRamp = Palette.ramp) -> NSColor {
        let key = FillKey(ramp: ramp.id, dark: dark, paint: paint)
        if let cached = fillCache[key] { return cached }
        let base = stepColor(paint.step, dark: dark, ramp: ramp)
        let color = paint.soften > 0 ? desaturate(base, by: Double(min(paint.soften, maxSoften)) * softenUnit) : base
        fillCache[key] = color
        return color
    }

    /// The theme's fill across a wedge or block: the resting fill with the theme's sheen
    /// (a slight lift, a few degrees of hue drift for some themes).
    static func gradientStops(_ paint: Paint, dark: Bool, alpha: CGFloat, ramp: ThemeRamp = Palette.ramp) -> [(CGFloat, CGColor)] {
        let resting = fill(paint, dark: dark, ramp: ramp)
        let base = resting.usingColorSpace(.sRGB) ?? resting
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return ramp.sheen.map { stop in
            let hue = normalizeDegrees(Double(h) * 360 + stop.hueShift) / 360
            return (stop.location, srgb(hue: hue, saturation: Double(s), brightness: min(1, Double(b) * stop.briMul), alpha: alpha).cgColor)
        }
    }

    /// Label ink on `paint`'s fill: white or `Synthetic.ink`, whichever contrasts more
    /// (every ramp step clears 4.5:1 with one of them).
    static func labelInk(_ paint: Paint, dark: Bool) -> NSColor {
        inkColor(onLuminance: relativeLuminance(fill(paint, dark: dark)))
    }

    /// `Color` for `node`, resolved for whichever appearance it is drawn in. Synthetic nodes
    /// get their fixed tints (`syntheticColor`).
    static func color(for node: FileNode, in focus: FileNode) -> Color {
        if let synthetic = syntheticColor(for: node) { return synthetic }
        guard let paint = paint(for: node, in: focus) else { return .gray }
        return color(for: paint)
    }

    /// An appearance-tracking `Color` for `paint` (legend, help centre).
    static func color(for paint: Paint) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            fill(paint, dark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        })
    }

    /// Fixed, appearance-aware color for a `SpaceAccounting` synthetic node — deliberately
    /// outside the ramps so accounting data never reads as "real" file/folder data, in
    /// either the chart or the sidebar. `nil` for a real `.item` node. Backed by
    /// `Synthetic`'s shared constants (see there for the other canvases' equivalent).
    static func syntheticColor(for node: FileNode) -> Color? {
        let dark: (NSAppearance) -> Bool = { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
        switch node.kind {
        case .item:
            return nil
        case .freeSpace:
            return Color(nsColor: NSColor(name: nil) { a in Synthetic.freeFill(dark: dark(a)) })
        case .purgeable:
            return Color(nsColor: NSColor(name: nil) { a in Synthetic.purgeableFill(dark: dark(a)) })
        case .hidden, .snapshot:
            return Color(nsColor: NSColor(name: nil) { a in Synthetic.unseenFill(dark: dark(a)) })
        }
    }

    /// Blends two stop lists of equal shape (the Ball's zoom morph between two paints).
    static func blend(_ a: [(CGFloat, CGColor)], _ b: [(CGFloat, CGColor)], _ t: Double) -> [(CGFloat, CGColor)] {
        guard a.count == b.count else { return t < 0.5 ? a : b }
        return zip(a, b).map { sa, sb in
            let ca = NSColor(cgColor: sa.1)?.usingColorSpace(.sRGB)
            let cb = NSColor(cgColor: sb.1)?.usingColorSpace(.sRGB)
            guard let ca, let cb else { return t < 0.5 ? sa : sb }
            let mixed = ca.blended(withFraction: CGFloat(t), of: cb) ?? cb
            return (sa.0 + (sb.0 - sa.0) * CGFloat(t), mixed.cgColor)
        }
    }

    // MARK: - Legibility

    /// White or `Synthetic.ink`, whichever contrasts more with a fill of luminance `fill`.
    static func inkColor(onLuminance fill: Double) -> NSColor {
        let ink = relativeLuminance(Synthetic.ink)
        let onWhite = 1.05 / (fill + 0.05)
        let onInk = (fill + 0.05) / (ink + 0.05)
        return onInk > onWhite ? Synthetic.ink : NSColor.white
    }

    /// WCAG 2 relative luminance (sRGB, linearized).
    static func relativeLuminance(_ color: NSColor) -> Double {
        let c = color.usingColorSpace(.sRGB) ?? color
        return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
    }

    private static func linear(_ v: CGFloat) -> Double {
        let x = Double(v)
        return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
    }

    private static func encoded(_ x: Double) -> CGFloat {
        let v = max(0, min(1, x))
        return CGFloat(v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055)
    }

    /// `color` with `fraction` of its chroma removed at constant WCAG luminance (a mix
    /// toward the grey of equal luminance in linear light), so its label ink is unchanged.
    static func desaturate(_ color: NSColor, by fraction: Double) -> NSColor {
        guard let c = color.usingColorSpace(.sRGB) else { return color }
        let r = linear(c.redComponent), g = linear(c.greenComponent), b = linear(c.blueComponent)
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let f = max(0, min(1, fraction))
        return NSColor(srgbRed: encoded(r + (y - r) * f), green: encoded(g + (y - g) * f),
                       blue: encoded(b + (y - b) * f), alpha: c.alphaComponent)
    }

    /// An sRGB colour from HSB components (`NSColor(hue:)` is not tied to sRGB).
    static func srgb(hue: Double, saturation s: Double, brightness v: Double, alpha: CGFloat) -> NSColor {
        let h = (hue - floor(hue)) * 6
        let i = Int(h) % 6
        let f = h - floor(h)
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        let (r, g, b): (Double, Double, Double)
        switch i {
        case 0: (r, g, b) = (v, t, p)
        case 1: (r, g, b) = (q, v, p)
        case 2: (r, g, b) = (p, v, t)
        case 3: (r, g, b) = (p, q, v)
        case 4: (r, g, b) = (t, p, v)
        default: (r, g, b) = (v, p, q)
        }
        return NSColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: alpha)
    }

    // MARK: - Synthetic node tints (shared across canvases)

    /// Shared, named tints for the four synthetic "not really data" fills — Free,
    /// Purgeable, Unseen, and the "Everything else" merge bucket — used by `Synthetic`
    /// and directly by `SunburstNSView`'s per-role drawing (fill vs. stroke vs.
    /// highlighted-stroke need more than the one flat `Color` `syntheticColor` returns).
    /// Floor and Layers adopt these instead of
    /// re-deriving their own Free/Purgeable/Unseen/"Everything else" colors, so all
    /// three canvases read as the same language.
    enum Synthetic {
        /// `text.primary` ink used on light fills / light-mode text.
        static let ink = NSColor(srgbRed: 0x1A / 255.0, green: 0x1B / 255.0, blue: 0x26 / 255.0, alpha: 1)

        /// Free: frosted glass, barely-there, no hue — reads as "empty".
        static func freeFill(dark: Bool) -> NSColor { NSColor(white: dark ? 1 : 0, alpha: dark ? 0.045 : 0.03) }
        static func freeStroke(dark: Bool, highlighted: Bool) -> NSColor {
            NSColor(white: dark ? 1 : 0, alpha: (highlighted ? 0.55 : dark ? 0.12 : 0.12))
        }

        /// Purgeable: the `warning` role (amber) — "counted as used, but reclaimable".
        /// This is the *only* place amber appears outside a ramp that has it.
        /// Neon uses the design system's `--warn` (#FFB800); the others the Studio amber.
        private static var warningDark: NSColor {
            Theme.current == .neon ? NSColor.hex(0xFFB800)
                : NSColor(srgbRed: 0xF5 / 255.0, green: 0xB5 / 255.0, blue: 0x44 / 255.0, alpha: 1)
        }
        private static let warningLight = NSColor(srgbRed: 0x9A / 255.0, green: 0x58 / 255.0, blue: 0x00 / 255.0, alpha: 1)
        static func purgeableFill(dark: Bool) -> NSColor { (dark ? warningDark : warningLight).withAlphaComponent(0.24) }
        static func purgeableStroke(dark: Bool, highlighted: Bool) -> NSColor {
            (dark ? warningDark : warningLight).withAlphaComponent(highlighted ? 0.95 : 0.7)
        }

        /// Unseen (and its Snapshot/other-volume children): a cool slate — "not a
        /// file", distinct from the achromatic "Everything else" hatch.
        private static let slateDark = NSColor(srgbRed: 0x5B / 255.0, green: 0x64 / 255.0, blue: 0x78 / 255.0, alpha: 1)
        private static let slateLight = NSColor(srgbRed: 0x9A / 255.0, green: 0xA2 / 255.0, blue: 0xB5 / 255.0, alpha: 1)
        static func unseenFill(dark: Bool) -> NSColor { (dark ? slateDark : slateLight).withAlphaComponent(0.20) }
        static func unseenStroke(dark: Bool, highlighted: Bool) -> NSColor {
            (dark ? slateDark : slateLight).withAlphaComponent(highlighted ? 0.75 : 0.42)
        }

        /// "Everything else": the merged small-items bucket — `line.hairline`, no hue
        /// at all, so it reads as "not worth a color" rather than another data step.
        static func otherFill(dark: Bool) -> NSColor { dark ? NSColor.white.withAlphaComponent(0.055) : ink.withAlphaComponent(0.045) }
        static func otherStroke(dark: Bool) -> NSColor { dark ? NSColor.white.withAlphaComponent(0.09) : ink.withAlphaComponent(0.09) }
    }

    // MARK: - Helpers

    static func normalizeDegrees(_ degrees: Double) -> Double {
        var x = degrees.truncatingRemainder(dividingBy: 360)
        if x < 0 { x += 360 }
        return x
    }
}
