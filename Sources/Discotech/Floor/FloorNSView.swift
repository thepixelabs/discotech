import AppKit
import QuartzCore

/// The Floor: the focused folder as a calm map of rounded blocks (a squarified treemap
/// with damped areas, see `FloorLayout`). It always fits the view; there is nothing to
/// scroll.
///
/// Drawing is split in two. Everything that only changes with the focus, the tree, the
/// size, the theme, the appearance or the Crate is rendered once into a cached bitmap.
/// Hover, emphasis and selection are drawn on top of it every frame as veils and
/// outlines, so moving the pointer never re-renders the floor. While the view is being
/// resized the last bitmap is scaled and the floor is laid out again once the size
/// settles.
final class FloorNSView: NSView {
    weak var appState: AppState?

    // Layouts, cached per focus / tree version / size.
    private struct LayoutKey: Hashable {
        let focus: ObjectIdentifier
        let tree: Int
        let width: Int
        let height: Int
    }
    private var layoutCache: [LayoutKey: FloorLayout] = [:]
    private var layoutOrder: [LayoutKey] = []
    var layout: FloorLayout?

    // Mirrored model state (set in `sync`).
    private var focus: FileNode?
    private var treeVersion = 0
    private var externalHover: FileNode?
    private var emphasized: Set<FileNode> = []
    private var collected: [FileNode] = []
    private var selected: FileNode?

    // Bitmaps.
    private struct ImageKey: Hashable {
        let layout: Int
        let theme: Theme
        let dark: Bool
        let scale: CGFloat
        let width: CGFloat
        let height: CGFloat
        let crate: [ObjectIdentifier]
    }
    private var images: [ImageKey: CGImage] = [:]
    private var imageOrder: [ImageKey] = []
    /// Last full frame's base bitmap and the bounds it was made for (resize stand-in).
    private var lastImage: CGImage?
    private var lastImageSize: CGSize = .zero

    // Resizing.
    private var settleTimer: Timer?

    // Focus transition.
    enum TransitionKind { case zoomIn, zoomOut, dissolve }
    struct Transition {
        let old: CGImage
        let kind: TransitionKind
        var anchor: CGRect?
        let anchorNode: FileNode?
        let start: CFTimeInterval
        let duration: CFTimeInterval
    }
    private var transition: Transition?
    #if DEBUG
    var debug = FloorDebugState()
    #endif

    // Pointer.
    private var pointerHit: FloorHit?
    private var isMouseInside = false
    private var trackingArea: NSTrackingArea?

    // Highlight: target opacity per region and per leaf, blended over `hoverBlendDuration`.
    private enum HoverTarget: Equatable { case none, hit(FloorHit), node(ObjectIdentifier) }
    private struct HighlightSignature: Equatable {
        let layout: Int
        let hover: HoverTarget
        let emphasis: Set<ObjectIdentifier>
        let selected: ObjectIdentifier?
    }
    private var highlightSignature: HighlightSignature?
    private var regionFrom: [CGFloat] = [], regionTo: [CGFloat] = []
    private var leafFrom: [CGFloat] = [], leafTo: [CGFloat] = []
    private var blendStart: CFTimeInterval = 0
    var blendProgress: CGFloat = 1
    /// A highlighted block: its resting rectangle (layout space), corner radius, and the
    /// colour whose hue `CanvasHighlight` glows in (nil = colourless, uses the accent).
    private struct HighlightShape {
        let rect: CGRect
        let radius: CGFloat
        let tint: NSColor?
    }
    private var hoverShapes: [HighlightShape] = []
    private var rimShape: HighlightShape?
    private var emphasisShapes: [HighlightShape] = []
    private var selectedShapes: [HighlightShape] = []

