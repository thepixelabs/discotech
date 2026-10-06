import AppKit
import SwiftUI

/// The Floor's local token layer. Node colours always come from `Palette` (hues,
/// shading, label ink, synthetic tints — so the floor follows the theme); the canvas
/// background from `Tokens.Colors.chartSurface`; motion timings from `Tokens.Motion`.
enum FloorStyle {
    // MARK: Grid

    /// The layout snaps blocks to a grid of equal cells, its unit of area (never shown).
    /// Never fewer or more cells than this, whatever the window size.
    static let minTiles = 120
    static let maxTiles = 2600
    /// Target cell edge (points); the cell count is chosen so the floor lands near it.
    static let targetTile: CGFloat = 22
    /// Share of grid cells the first placement attempt hands out. A region whose
    /// children don't fit gets more room on the next attempt; the whole grid loosens
    /// (5 points a time) only when the regions themselves don't fit.
    static let gridFill = 0.96
    static let gridAttempts = 16
    /// Padding around the floor (points): the sides match the hover strip's inset, so
    /// the floor's edges line up with it; the bottom plus the strip's own gap makes the
    /// same 16 pt.
    static let outerPadding: CGFloat = 16
    static let topPadding: CGFloat = 8
    static let bottomPadding: CGFloat = 8

    // MARK: Hierarchy

    /// Area is damped: a block's share of its parent's cells follows `size ^ areaExponent`
    /// among its siblings, not `size`, so one huge folder can't swallow the floor and
    /// the next dozen items stay big enough to read. Order (largest first) is kept, and
    /// every label still shows the true size and byte share.
    static let areaExponent = 0.5
    /// A top-level item needs this many cells to get its own region; smaller ones join
    /// "Everything else". Same for children inside a region.
    static let minRegionTiles: Double = 5
    static let minChildTiles: Double = 4
    /// …and at least this share of the floor (regions) or of its region (children), so
    /// slivers join "Everything else" instead of adding confetti.
    static let minRegionShare = 0.004
    static let minChildShare = 0.015
    static let maxRegions = 40
    static let maxChildren = 32
    /// Regions smaller than this are always drawn flat.
    static let minSubdivideTiles = 12
    /// A share of a parent at or above this counts as "the same thing one level down"
    /// (/Users → /Users/you); mirrors `Palette`'s rule.
    static let mostOfParent = 0.85
    /// A header strip may add at most this share to a region's area; smaller regions
    /// stay flat rather than be inflated by their own name.
    static let headerMaxShare = 0.25

    // MARK: Shape (points; gaps are capped against the cell edge by `FloorLayout`)

    /// Between regions, between children, and from a region's edge to its children.
    static let regionGap: CGFloat = 10
    static let childGap: CGFloat = 5
    static let regionPad: CGFloat = 6
    static let regionRadius: CGFloat = 14
    static let childRadius: CGFloat = 9
    /// A header strip needs this much height (name + size line, incl. padding).
    static let headerHeight: CGFloat = 44

    // MARK: Hover / emphasis

    static let dimAlpha: CGFloat = 0.38
    /// Siblings of the hovered child inside its region.
    static let siblingAlpha: CGFloat = 0.62
    static var hoverBlendDuration: CFTimeInterval { Tokens.Motion.micro * 0.8 } // 120 ms
    static var zoomDuration: CFTimeInterval { Tokens.Motion.panel }
    static let dissolveDuration: CFTimeInterval = 0.15
    /// Size changes settle for this long before the floor is laid out again.
    static let resizeSettle: CFTimeInterval = 0.12

    // MARK: Labels

    static let labelInset: CGFloat = 8
    static let childLabelInset: CGFloat = 6
    /// Smallest block that tries for a label (points).
    static let minLabelWidth: CGFloat = 46

    // MARK: Colours

    static func background(_ appearance: NSAppearance) -> CGColor {
        var color = CGColor(gray: 0, alpha: 1)
        appearance.performAsCurrentDrawingAppearance {
            color = NSColor(Tokens.Colors.chartSurface).usingColorSpace(.sRGB)?.cgColor ?? color
        }
        return color
    }

    /// Resting fill of a block with `paint` (the theme ramp step, `Palette.fill`).
    static func tone(_ paint: Palette.Paint, dark: Bool) -> NSColor {
        Palette.fill(paint, dark: dark)
    }

    /// The tint the hover, selection and emphasis glow in: the block's own fill.
    static func swatch(_ paint: Palette.Paint, dark: Bool) -> NSColor {
        Palette.fill(paint, dark: dark)
    }

    /// A block's top-lit fill: the tone a little brighter at the top than at the bottom,
    /// within a few percent so the label ink picked for the tone holds across the block.
    static func litStops(_ paint: Palette.Paint, dark: Bool) -> [(CGFloat, CGColor)] {
        let tone = (Palette.fill(paint, dark: dark).usingColorSpace(.sRGB) ?? Palette.fill(paint, dark: dark))
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        tone.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        func stop(_ at: CGFloat, bri: Double) -> (CGFloat, CGColor) {
            (at, Palette.srgb(hue: Double(h), saturation: Double(s), brightness: min(1, Double(b) * bri), alpha: 1).cgColor)
        }
        return dark ? [stop(0, bri: 1.05), stop(1, bri: 0.98)] : [stop(0, bri: 1.03), stop(1, bri: 0.98)]
    }

