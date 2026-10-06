import AppKit

/// Maps layout points (top-down from the grid's top-left) to view points (y up).
struct FloorGeometry {
    let originX: CGFloat
    let topY: CGFloat

    func view(_ r: CGRect) -> CGRect {
        CGRect(x: originX + r.minX, y: topY - r.maxY, width: r.width, height: r.height)
    }

    func layout(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - originX, y: topY - p.y) }
}

/// What a block is filled with.
enum FloorFill {
    case tone(Palette.Paint)
    /// "Everything else"; inside a real region it takes that region's tone.
    case other(on: Palette.Paint?)
    case free, purgeable, unseen

    /// `paint` is the block's own; `regionPaint` the enclosing region's (for "Everything else").
    init(kind: FileNode.Kind, isOther: Bool, paint: Palette.Paint?, regionPaint: Palette.Paint?, inRegion: Bool) {
        if isOther { self = .other(on: inRegion ? regionPaint : nil); return }
        switch kind {
        case .item: self = paint.map { .tone($0) } ?? .other(on: nil)
        case .freeSpace: self = .free
        case .purgeable: self = .purgeable
        case .hidden, .snapshot: self = .unseen
        }
    }
}

/// Renders one floor into a bitmap context: solid, top-lit cards with generous gaps, big
/// type and icons. Everything here is static (drawn once per layout, theme, appearance,
/// size and Crate); hover and selection are drawn over it by `FloorNSView` with
/// `CanvasHighlight`.
struct FloorPainter {
    let ctx: CGContext
    let layout: FloorLayout
    let geo: FloorGeometry
    let bounds: CGRect
    let dark: Bool
    let background: CGColor
    /// Resting rectangles (layout space) of what's in the Crate.
    let crateRects: [(CGRect, CGFloat)]
    /// Finder icon for a package, if already loaded; the view re-renders once it is.
    let packageIcon: (FileNode) -> NSImage?

    // MARK: - Entry

    func render() {
        ctx.setFillColor(background)
        ctx.fill(bounds)
        if SpaceBackdrop.isActive { SpaceBackdrop.draw(in: ctx, rect: bounds, dark: dark, background: background) }
        if layout.isEmpty {
            drawCentered(layout.focus.children.isEmpty ? "This folder is empty" : "Nothing here takes up space")
            return
        }
        for region in layout.regions { renderRegion(region) }
        drawCrate()
        drawLabels()
    }

    private func renderRegion(_ region: FloorRegion) {
        let rect = geo.view(region.rect)
        let radius = layout.regionRadius(region.rect)
        if region.isSubdivided {
            let fill = FloorFill(kind: region.kind, isOther: region.isOther, paint: region.paint,
                                 regionPaint: nil, inRegion: false)
            paint(fill, rect: rect, radius: radius, role: .region)
            for (k, li) in region.leaves.enumerated() {
                let leaf = layout.leaves[li]
                guard !leaf.rect.isEmpty else { continue }
                paint(leafFill(leaf, in: region), rect: geo.view(leaf.rect), radius: layout.leafRadius(leaf), role: .child(k))
            }
        } else {
            let leaf = layout.leaves[region.leaves.lowerBound]
            let fill = FloorFill(kind: leaf.kind, isOther: leaf.isOther, paint: leaf.paint ?? region.paint,
                                 regionPaint: nil, inRegion: false)
            paint(fill, rect: rect, radius: radius, role: .region)
        }
    }

    private func leafFill(_ leaf: FloorLeaf, in region: FloorRegion) -> FloorFill {
        FloorFill(kind: leaf.kind, isOther: leaf.isOther, paint: leaf.paint, regionPaint: region.paint,
                  inRegion: region.kind == .item)
    }

    // MARK: - Blocks

    enum Role: Equatable {
        case region
        /// A child inside a region (its index there).
        case child(Int)
    }