    private var displayLinkRef: CADisplayLink?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange),
                                               name: .discotechThemeDidChange, object: nil)
    }

    /// A new theme or "Colour by" mode: every cached bitmap, layout (it carries each block's
    /// paint) and highlight tint is stale. Show the new look directly (no zoom or dissolve).
    @objc private func themeDidChange() {
        layoutCache.removeAll()
        layoutOrder.removeAll()
        layout = nil
        images.removeAll()
        imageOrder.removeAll()
        lastImage = nil
        highlightSignature = nil
        needsDisplay = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { true }

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
    var reduceMotion: Bool { CanvasHighlight.systemReduceMotion }

    // MARK: - Sync

    func sync(focus: FileNode?, treeVersion: Int, hovered: FileNode?, emphasized: Set<FileNode>,
              collected: [FileNode], selected: FileNode?) {
        let focusChanged = focus !== self.focus
        let treeChanged = treeVersion != self.treeVersion
        if focusChanged, let old = lastImage, let oldFocus = self.focus, let newFocus = focus, lastImageSize == bounds.size {
            beginTransition(from: oldFocus, to: newFocus, oldImage: old)
        }
        if treeChanged {
            layoutCache.removeAll()
            layoutOrder.removeAll()
        }
        self.focus = focus
        self.treeVersion = treeVersion
        self.externalHover = hovered
        self.emphasized = emphasized
        self.collected = collected
        self.selected = selected
        if focusChanged || treeChanged {
            pointerHit = nil
        }
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    // MARK: - Geometry

    /// The rectangle the grid may use: the same side inset as the hover strip, so the
    /// floor's edges line up with it at every window size.
    private var gridArea: CGRect {
        CGRect(x: FloorStyle.outerPadding, y: FloorStyle.bottomPadding,
               width: max(0, bounds.width - FloorStyle.outerPadding * 2),
               height: max(0, bounds.height - FloorStyle.topPadding - FloorStyle.bottomPadding))
    }

    /// The grid fills `gridArea` exactly, so its origin is the area's.
    func geometry(for layout: FloorLayout) -> FloorGeometry {
        let area = gridArea
        return FloorGeometry(originX: area.minX, topY: area.maxY)
    }

    private func layoutKey(for focus: FileNode, size: CGSize) -> LayoutKey {
        LayoutKey(focus: ObjectIdentifier(focus), tree: treeVersion, width: Int(size.width.rounded()),
                  height: Int(size.height.rounded()))
    }

    /// Layout for the current focus and size, from the cache or built now.
    @discardableResult
    private func ensureLayout() -> FloorLayout? {
        guard let focus else { layout = nil; return nil }
        let size = gridArea.size
        guard size.width > 40, size.height > 40 else { return nil }
        let key = layoutKey(for: focus, size: size)
        if let cached = layoutCache[key] {
            if cached !== layout { highlightSignature = nil }
            layout = cached
            return cached
        }
        let started = CACurrentMediaTime()
        let built = FloorLayout(focus: focus, area: CGSize(width: size.width.rounded(), height: size.height.rounded()))
        #if DEBUG
        debugLogLayout(built, started: started)
        #endif
        layoutCache[key] = built
        layoutOrder.append(key)
        if layoutOrder.count > 8 { layoutCache[layoutOrder.removeFirst()] = nil }
        layout = built
        highlightSignature = nil
        return built
    }

    // MARK: - Resizing

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        guard changed else { return }
        if lastImage != nil {
            // Keep showing the last floor (scaled) until the size settles.
            settleTimer?.invalidate()
            settleTimer = Timer.scheduledTimer(withTimeInterval: FloorStyle.resizeSettle, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.settleTimer = nil
                if !self.inLiveResize { self.needsDisplay = true }
            }
        }
        needsDisplay = true
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        settleTimer?.invalidate()
        settleTimer = nil
        needsDisplay = true
    }

    private var isSettling: Bool { inLiveResize || settleTimer != nil }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let dark = isDark
        let bg = FloorStyle.background(effectiveAppearance)
        ctx.setFillColor(bg)
        ctx.fill(bounds)

        // Mid-resize: stretch the last frame to the new size (its edges stay on the new
        // margins) instead of laying out on every step; the real layout follows once the
        // size settles.
        if isSettling, let last = lastImage, lastImageSize != bounds.size, focus != nil {
            ctx.interpolationQuality = .medium
            ctx.draw(last, in: bounds)
            return
        }

        guard let layout = ensureLayout() else { return }
        advanceBlend()
        let geo = geometry(for: layout)
        guard let base = image(layout: layout, geo: geo, dark: dark) else { return }
        lastImage = base
        lastImageSize = bounds.size

        if var t = transition {
            let progress = min(1, (CACurrentMediaTime() - t.start) / t.duration)
            if progress < 1 {
                if t.anchor == nil, t.kind == .zoomOut, let node = t.anchorNode {
                    t.anchor = viewRect(of: node, in: layout, geo: geo)
                    transition = t
                }
                drawTransition(ctx, t, new: base, progress: CGFloat(progress))
                #if DEBUG
                debug.transitionFrames += 1
                #endif
                return
            }
            #if DEBUG
            debugTransitionEnded(t)
            #endif
            transition = nil
        }

        ctx.draw(base, in: bounds)
        guard !layout.isEmpty else { return }

        refreshHighlight(layout: layout)
        drawOverlay(ctx, layout: layout, geo: geo, dark: dark)
        #if DEBUG
        runDebugHooks(layout: layout, geo: geo)
        #endif
    }

    private func image(layout: FloorLayout, geo: FloorGeometry, dark: Bool) -> CGImage? {
        let scale = window?.backingScaleFactor ?? 2
        let key = ImageKey(layout: layout.id, theme: Theme.current, dark: dark, scale: scale, width: bounds.width,
                           height: bounds.height, crate: collected.map(ObjectIdentifier.init))
        if let cached = images[key] { return cached }
        let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
        guard w > 0, h > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let started = CACurrentMediaTime()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            renderStatic(ctx, layout: layout, geo: geo, dark: dark)
        }
        NSGraphicsContext.restoreGraphicsState()
        #if DEBUG
        debugLogRender(started: started, scale: scale)
        #endif
        guard let made = ctx.makeImage() else { return nil }
        images[key] = made
        imageOrder.append(key)
        if imageOrder.count > 6 { images[imageOrder.removeFirst()] = nil }
        return made
    }

    // MARK: - Static rendering

    /// Package icons not loaded yet; once they are, the bitmaps are made again.
    private var iconRequests: Set<String> = []

    private func renderStatic(_ ctx: CGContext, layout: FloorLayout, geo: FloorGeometry, dark: Bool) {
        var missing: [FileNode] = []
        let painter = FloorPainter(ctx: ctx, layout: layout, geo: geo, bounds: bounds, dark: dark,
                                   background: FloorStyle.background(effectiveAppearance),
                                   crateRects: markRects(collected, in: layout),
                                   packageIcon: { node in
                                       if let hit = IconCache.shared.cached(node.path) { return hit }
                                       missing.append(node)
                                       return nil
                                   })
        painter.render()
        requestIcons(missing)
    }

    private func requestIcons(_ nodes: [FileNode]) {
        let fresh = nodes.filter { !iconRequests.contains($0.path) }
        guard !fresh.isEmpty else { return }
        for node in fresh { iconRequests.insert(node.path) }
        Task { @MainActor [weak self] in
            for node in fresh { _ = await IconCache.shared.icon(for: node.path, isDirectory: node.isDirectory) }
            guard let self else { return }
            self.images.removeAll()
            self.imageOrder.removeAll()
            self.needsDisplay = true
        }
    }

    /// The label text in `width` points: the first candidate that fits whole ("Xcode.app",
    /// then "Xcode"); else the last candidate middle-truncated, still showing at least 6
    /// characters and 60% of it (or 10+ characters of a long one). `nil` when none fits;
    /// a label like "Co…ts" tells nobody anything.
    static func fittedName(_ candidates: [String], font: NSFont, width: CGFloat) -> String? {
        func measure(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: [.font: font]).width }
        for candidate in candidates where measure(candidate) <= width { return candidate }
        guard let last = candidates.last, !last.hasSuffix(" items"), !last.hasSuffix(" item") else { return nil }
        let chars = Array(last)
        var keep = chars.count - 1
        while keep >= 6, Double(keep) >= Double(chars.count) * 0.6 || keep >= 10 {
            let head = (keep + 1) / 2, tail = keep - head
            let s = String(chars[..<head]) + "…" + String(chars[(chars.count - tail)...])
            if measure(s) <= width { return s }
            keep -= 1
        }
        return nil
    }

    // MARK: - Transition

    private func beginTransition(from oldFocus: FileNode, to newFocus: FileNode, oldImage: CGImage) {
        let kind: TransitionKind
        var anchor: CGRect?
        var anchorNode: FileNode?
        if reduceMotion {
            kind = .dissolve
        } else if newFocus.isDescendant(of: oldFocus), let layout, layout.focus === oldFocus {
            kind = .zoomIn
            anchor = viewRect(of: newFocus, in: layout, geo: geometry(for: layout))
        } else if oldFocus.isDescendant(of: newFocus) {
            kind = .zoomOut
            anchorNode = oldFocus
        } else {
            kind = .dissolve
        }
        let isZoom = kind != .dissolve && (anchor != nil || anchorNode != nil)
        transition = Transition(old: oldImage, kind: isZoom ? kind : .dissolve, anchor: anchor, anchorNode: anchorNode,
                                start: CACurrentMediaTime(),
                                duration: isZoom ? FloorStyle.zoomDuration : FloorStyle.dissolveDuration)
        startTicking()
    }

    /// View rectangle covering `node` on `layout`.
    private func viewRect(of node: FileNode, in layout: FloorLayout, geo: FloorGeometry) -> CGRect? {
        var used: [Int: Int] = [:]
        guard let mark = layout.mark(for: node, used: &used) else { return nil }
        let rects = layout.rects(for: mark).map { geo.view($0.0) }
        guard let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    private func drawTransition(_ ctx: CGContext, _ t: Transition, new: CGImage, progress: CGFloat) {
        let p = t.kind == .dissolve ? progress : Self.ease(progress)
        let full = bounds
        func lerp(_ a: CGRect, _ b: CGRect, _ k: CGFloat) -> CGRect {
            CGRect(x: a.minX + (b.minX - a.minX) * k, y: a.minY + (b.minY - a.minY) * k,
                   width: a.width + (b.width - a.width) * k, height: a.height + (b.height - a.height) * k)
        }
        /// Where the whole image lands when `a` is stretched to fill the view.
        func blownUp(_ a: CGRect) -> CGRect {
            let sx = full.width / max(1, a.width), sy = full.height / max(1, a.height)
            return CGRect(x: full.minX - (a.minX - full.minX) * sx, y: full.minY - (a.minY - full.minY) * sy,
                          width: full.width * sx, height: full.height * sy)
        }
        ctx.saveGState()
        ctx.clip(to: full)
        ctx.interpolationQuality = .medium
        switch (t.kind, t.anchor) {
        case (.zoomIn, let a?):
            ctx.saveGState(); ctx.setAlpha(p); ctx.draw(new, in: lerp(a, full, p)); ctx.restoreGState()
            ctx.saveGState(); ctx.setAlpha(1 - p); ctx.draw(t.old, in: lerp(full, blownUp(a), p)); ctx.restoreGState()
        case (.zoomOut, let a?):
            ctx.saveGState(); ctx.setAlpha(p); ctx.draw(new, in: lerp(blownUp(a), full, p)); ctx.restoreGState()
            ctx.saveGState(); ctx.setAlpha(1 - p); ctx.draw(t.old, in: lerp(full, a, p)); ctx.restoreGState()
        default:
            ctx.saveGState(); ctx.setAlpha(1 - p); ctx.draw(t.old, in: full); ctx.restoreGState()
            ctx.saveGState(); ctx.setAlpha(p); ctx.draw(new, in: full); ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    /// cubic-bezier(0.4, 0, 0.2, 1), the app's state-change curve.
    private static func ease(_ x: CGFloat) -> CGFloat {
        let (x1, y1, x2, y2): (CGFloat, CGFloat, CGFloat, CGFloat) = (0.4, 0, 0.2, 1)
        func bez(_ t: CGFloat, _ a: CGFloat, _ b: CGFloat) -> CGFloat {
            let u = 1 - t
            return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
        }
        var lo: CGFloat = 0, hi: CGFloat = 1, t = x
        for _ in 0..<24 {
            t = (lo + hi) / 2
            if bez(t, x1, x2) < x { lo = t } else { hi = t }
        }
        return bez(t, y1, y2)
    }

    // MARK: - Highlight overlay

    /// Resting rectangles standing for `nodes` (a node nested inside another in the list
    /// counts once; several small items in one block stack instead of overlapping).
    private func markRects(_ nodes: some Sequence<FileNode>, in layout: FloorLayout) -> [(CGRect, CGFloat)] {
        marks(nodes, in: layout).flatMap { layout.rects(for: $0) }
    }

    private func marks(_ nodes: some Sequence<FileNode>, in layout: FloorLayout) -> [FloorMark] {
        let list = Array(nodes)
        guard !list.isEmpty else { return [] }
        let set = Set(list.map(ObjectIdentifier.init))
        var used: [Int: Int] = [:]
        var out: [FloorMark] = []
        for node in list {
            var p = node.parent, covered = false
            while let cur = p { if set.contains(ObjectIdentifier(cur)) { covered = true; break }; p = cur.parent }
            if covered { continue }
            if let mark = layout.mark(for: node, used: &used) { out.append(mark) }
        }
        // Small items stacked in one block read as one band, not a ladder of outlines.
        var bands: [Int: (first: Int, end: Int)] = [:]
        var merged: [FloorMark] = []
        for mark in out {
            if case .partial(let leaf, let first, let count) = mark {
                let cur = bands[leaf] ?? (first, first + count)
                bands[leaf] = (min(cur.first, first), max(cur.end, first + count))
            } else {
                merged.append(mark)
            }
        }
        for (leaf, band) in bands.sorted(by: { $0.key < $1.key }) {
            merged.append(.partial(leaf: leaf, first: band.first, count: band.end - band.first))
        }
        return merged
    }

    private func currentHoverTarget() -> HoverTarget {
        if isMouseInside {
            if let pointerHit { return .hit(pointerHit) }
            return .none
        }
        if let node = externalHover { return .node(ObjectIdentifier(node)) }
        return .none
    }

    /// Regions and leaves a mark touches.
    private func members(of mark: FloorMark, in layout: FloorLayout) -> (regions: Set<Int>, leaves: Set<Int>) {
        switch mark {
        case .regions(let list):
            return (Set(list), Set(list.flatMap { Array(layout.regions[$0].leaves) }))
        case .leaves(let list):
            return (Set(list.map { layout.leaves[$0].region }), Set(list))
        case .partial(let leaf, _, _):
            return ([layout.leaves[leaf].region], [leaf])
        }
    }

    private func refreshHighlight(layout: FloorLayout) {
        let hover = currentHoverTarget()
        let signature = HighlightSignature(layout: layout.id, hover: hover,
                                           emphasis: Set(emphasized.map(ObjectIdentifier.init)),
                                           selected: selected.map(ObjectIdentifier.init))
        guard signature != highlightSignature else { return }
        let layoutChanged = highlightSignature?.layout != signature.layout
        highlightSignature = signature

        var hoverMark: FloorMark?
        switch hover {
        case .none: break
        case .hit(.region(let ri)): hoverMark = .regions([ri])
        case .hit(.leaf(let li)): hoverMark = .leaves([li])
        case .node:
            if let node = externalHover {
                var used: [Int: Int] = [:]
                hoverMark = layout.mark(for: node, used: &used)
            }
        }
        hoverShapes = hoverMark.map { shapes(for: $0, in: layout) } ?? []
        rimShape = nil
        let emphasisMarks = marks(emphasized, in: layout)
        emphasisShapes = emphasisMarks.flatMap { shapes(for: $0, in: layout) }
        selectedShapes = selected.map { marks([$0], in: layout).flatMap { shapes(for: $0, in: layout) } } ?? []

        var regionTarget = [CGFloat](repeating: 1, count: layout.regions.count)
        var leafTarget = [CGFloat](repeating: 1, count: layout.leaves.count)
        if let hoverMark {
            let (rs, ls) = members(of: hoverMark, in: layout)
            let wholeRegions: Bool
            if case .regions = hoverMark { wholeRegions = true } else { wholeRegions = false }
            for ri in layout.regions.indices where !rs.contains(ri) { regionTarget[ri] = FloorStyle.dimAlpha }
            if !wholeRegions {
                for ri in rs where layout.regions[ri].isSubdivided {
                    rimShape = shapes(for: .regions([ri]), in: layout).first
                    for li in layout.regions[ri].leaves where !ls.contains(li) { leafTarget[li] = FloorStyle.siblingAlpha }
                }
            }
        } else if !emphasisMarks.isEmpty {
            var rs = Set<Int>(), ls = Set<Int>()
            for mark in emphasisMarks {
                let m = members(of: mark, in: layout)
                rs.formUnion(m.regions); ls.formUnion(m.leaves)
            }
            for ri in layout.regions.indices where !rs.contains(ri) { regionTarget[ri] = FloorStyle.dimAlpha }
            for ri in rs where layout.regions[ri].isSubdivided {
                for li in layout.regions[ri].leaves where !ls.contains(li) { leafTarget[li] = FloorStyle.dimAlpha }
            }
        }

        // The selection is where the user is; hovering elsewhere never fades it out.
        if let selected {
            for mark in marks([selected], in: layout) {
                let (rs, ls) = members(of: mark, in: layout)
                for ri in rs { regionTarget[ri] = 1 }
                for li in ls { leafTarget[li] = 1 }
            }
        }

        if layoutChanged || reduceMotion || regionTo.count != regionTarget.count || leafTo.count != leafTarget.count {
            regionFrom = regionTarget; regionTo = regionTarget
            leafFrom = leafTarget; leafTo = leafTarget
            blendProgress = 1
        } else {
            regionFrom = blended(regionFrom, regionTo); regionTo = regionTarget
            leafFrom = blended(leafFrom, leafTo); leafTo = leafTarget
            blendProgress = 0
            blendStart = CACurrentMediaTime()
            startTicking()
        }
    }

    private func blended(_ from: [CGFloat], _ to: [CGFloat]) -> [CGFloat] {
        guard blendProgress < 1, from.count == to.count else { return to }
        return zip(from, to).map { $0 + ($1 - $0) * blendProgress }
    }

    private func drawOverlay(_ ctx: CGContext, layout: FloorLayout, geo: FloorGeometry, dark: Bool) {
        let bg = FloorStyle.background(effectiveAppearance)
        let regionAlpha = blended(regionFrom, regionTo)
        let leafAlpha = blended(leafFrom, leafTo)
        func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
            let v = geo.view(r)
            let c = min(radius, min(v.width, v.height) / 2)
            return CGPath(roundedRect: v, cornerWidth: c, cornerHeight: c, transform: nil)
        }

        // Veils: dim what isn't highlighted.
        ctx.saveGState()
        for (ri, region) in layout.regions.enumerated() where ri < regionAlpha.count && regionAlpha[ri] < 0.999 {
            ctx.addPath(rounded(region.rect.insetBy(dx: -0.5, dy: -0.5), layout.regionRadius(region.rect)))
            ctx.setFillColor(bg.copy(alpha: 1 - regionAlpha[ri]) ?? bg)
            ctx.fillPath()
        }
        for (li, leaf) in layout.leaves.enumerated() where li < leafAlpha.count && leafAlpha[li] < 0.999 && leaf.depth == 1 {
            ctx.addPath(rounded(leaf.rect, layout.leafRadius(leaf)))
            ctx.setFillColor(bg.copy(alpha: 1 - leafAlpha[li]) ?? bg)
            ctx.fillPath()
        }
        ctx.restoreGState()

        // Highlights: lineage rim, Findings emphasis, selection, then hover on top (a
        // hovered selection shows both rings). The hover fades in with the veils.
        let hc = CanvasHighlight.systemIncreaseContrast || CanvasHighlight.isHighContrast(effectiveAppearance)
        func draw(_ list: [HighlightShape], _ state: CanvasHighlight.State, opacity: CGFloat = 1) {
            for shape in list where !shape.rect.isEmpty {
                CanvasHighlight.draw(state, rect: geo.view(shape.rect), radius: shape.radius, tint: shape.tint, dark: dark,
                                     in: ctx, increaseContrast: hc, opacity: opacity)
            }
        }
        if let rimShape { draw([rimShape], .ancestor, opacity: blendProgress) }
        draw(emphasisShapes, .emphasized)
        draw(selectedShapes, .selected)
        draw(hoverShapes, .hovered, opacity: blendProgress)
    }

    /// Highlight shapes for a mark, each tinted with its block's own fill.
    private func shapes(for mark: FloorMark, in layout: FloorLayout) -> [HighlightShape] {
        func tint(region ri: Int) -> NSColor? {
            let region = layout.regions[ri]
            guard region.kind == .item, !region.isOther, let paint = region.paint else { return nil }
            return FloorStyle.swatch(paint, dark: isDark)
        }
        func leafTint(_ li: Int) -> NSColor? {
            let leaf = layout.leaves[li]
            guard leaf.kind == .item else { return nil }
            if let paint = leaf.paint { return FloorStyle.swatch(paint, dark: isDark) }
            return tint(region: leaf.region)
        }
        switch mark {
        case .regions(let list):
            return list.map { HighlightShape(rect: layout.regions[$0].rect, radius: layout.regionRadius(layout.regions[$0].rect),
                                             tint: tint(region: $0)) }
        case .leaves(let list):
            return list.map { HighlightShape(rect: layout.leaves[$0].rect, radius: layout.leafRadius(layout.leaves[$0]),
                                             tint: leafTint($0)) }
        case .partial(let leaf, let first, let count):
            let band = layout.bandRect(ofLeaf: leaf, first: first, count: count)
            return [HighlightShape(rect: band, radius: min(layout.leafRadius(layout.leaves[leaf]), band.height / 2), tint: leafTint(leaf))]
        }
    }

    // MARK: - Highlight blend

    /// Current highlight blend progress, from the clock.
    private func advanceBlend() {
        guard blendProgress < 1 else { return }
        let now = CACurrentMediaTime()
        blendProgress = reduceMotion ? 1 : CGFloat(min(1, (now - blendStart) / FloorStyle.hoverBlendDuration))
        #if DEBUG
        debugFadeFrame()
        #endif
    }

    private var hasRunningAnimation: Bool {
        if let transition, CACurrentMediaTime() - transition.start < transition.duration { return true }
        return blendProgress < 1
    }

    // MARK: - Animation

    private func startTicking() {
        needsDisplay = true
        // Backstop: land on the final frame even if the display link doesn't fire
        // (occluded window, sleeping display).
        DispatchQueue.main.asyncAfter(deadline: .now() + max(FloorStyle.zoomDuration, FloorStyle.hoverBlendDuration) + 0.05) { [weak self] in
            self?.needsDisplay = true
        }
        guard displayLinkRef == nil, window != nil else { return }
        let link = displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLinkRef = link
    }

    /// The display link only asks for frames; `draw` reads every animation from the clock.
    @objc private func tick() {
        needsDisplay = true
        if !hasRunningAnimation {
            displayLinkRef?.invalidate()
            displayLinkRef = nil
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            displayLinkRef?.invalidate()
            displayLinkRef = nil
        }
        #if DEBUG
        if window != nil { scheduleScrollSelfTest() }
        #endif
    }

    // MARK: - Mouse

    private func hit(at point: CGPoint) -> FloorHit? {
        guard let layout = ensureLayout() else { return nil }
        let geo = geometry(for: layout)
        return layout.hit(geo.layout(point))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isMouseInside = true }

    override func mouseMoved(with event: NSEvent) {
        pointerMoved(to: convert(event.locationInWindow, from: nil))
    }

    func pointerMoved(to point: CGPoint) {
        guard !isSettling else { return }
        isMouseInside = true
        let found = hit(at: point)
        if found != pointerHit {
            pointerHit = found
            needsDisplay = true
        }
        let node = found.flatMap { layout?.node(for: $0) }
        if appState?.hovered !== node {
            appState?.hovered = node
            externalHover = node
        }
    }

    override func mouseExited(with event: NSEvent) {
        isMouseInside = false
        if pointerHit != nil { pointerHit = nil; needsDisplay = true }
        if appState?.hovered != nil {
            appState?.hovered = nil
            externalHover = nil
        }
    }

    override func mouseDown(with event: NSEvent) {
        click(at: convert(event.locationInWindow, from: nil))
    }

    func click(at point: CGPoint) {
        guard let appState else { return }
        guard let found = hit(at: point), let layout else {
            appState.zoomOut() // background: back up one level
            return
        }
        switch found {
        case .region(let ri):
            if let node = layout.regions[ri].node, node.isDirectory { appState.zoom(into: node) }
        case .leaf(let li):
            let leaf = layout.leaves[li]
            if let node = leaf.node {
                if node.isDirectory, !node.isPackage || !node.children.isEmpty {
                    appState.zoom(into: node)
                } else {
                    appState.selected = node
                    appState.hovered = node
                    externalHover = node
                }
            } else if let parent = leaf.bucketParent, parent !== layout.focus {
                // "Everything else" inside a region: go into that folder, where they get room.
                appState.zoom(into: parent)
            }
        }
    }

    // MARK: - Scroll navigation

    /// The whole floor always fits the view, so vertical scroll walks the hierarchy
    /// instead, exactly like the Ball: up goes into the folder under the pointer, down
    /// goes out to the enclosing folder. Both use the same `zoom(into:)` / `zoomOut()` a
    /// click or the back control makes, so the zoom transition and the state are identical.
    /// The gesture rules (thresholds, momentum, cooldown) are `ScrollLevelNavigator`.
    private var scrollNavigator = ScrollLevelNavigator()

    override func scrollWheel(with event: NSEvent) {
        if !navigate(byScroll: event, at: convert(event.locationInWindow, from: nil)) {
            super.scrollWheel(with: event)
        }
    }

    /// Handles one scroll event at `point` (view coordinates). Returns false for events
    /// that aren't the Floor's to take (mostly horizontal, or nothing laid out yet), which
    /// then travel up the responder chain as before.
    func navigate(byScroll event: NSEvent, at point: CGPoint) -> Bool {
        guard appState != nil, focus != nil else { return false }
        return scrollNavigator.handle(event) { [weak self] inward in
            guard let self, let appState = self.appState else { return }
            if inward {
                if let target = self.scrollTarget(at: point) { appState.zoom(into: target) }
            } else {
                appState.zoomOut()
            }
        }
    }

    /// The folder a scroll up goes into: whatever a click at the pointer would open (the
    /// child block's own folder when over one inside a region, else the region's; an
    /// "Everything else" block opens its parent folder), else the selected item if it is
    /// an openable folder inside the focus, else none.
    private func scrollTarget(at point: CGPoint) -> FileNode? {
        func opens(_ node: FileNode) -> Bool {
            node.isDirectory && (!node.isPackage || !node.children.isEmpty)
        }
        if let found = hit(at: point), let layout {
            switch found {
            case .region(let ri):
                if let node = layout.regions[ri].node, node.isDirectory { return node }
            case .leaf(let li):
                let leaf = layout.leaves[li]
                if let node = leaf.node {
                    if opens(node) { return node }
                } else if let parent = leaf.bucketParent, parent !== layout.focus {
                    return parent
                }
            }
        }
        if let selected = appState?.selected, let focus = appState?.focus,
           selected !== focus, selected.isDescendant(of: focus), opens(selected) {
            return selected
        }
        return nil
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let appState, let found = hit(at: convert(event.locationInWindow, from: nil)), let layout else {
            super.rightMouseDown(with: event)
            return
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        func note(_ text: String) {
            let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        let node: FileNode?
        switch found {
        case .region(let ri): node = layout.regions[ri].node
        case .leaf(let li):
            node = layout.leaves[li].node
            if node == nil {
                let leaf = layout.leaves[li]
                note("\(leaf.displayName), each too small for its own block")
                if let parent = leaf.bucketParent, parent !== layout.focus {
                    menu.addItem(FloorMenuItem(title: "Go Into \(parent.name)") { appState.zoom(into: parent) })
                }
                NSMenu.popUpContextMenu(menu, with: event, for: self)
                return
            }
        }
        guard let node else { return }
        if node.isSynthetic {
            note(node.kind.explanation ?? "Not a file")
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        menu.addItem(FloorMenuItem(title: "Quick Look") { QuickLookController.shared.preview(node) })
        menu.addItem(FloorMenuItem(title: "Show in Finder") { appState.revealInFinder(node) })
        menu.addItem(FloorMenuItem(title: "Open") { appState.open(node) })
        menu.addItem(.separator())
        if appState.collected.contains(where: { $0 === node }) {
            menu.addItem(FloorMenuItem(title: "Take Out of \(Brand.crate)") { appState.uncollect(node) })
        } else if let reason = appState.collectBlockReason(node) {
            let add = FloorMenuItem(title: "Add to \(Brand.crate)") {}
            add.isEnabled = false
            menu.addItem(add)
            note(reason)
        } else if appState.isCollected(node) {
            note("Already in the \(Brand.crate) with its folder")
        } else {
            menu.addItem(FloorMenuItem(title: "Add to \(Brand.crate)") { appState.collect(node) })
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

/// Menu item with a closure action, for the Floor's right-click menu.
final class FloorMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func invoke() { handler() }
}