    /// Name size for an item holding `share` of the focus: 13 pt for small things up
    /// to 27 pt for a region that is all of the folder (children top out at 19 pt).
    static func bentoNameSize(share: Double, child: Bool) -> CGFloat {
        let s = CGFloat(max(0, min(1, share)).squareRoot())
        return child ? 12 + 7 * s : 13 + 14 * s
    }

    /// "28%", "<1%".
    static func percent(_ share: Double) -> String {
        if share < 0.01 { return "<1%" }
        return "\(Int((share * 100).rounded()))%"
    }

    /// A symbol for a plain folder or file (the block icons); well-known home folders
    /// get their own.
    static func symbolName(for node: FileNode) -> String {
        guard node.isDirectory else { return "doc.fill" }
        switch node.name {
        case "Documents": return "doc.text.fill"
        case "Downloads": return "arrow.down.circle.fill"
        case "Desktop": return "menubar.dock.rectangle"
        case "Library": return "building.columns.fill"
        case "Pictures", "Photos": return "photo.fill"
        case "Music": return "music.note"
        case "Movies": return "film.fill"
        case "Applications": return "square.grid.3x3.fill"
        case "Developer", "git", "src", "Projects": return "chevron.left.forwardslash.chevron.right"
        case "Public": return "person.2.fill"
        default: return "folder.fill"
        }
    }

    /// Label ink for text on a tone: white or `Palette.Synthetic.ink`, whichever has the
    /// higher WCAG contrast against the actual fill.
    static func ink(on fill: NSColor) -> NSColor {
        let l = luminance(fill)
        let onWhite = 1.05 / (l + 0.05)
        let onInk = (l + 0.05) / (luminance(Palette.Synthetic.ink) + 0.05)
        return onWhite >= onInk ? .white : Palette.Synthetic.ink
    }

    /// WCAG relative luminance of an opaque colour.
    static func luminance(_ color: NSColor) -> Double {
        guard let c = color.usingColorSpace(.sRGB) else { return 0 }
        func lin(_ v: CGFloat) -> Double {
            let x = Double(v)
            return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
    }

    /// Secondary (size) text: the label ink softened only as far as it keeps 4.5:1.
    static func detailInk(_ ink: NSColor, on fill: NSColor) -> NSColor {
        for alpha in [0.8, 0.88, 0.94] as [CGFloat] {
            let mixed = blend(ink, alpha: alpha, over: fill)
            if contrast(mixed, fill) >= 4.5 { return ink.withAlphaComponent(alpha) }
        }
        return ink
    }

    static func blend(_ fg: NSColor, alpha: CGFloat, over bg: NSColor) -> NSColor {
        guard let f = fg.usingColorSpace(.sRGB), let b = bg.usingColorSpace(.sRGB) else { return fg }
        return NSColor(srgbRed: f.redComponent * alpha + b.redComponent * (1 - alpha),
                       green: f.greenComponent * alpha + b.greenComponent * (1 - alpha),
                       blue: f.blueComponent * alpha + b.blueComponent * (1 - alpha), alpha: 1)
    }

    static func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Text on the canvas or on a translucent block (synthetics): the Studio text roles.
    /// Resolved for `dark` (and the high-contrast variant when the current drawing
    /// appearance is one), so callers get a plain sRGB colour.
    static func canvasInk(dark: Bool) -> NSColor { resolved(Tokens.Colors.textPrimary, dark: dark) }
    static func canvasDetailInk(dark: Bool) -> NSColor { resolved(Tokens.Colors.textSecondary, dark: dark) }

    static func resolved(_ color: Color, dark: Bool) -> NSColor {
        let current = NSAppearance.currentDrawing()
        let currentDark = current.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let appearance = currentDark == dark ? current : (NSAppearance(named: dark ? .darkAqua : .aqua) ?? current)
        var out = NSColor(color)
        appearance.performAsCurrentDrawingAppearance {
            out = NSColor(color).usingColorSpace(.sRGB) ?? out
        }
        return out
    }

    /// One-point top-edge highlight on a region.
    static func topHighlight(dark: Bool) -> CGColor { NSColor(white: 1, alpha: dark ? 0.10 : 0.45).cgColor }

    // Hover, selection, lineage and emphasis are drawn by `CanvasHighlight`.

    /// Items in the Crate: veiled toward the background and hatched.
    static let crateVeil: CGFloat = 0.5
    static func crateHatch(dark: Bool) -> CGColor {
        (dark ? NSColor(white: 1, alpha: 0.5) : Palette.Synthetic.ink.withAlphaComponent(0.4)).cgColor
    }

    static func roundedFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        if let descriptor = base.fontDescriptor.withDesign(.rounded) {
            return NSFont(descriptor: descriptor, size: size) ?? base
        }
        return base
    }
}