    /// Paints one block.
    private func paint(_ fill: FloorFill, rect: CGRect, radius: CGFloat, role: Role) {
        guard rect.width > 0.5, rect.height > 0.5 else { return }
        let r = min(radius, min(rect.width, rect.height) / 2)
        let shape = CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        switch fill {
        case .tone(let paint):
            block(shape, rect: rect, r: r, paint: paint, role: role)
        case .other(let onPaint):
            if let onPaint {
                // Inside a region: the region's own tone, hatched, so the small items read
                // as "more of this folder" rather than another colour.
                let tone = FloorStyle.tone(onPaint, dark: dark)
                ctx.addPath(shape)
                ctx.setFillColor(tone.cgColor)
                ctx.fillPath()
                hatch(shape, color: FloorStyle.ink(on: tone).withAlphaComponent(0.16).cgColor, spacing: 7)
            } else {
                ctx.addPath(shape)
                ctx.setFillColor(Palette.Synthetic.otherFill(dark: dark).cgColor)
                ctx.fillPath()
                hatch(shape, color: Palette.Synthetic.otherStroke(dark: dark).withAlphaComponent(dark ? 0.2 : 0.16).cgColor, spacing: 7)
                stroke(shape, Palette.Synthetic.otherStroke(dark: dark).cgColor, width: 1)
            }
        case .free:
            ctx.addPath(shape)
            ctx.setFillColor(Palette.Synthetic.freeFill(dark: dark).cgColor)
            ctx.fillPath()
            stroke(shape, Palette.Synthetic.freeStroke(dark: dark, highlighted: false).withAlphaComponent(dark ? 0.22 : 0.18).cgColor, width: 1)
        case .purgeable:
            ctx.addPath(shape)
            ctx.setFillColor(Palette.Synthetic.purgeableFill(dark: dark).cgColor)
            ctx.fillPath()
            hatch(shape, color: Palette.Synthetic.purgeableStroke(dark: dark, highlighted: false).withAlphaComponent(0.25).cgColor, spacing: 6)
            ctx.saveGState()
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            stroke(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: r, cornerHeight: r, transform: nil),
                   Palette.Synthetic.purgeableStroke(dark: dark, highlighted: false).cgColor, width: 1)
            ctx.restoreGState()
        case .unseen:
            ctx.addPath(shape)
            ctx.setFillColor(Palette.Synthetic.unseenFill(dark: dark).cgColor)
            ctx.fillPath()
            hatch(shape, color: Palette.Synthetic.unseenStroke(dark: dark, highlighted: false).cgColor, spacing: 6)
        }
    }

    /// A solid card lit from above: a gentle top-to-bottom lift, a one-point top highlight,
    /// and in light mode a soft contact shadow so cards sit on the canvas.
    private func block(_ shape: CGPath, rect: CGRect, r: CGFloat, paint: Palette.Paint, role: Role) {
        if !dark, role == .region {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 4, color: Palette.Synthetic.ink.withAlphaComponent(0.12).cgColor)
            ctx.addPath(shape)
            ctx.setFillColor(FloorStyle.tone(paint, dark: dark).cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        let stops = FloorStyle.litStops(paint, dark: dark)
        linearGradient(stops, from: CGPoint(x: rect.midX, y: rect.maxY), to: CGPoint(x: rect.midX, y: rect.minY))
        ctx.restoreGState()
        // One-point highlight along the top edge.
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        ctx.setStrokeColor(FloorStyle.topHighlight(dark: dark))
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: rect.minX + r, y: rect.maxY - 0.5))
        ctx.addLine(to: CGPoint(x: rect.maxX - r, y: rect.maxY - 0.5))
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: - Primitives

    private func linearGradient(_ stops: [(CGFloat, CGColor)], from: CGPoint, to: CGPoint) {
        guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: stops.map(\.1) as CFArray,
                                 locations: stops.map(\.0)) else { return }
        ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    private func stroke(_ path: CGPath, _ color: CGColor, width: CGFloat) {
        ctx.addPath(path)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.strokePath()
    }

    private func hatch(_ path: CGPath, color: CGColor, spacing: CGFloat) {
        let box = path.boundingBoxOfPath
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.setStrokeColor(color)
        ctx.setLineWidth(1)
        var x = box.minX - box.height
        while x < box.maxX {
            ctx.move(to: CGPoint(x: x, y: box.minY))
            ctx.addLine(to: CGPoint(x: x + box.height, y: box.maxY))
            x += spacing
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// Crate items: veiled toward the background and hatched, so what's queued to go
    /// reads as "already on its way out" without losing its colour entirely.
    private func drawCrate() {
        guard !crateRects.isEmpty else { return }
        let path = CGMutablePath()
        for (r, radius) in crateRects where !r.isEmpty {
            let v = geo.view(r)
            let c = min(radius, min(v.width, v.height) / 2)
            path.addRoundedRect(in: v, cornerWidth: c, cornerHeight: c)
        }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setFillColor(background.copy(alpha: FloorStyle.crateVeil) ?? .clear)
        ctx.fillPath()
        ctx.restoreGState()
        hatch(path, color: FloorStyle.crateHatch(dark: dark), spacing: 4)
    }

    // MARK: - Labels

    private struct TextStyle {
        let name: NSFont
        let detail: NSFont
        let weight: NSFont.Weight
        var nameH: CGFloat { ceil(name.ascender - name.descender) }
        var detailH: CGFloat { ceil(detail.ascender - detail.descender) }

        init(name: CGFloat, detail: CGFloat, nameWeight: NSFont.Weight = .semibold) {
            weight = nameWeight
            self.name = FloorStyle.roundedFont(size: name, weight: nameWeight)
            self.detail = FloorStyle.roundedFont(size: detail, weight: .medium)
        }
    }

    /// What the label sits on: a known opaque fill (ink picked by contrast), or a
    /// synthetic block (canvas text colours).
    private func inks(for fill: NSColor?) -> (name: NSColor, detail: NSColor) {
        if let fill {
            let ink = FloorStyle.ink(on: fill)
            return (ink, FloorStyle.detailInk(ink, on: fill))
        }
        return (FloorStyle.canvasInk(dark: dark), FloorStyle.canvasDetailInk(dark: dark))
    }

    private func regionFill(_ region: FloorRegion) -> NSColor? {
        guard region.kind == .item, !region.isOther, let paint = region.paint else { return nil }
        return FloorStyle.tone(paint, dark: dark)
    }

    /// Sizes and percentages are always the true bytes (area is damped, so it isn't).
    private func drawLabels() {
        let focusSize = max(1, layout.focus.size)
        for region in layout.regions {
            let fill = regionFill(region)
            let (ink, detailInk) = inks(for: fill)
            let area = geo.view(region.isSubdivided ? region.headerRect : region.rect)
            let share = Double(region.size) / Double(focusSize)
            let size = ByteFormat.string(region.size)
            let details = [size + "  ·  " + FloorStyle.percent(share), size]
            let style = regionTextStyle(area: area, share: share, header: region.isSubdivided)
            drawLabel(names: region.nameCandidates, details: details, in: area, style: style,
                      inset: FloorStyle.labelInset + (region.isSubdivided ? 2 : 3),
                      ink: ink, detailInk: detailInk, allowInline: region.isSubdivided, icon: regionIcon(region, ink: ink))
            guard region.isSubdivided else { continue }
            for li in region.leaves {
                let leaf = layout.leaves[li]
                let rect = leaf.rect
                guard rect.width >= FloorStyle.minLabelWidth else { continue }
                var leafFill: NSColor?
                if region.kind == .item, leaf.kind == .item, let paint = leaf.isOther ? region.paint : leaf.paint {
                    leafFill = FloorStyle.tone(paint, dark: dark)
                }
                let (leafInk, leafDetail) = inks(for: leafFill)
                let style = childTextStyle(area: geo.view(rect), share: Double(leaf.size) / Double(focusSize))
                drawLabel(names: leaf.nameCandidates, details: [ByteFormat.string(leaf.size)], in: geo.view(rect), style: style,
                          inset: FloorStyle.childLabelInset + 2, ink: leafInk, detailInk: leafDetail,
                          allowInline: false, icon: leafIcon(leaf, ink: leafInk, rect: geo.view(rect)))
            }
        }
    }

    /// Type scales with the item's share of the folder (then fits the block), so the
    /// biggest regions read first from across the room.
    private func regionTextStyle(area: CGRect, share: Double, header: Bool) -> TextStyle {
        var name = FloorStyle.bentoNameSize(share: share, child: false)
        name = header ? min(name, max(13, area.height * 0.62)) : min(name, max(12.5, min(area.width / 8, area.height / 4)))
        return TextStyle(name: name.rounded(), detail: max(11, (name * 0.6).rounded()))
    }

    private func childTextStyle(area: CGRect, share: Double) -> TextStyle {
        let name = min(FloorStyle.bentoNameSize(share: share, child: true), max(11.5, min(area.width / 9, area.height / 4)))
        return TextStyle(name: name.rounded(), detail: max(10, (name * 0.66).rounded()), nameWeight: .semibold)
    }

    private struct Icon {
        let image: NSImage
        let size: CGFloat
        /// Above the name (big blocks) or before it on the same line (headers).
        let stacked: Bool
        /// Scale the image to `size` (app icons); symbols are drawn at their own size.
        var fit = false
    }

    private func regionIcon(_ region: FloorRegion, ink: NSColor) -> Icon? {
        let rect = geo.view(region.isSubdivided ? region.headerRect : region.rect)
        if region.isSubdivided {
            guard rect.width >= 180, let image = iconImage(region.node, ink: ink, size: 18) else { return nil }
            return Icon(image: image, size: 18, stacked: false, fit: region.node?.isPackage ?? false)
        }
        guard rect.width >= 110, rect.height >= 96 else { return nil }
        let size: CGFloat = rect.height >= 150 && rect.width >= 150 ? 34 : 26
        guard let image = iconImage(region.node, ink: ink, size: size) else { return nil }
        return Icon(image: image, size: size, stacked: true, fit: region.node?.isPackage ?? false)
    }

    private func leafIcon(_ leaf: FloorLeaf, ink: NSColor, rect: CGRect) -> Icon? {
        guard rect.width >= 110, rect.height >= 96, let image = iconImage(leaf.node, ink: ink, size: 24) else { return nil }
        return Icon(image: image, size: 24, stacked: true, fit: leaf.node?.isPackage ?? false)
    }

    /// Apps and other packages show their real icon (once loaded); folders and files a
    /// symbol in the label ink, so the block's colour stays the only colour.
    private func iconImage(_ node: FileNode?, ink: NSColor, size: CGFloat) -> NSImage? {
        guard let node else { return nil }
        if node.isPackage { return packageIcon(node) }
        let name = node.kind.symbolName ?? FloorStyle.symbolName(for: node)
        let config = NSImage.SymbolConfiguration(pointSize: size * 0.72, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [ink.withAlphaComponent(0.9)]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }

    /// Name (and size) at the top-left of `rect`. Two lines when there's room; for header
    /// strips, one line "Name  Size" when only one fits; name only when the size doesn't
    /// fit either. Nothing when not even a readable name fits.
    private func drawLabel(names: [String], details: [String], in rect: CGRect, style: TextStyle, inset: CGFloat,
                           ink: NSColor, detailInk: NSColor, allowInline: Bool, icon: Icon?) {
        // Small blocks get a tighter inset, so a short name still fits.
        let inset = min(inset, max(5, (allowInline ? rect.width : min(rect.width, rect.height)) * 0.09))
        let top = inset * 0.75
        var x = rect.minX + inset
        var w = rect.width - inset * 2
        var yTop = rect.maxY - top
        var h = rect.height - top - 3
        // Icon: stacked above the text, or inline before it.
        if let icon {
            if icon.stacked, h >= icon.size + 6 + style.nameH + style.detailH {
                drawIcon(icon, in: CGRect(x: x, y: yTop - icon.size - 2, width: icon.size, height: icon.size))
                yTop -= icon.size + 8
                h -= icon.size + 8
            } else if !icon.stacked, w > icon.size + 60 {
                drawIcon(icon, in: CGRect(x: x, y: yTop - (style.nameH + icon.size) / 2 - 1, width: icon.size, height: icon.size))
                x += icon.size + 6
                w -= icon.size + 6
            }
        }
        // Type steps down to 75 % before it truncates a name.
        var style = style
        var size = style.name.pointSize
        let floor = max(11, (size * 0.75).rounded())
        while size > floor, !names.contains(where: { ($0 as NSString).size(withAttributes: [.font: style.name]).width <= w }) {
            size -= 1
            style = TextStyle(name: size, detail: style.detail.pointSize, nameWeight: style.weight)
        }
        guard w >= 24, h >= style.nameH,
              let fitted = FloorNSView.fittedName(names, font: style.name, width: w) else { return }
        let nameAttrs: [NSAttributedString.Key: Any] = [.font: style.name, .foregroundColor: ink]
        let detailAttrs: [NSAttributedString.Key: Any] = [.font: style.detail, .foregroundColor: detailInk]
        let nameW = (fitted as NSString).size(withAttributes: nameAttrs).width
        // The longest detail that fits ("8.41 GB · 28%", then "8.41 GB").
        let measured = details.map { ($0, ($0 as NSString).size(withAttributes: detailAttrs).width) }
        let (detail, detailW) = measured.first { $0.1 <= w } ?? measured.last ?? ("", .greatestFiniteMagnitude)
        let y = yTop - style.nameH
        var detailOrigin: CGPoint?
        if h >= style.nameH + style.detailH, detailW <= w {
            detailOrigin = CGPoint(x: x, y: y - style.detailH)
        } else if allowInline, nameW + 8 + detailW <= w {
            detailOrigin = CGPoint(x: x + nameW + 8, y: y + (style.nameH - style.detailH) / 2 - 0.5)
        }
        (fitted as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: nameAttrs)
        if let detailOrigin {
            (detail as NSString).draw(at: detailOrigin, withAttributes: detailAttrs)
        }
    }

    private func drawIcon(_ icon: Icon, in rect: CGRect) {
        let size = icon.image.size
        guard size.width > 0, size.height > 0 else { return }
        // App icons scale to the square; symbols keep the size they were configured at.
        var scale = min(rect.width / size.width, rect.height / size.height)
        if !icon.fit { scale = min(1, scale) }
        let w = size.width * scale, h = size.height * scale
        icon.image.draw(in: CGRect(x: rect.minX, y: rect.midY - h / 2, width: w, height: h), from: .zero,
                        operation: .sourceOver, fraction: 1)
    }

    private func drawCentered(_ string: String) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: FloorStyle.roundedFont(size: 13, weight: .medium),
            .foregroundColor: FloorStyle.canvasInk(dark: dark).withAlphaComponent(0.7),
        ]
        let size = (string as NSString).size(withAttributes: attrs)
        (string as NSString).draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attrs)
    }
}
