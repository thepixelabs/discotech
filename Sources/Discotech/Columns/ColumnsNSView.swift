import AppKit
import QuartzCore

/// Layers: the focused folder as a left-to-right partition (icicle) chart. Column 1 splits
/// `state.focus`'s children by exact proportional height; column 2 splits each of *those*
/// children's own children inside the vertical span it already owns; and so on for however
/// many columns fit the window (see `ColumnsGeometry`). Every visible band's length is
/// simultaneously proportional to its size within its parent's span, which is what makes
/// this a true macro view — unlike the old Miller-columns implementation, where each column
/// was only proportional to itself and a deep drill path scrolled the earliest column into
/// an unreadable sliver.
///
/// A plain layer-backed `NSView`, not SwiftUI, for the same reasons as `SunburstNSView` and
/// `FloorNSView`: precise hit testing for the right-click menu, and a manual repaint that
/// never re-lays-out on hover alone.
final class ColumnsNSView: NSView {
    weak var appState: AppState?

    // MARK: Layout cache (rebuilt only on focus/tree/size change — see `ensureLayout`)

    var layout: LayersLayout?
    private var layoutFocus: FileNode?
    private var layoutTreeVersion = -1
    private var layoutSize: CGSize = .zero
    var columnWidths: [CGFloat] = []

    // Mirrored model state (set in `sync`).
    private var lastFocus: FileNode?
    private var lastTreeVersion: Int = -1
    private var lastExternalHover: FileNode?
    private var lastEmphasized: Set<FileNode> = []
    private var lastSelected: FileNode?

    // Pointer.
    private var hoveredLocation: (column: Int, index: Int)?
    private var isMouseInside = false
    private var trackingArea: NSTrackingArea?

    // Focus-change cross-fade: a snapshot of the view right before the focus changes,
    // faded out while the freshly-laid-out new focus draws underneath at rising alpha —
    // the same technique `FloorNSView` uses for its own focus change.
    private var fadingImage: CGImage?
    private var fadeStart: CFTimeInterval = 0
    private var fadeProgress: CGFloat = 1
    private var displayLinkRef: CADisplayLink?

    #if DEBUG
    var debug = ColumnsDebugState()
    #endif

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true } // top-down, like a document — matches the header row sitting at the top
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var isDarkAppearance: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // MARK: - External sync

    /// First-time setup: records the starting focus without animating (there's nothing to
    /// fade from yet).
    func prime(focus: FileNode?, treeVersion: Int) {
        lastFocus = focus
        lastTreeVersion = treeVersion
    }

    /// Called from `ColumnsRepresentable.updateNSView` on every state change.
    func sync(focus: FileNode?, treeVersion: Int, externalHover: FileNode?, emphasized: Set<FileNode>, selected: FileNode?) {
        if externalHover !== lastExternalHover {
            lastExternalHover = externalHover
            needsDisplay = true
        }
        if emphasized != lastEmphasized {
            lastEmphasized = emphasized
            needsDisplay = true
        }
        if selected !== lastSelected {
            lastSelected = selected
            needsDisplay = true
        }
        guard let focus else { return }
        if focus !== lastFocus || treeVersion != lastTreeVersion {
            if focus !== lastFocus { captureSnapshotForFade() }
            lastFocus = focus
            lastTreeVersion = treeVersion
            hoveredLocation = nil
            needsDisplay = true
            #if DEBUG
            debug = ColumnsDebugState()
            #endif
        }
    }

    // MARK: - Layout

    private func ensureLayout() {
        let size = bounds.size
        if let layoutFocus, layoutFocus === lastFocus, layoutTreeVersion == lastTreeVersion,
           abs(layoutSize.width - size.width) < 0.5, abs(layoutSize.height - size.height) < 0.5 {
            return
        }
        guard let focus = lastFocus, size.width > 0, size.height > 0 else {
            layout = nil
            columnWidths = []
            return
        }
        columnWidths = ColumnsGeometry.columnWidths(totalWidth: size.width)
        let contentHeight = max(0, size.height - ColumnsConstants.headerHeight)
        let built = LayersLayout.build(focus: focus, contentHeight: contentHeight, maxColumns: columnWidths.count)
        // The tree might be shallower than the window has room for (a folder of files
        // only, a package with one thin level) — re-widen to however many columns the
        // tree actually populated, so the last one absorbs the leftover width instead of
        // leaving a dead band of empty canvas.
        if built.columns.count > 0, built.columns.count < columnWidths.count {
            columnWidths = ColumnsGeometry.columnWidths(totalWidth: size.width, cap: built.columns.count)
        }
        layout = built
        layoutFocus = focus
        layoutTreeVersion = lastTreeVersion
        layoutSize = size
    }

    func columnX(_ index: Int) -> CGFloat {
        var x = ColumnsConstants.spineWidth + ColumnsConstants.columnGutter
        for i in 0..<index { x += columnWidths[i] + ColumnsConstants.columnGutter }
        return x
    }

    private func isSplittable(_ node: FileNode) -> Bool {
        node.isDirectory && node.size > 0 && node.children.contains { $0.size > 0 }
    }

    /// Mirrors `AppState.zoom(into:)`'s own guard, so a chevron/click never promises a
    /// zoom that would silently no-op.
    private func isZoomable(_ node: FileNode) -> Bool {
        node.isDirectory && (!node.isPackage || !node.children.isEmpty)
    }

    // MARK: - Hit testing

    private enum HitRegion { case spine; case band(column: Int, index: Int); case none }

    private func hitRegion(at point: CGPoint) -> HitRegion {
        guard point.x >= 0, point.y >= 0, point.y < bounds.height else { return .none }
        if point.x < ColumnsConstants.spineWidth { return .spine }
        guard let layout, !columnWidths.isEmpty, point.y >= ColumnsConstants.headerHeight else { return .none }
        let y = point.y - ColumnsConstants.headerHeight
        var x = ColumnsConstants.spineWidth + ColumnsConstants.columnGutter
        for (c, width) in columnWidths.enumerated() {
            if point.x >= x, point.x < x + width {
                guard c < layout.columns.count else { return .none }
                if let i = layout.columns[c].bands.firstIndex(where: { y >= $0.y && y < $0.y + $0.height }) {
                    return .band(column: c, index: i)
                }
                return .none
            }
            x += width + ColumnsConstants.columnGutter
        }
        return .none
    }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let ta = NSTrackingArea(rect: bounds,
                                 options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                                 owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func mouseEntered(with event: NSEvent) { isMouseInside = true }

    override func mouseMoved(with event: NSEvent) {
        performHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        isMouseInside = false
        if hoveredLocation != nil { hoveredLocation = nil; needsDisplay = true }
        if appState?.hovered != nil {
            appState?.hovered = nil
            lastExternalHover = nil
        }
    }

    func performHover(at point: CGPoint) {
        isMouseInside = true
        var newLocation: (column: Int, index: Int)?
        var newHoverNode: FileNode?
        if case .band(let c, let i) = hitRegion(at: point) {
            newLocation = (c, i)
            newHoverNode = layout?.columns[c].bands[i].node
        }
        if newLocation?.column != hoveredLocation?.column || newLocation?.index != hoveredLocation?.index {
            hoveredLocation = newLocation
            needsDisplay = true
        }
        if appState?.hovered !== newHoverNode {
            appState?.hovered = newHoverNode
            lastExternalHover = newHoverNode
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        performClick(at: convert(event.locationInWindow, from: nil))
    }

    /// Folder → zoom in; file → select; the spine or any empty canvas area → zoom out.
    /// Matches the Ball's center orb and the Floor's background-click convention — one
    /// mechanism for "go back" across every canvas mode.
    func performClick(at point: CGPoint) {
        guard case .band(let c, let i) = hitRegion(at: point), let layout,
              c < layout.columns.count, i < layout.columns[c].bands.count else {
            appState?.zoomOut()
            return
        }
        let band = layout.columns[c].bands[i]
        if band.isBucket {
            if let parent = band.bucketParent, parent !== layout.focus { appState?.zoom(into: parent) }
            return
        }
        guard let node = band.node else { return }
        // A band that absorbed a pass-through chain ("Suite.app › Contents") zooms into
        // the chain's *resolved* end, not the shallow node — that's where the label and
        // the next column's children (if any were visible) both already point.
        let target = band.childSource ?? node
        if isZoomable(target) {
            appState?.zoom(into: target)
        } else {
            appState?.selected = node
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard case .band(let c, let i) = hitRegion(at: point), let layout,
              c < layout.columns.count, i < layout.columns[c].bands.count, let appState else {
            super.rightMouseDown(with: event)
            return
        }
        let band = layout.columns[c].bands[i]
        let menu = NSMenu()
        menu.autoenablesItems = false // so a blocked "Add to Crate" can show disabled
        func note(_ text: String) {
            let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        guard let node = band.node else {
            note(band.bucketCount == 1 ? "1 smaller item" : "\(band.bucketCount) smaller items")
            if let parent = band.bucketParent, parent !== layout.focus {
                menu.addItem(SunburstClosureMenuItem(title: "Go Into \(parent.name)") { appState.zoom(into: parent) })
            }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        if node.isSynthetic {
            note(node.kind.explanation ?? "Not a file")
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        menu.addItem(SunburstClosureMenuItem(title: "Quick Look") { QuickLookController.shared.preview(node) })
        menu.addItem(SunburstClosureMenuItem(title: "Show in Finder") { appState.revealInFinder(node) })
        menu.addItem(SunburstClosureMenuItem(title: "Open") { appState.open(node) })
        menu.addItem(.separator())
        if appState.collected.contains(where: { $0 === node }) {
            menu.addItem(SunburstClosureMenuItem(title: "Take Out of \(Brand.crate)") { appState.uncollect(node) })
        } else if let reason = appState.collectBlockReason(node) {
            let add = SunburstClosureMenuItem(title: "Add to \(Brand.crate)") {}
            add.isEnabled = false
            menu.addItem(add)
            note(reason)
        } else if appState.isCollected(node) {
            note("Already in the \(Brand.crate) with its folder")
        } else {
            menu.addItem(SunburstClosureMenuItem(title: "Add to \(Brand.crate)") { appState.collect(node) })
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    // MARK: - Focus-change cross-fade

    private func captureSnapshotForFade() {
        guard !reduceMotion, lastFocus != nil, bounds.width > 1, bounds.height > 1 else { return }
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return }
        cacheDisplay(in: bounds, to: rep)
        fadingImage = rep.cgImage
        fadeProgress = 0
        fadeStart = CACurrentMediaTime()
        startTicking()
    }

    private func startTicking() {
        guard displayLinkRef == nil else { return }
        let link = displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLinkRef = link
    }

    @objc private func tick() {
        guard fadeProgress < 1 else {
            displayLinkRef?.invalidate()
            displayLinkRef = nil
            return
        }
        let elapsed = CACurrentMediaTime() - fadeStart
        fadeProgress = CGFloat(min(1, elapsed / ColumnsConstants.focusFadeDuration))
        needsDisplay = true
        if fadeProgress >= 1 {
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
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ensureLayout()
        let dark = isDarkAppearance
        if fadeProgress < 1, let old = fadingImage {
            let t = 1 - pow(1 - Double(fadeProgress), 3) // ease-out, matches the Ball's zoom easing
            ctx.saveGState(); ctx.setAlpha(CGFloat(1 - t)); ctx.draw(old, in: bounds); ctx.restoreGState()
            ctx.saveGState(); ctx.setAlpha(CGFloat(t)); drawContent(ctx, dark: dark); ctx.restoreGState()
        } else {
            fadingImage = nil
            drawContent(ctx, dark: dark)
        }
        #if DEBUG
        runDebugHooks()
        #endif
    }

    private func drawContent(_ ctx: CGContext, dark: Bool) {
        ctx.setFillColor(FloorStyle.background(effectiveAppearance))
        ctx.fill(bounds)
        guard let focus = lastFocus else { return }
        drawSpine(ctx, focus: focus, dark: dark)
        guard let layout, !layout.isEmpty else {
            drawEmptyState(ctx, dark: dark)
            return
        }

        // Lineage classification, computed once per frame (band counts are small — a
        // handful per column, at most `ColumnsConstants.maxColumns` columns).
        var hoveredLoc: BandKey?
        var ancestors: Set<BandKey> = []
        var descendants: Set<BandKey> = []
        if let loc = effectiveHoverLocation(), let band = layout.band(at: loc) {
            hoveredLoc = BandKey(column: loc.column, index: loc.index)
            let range = (band.y, band.y + band.height)
            ancestors = Set(layout.ancestors(ofColumn: loc.column, range: range).map { BandKey(column: $0.column, index: $0.index) })
            descendants = Set(layout.descendants(ofColumn: loc.column, range: range).map { BandKey(column: $0.column, index: $0.index) })
        }

        let lastColumnIndex = min(columnWidths.count, layout.columns.count) - 1
        for (c, width) in columnWidths.enumerated() where c < layout.columns.count {
            drawColumnHeader(ctx, index: c, width: width, focus: focus, dark: dark, isLastColumn: c == lastColumnIndex)
            let x = columnX(c)
            for (i, band) in layout.columns[c].bands.enumerated() {
                let key = BandKey(column: c, index: i)
                let isHovered = key == hoveredLoc
                var alpha: CGFloat = 1
                if hoveredLoc != nil {
                    if isHovered || ancestors.contains(key) { alpha = 1 }
                    else if descendants.contains(key) { alpha = ColumnsConstants.hoverDescendantAlpha }
                    else { alpha = ColumnsConstants.hoverDimAlpha }
                }
                let isEmphasized = !lastEmphasized.isEmpty && isNodeEmphasized(band.node)
                if !lastEmphasized.isEmpty { alpha *= isEmphasized ? 1 : ColumnsConstants.hoverDimAlpha }
                let isSelected = band.node != nil && band.node === lastSelected
                let isAncestor = ancestors.contains(key)
                let rect = CGRect(x: x, y: ColumnsConstants.headerHeight + band.y, width: width, height: band.height)
                drawBand(ctx, band: band, rect: rect, focus: focus, dark: dark, alpha: alpha,
                        isHovered: isHovered, isSelected: isSelected, isAncestor: isAncestor, isEmphasized: isEmphasized)
            }
        }
    }

    private struct BandKey: Hashable { let column: Int; let index: Int }

    private func effectiveHoverLocation() -> (column: Int, index: Int)? {
        if isMouseInside, let loc = hoveredLocation, let layout,
           layout.columns.indices.contains(loc.column), layout.columns[loc.column].bands.indices.contains(loc.index) {
            return loc
        }
        if !isMouseInside, let node = lastExternalHover, let layout { return layout.location(of: node) }
        return nil
    }

    /// True when `node` is `state.emphasized` itself, or nested inside one of its members —
    /// the same "here, and everything in here" rule the Ball's lineage highlight uses.
    private func isNodeEmphasized(_ node: FileNode?) -> Bool {
        var n = node
        while let cur = n {
            if lastEmphasized.contains(cur) { return true }
            n = cur.parent
        }
        return false
    }

    private func drawSpine(_ ctx: CGContext, focus: FileNode, dark: Bool) {
        let rect = CGRect(x: 0, y: 0, width: ColumnsConstants.spineWidth, height: bounds.height)
        ctx.saveGState()
        ctx.setFillColor(NSColor(white: dark ? 1 : 0, alpha: dark ? 0.06 : 0.04).cgColor)
        ctx.fill(rect)
        ctx.setStrokeColor(NSColor(white: dark ? 1 : 0, alpha: dark ? 0.14 : 0.10).cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: rect.maxX, y: 0))
        ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        ctx.strokePath()
        ctx.restoreGState()

        guard rect.height > 40 else { return }
        let name = Self.displayName(for: focus)
        let sizeStr = ByteFormat.string(focus.size)
        let textColor = dark ? NSColor.white : NSColor(calibratedWhite: 0.1, alpha: 1)
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingMiddle
        let nameAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: textColor, .paragraphStyle: style,
        ]
        let sizeAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9.5, weight: .regular),
            .foregroundColor: textColor.withAlphaComponent(0.6), .paragraphStyle: style,
        ]

        ctx.saveGState()
        ctx.translateBy(x: rect.midX, y: rect.midY)
        ctx.rotate(by: -.pi / 2)
        let textLen = max(0, rect.height - 20)
        (name as NSString).draw(in: CGRect(x: -textLen / 2, y: -4, width: textLen, height: 16), withAttributes: nameAttrs)
        (sizeStr as NSString).draw(in: CGRect(x: -textLen / 2, y: 10, width: textLen, height: 12), withAttributes: sizeAttrs)
        ctx.restoreGState()
    }

    private func drawColumnHeader(_ ctx: CGContext, index: Int, width: CGFloat, focus: FileNode, dark: Bool, isLastColumn: Bool) {
        let x = columnX(index)
        let rect = CGRect(x: x, y: 0, width: width, height: ColumnsConstants.headerHeight)
        ctx.saveGState()
        ctx.setStrokeColor(NSColor(white: dark ? 1 : 0, alpha: dark ? 0.10 : 0.08).cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        ctx.strokePath()
        ctx.restoreGState()

        // The size-ramp legend rides in the last column's header, right-aligned, so it
        // appears exactly once regardless of how many columns fit — never per-column noise.
        // It reserves its own width first so the eyebrow label truncates instead of
        // overlapping it, and it draws nothing at all if the column is too narrow to hold
        // both without crowding (the "no overlap, ever" rule).
        let legendWidth = isLastColumn ? drawSizeLegend(ctx, in: rect, dark: dark) : 0

        let text = Self.eyebrowText(forColumn: index, focus: focus)
        let color = (dark ? NSColor.white : NSColor(calibratedWhite: 0.08, alpha: 1)).withAlphaComponent(dark ? 0.5 : 0.45)
        let font = NSFont.systemFont(ofSize: ColumnsConstants.eyebrowFontSize, weight: .semibold)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .kern: ColumnsConstants.eyebrowTracking, .paragraphStyle: style,
        ]
        let attrText = NSAttributedString(string: text.uppercased(), attributes: attrs)
        let size = attrText.size()
        let textRect = CGRect(x: rect.minX + 10, y: rect.midY - size.height / 2,
                              width: max(0, rect.width - 20 - legendWidth), height: size.height)
        attrText.draw(in: textRect)
    }

    /// A small "larger ← → smaller" swatch of the theme ramp's steps, shown while colour
    /// means size ("Colour by: Size", the default), so that reading is legible without
    /// opening Settings. Right-aligned in `headerRect`; draws nothing and returns 0 when the
    /// column isn't wide enough to hold it without crowding the eyebrow label on its left
    /// (checked by the caller, `drawColumnHeader`). Returns the width it consumed
    /// (swatch + gap + text + trailing pad), 0 if skipped.
    @discardableResult
    private func drawSizeLegend(_ ctx: CGContext, in headerRect: CGRect, dark: Bool) -> CGFloat {
        let trailingPad: CGFloat = 10
        let swatchSize = CGSize(width: 46, height: 6)
        let gap: CGFloat = 6
        let minEyebrowRoom: CGFloat = 70 // shortest an eyebrow label needs before truncation reads as noise

        let font = NSFont.systemFont(ofSize: 9, weight: .medium)
        let color = (dark ? NSColor.white : NSColor(calibratedWhite: 0.08, alpha: 1)).withAlphaComponent(dark ? 0.4 : 0.36)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let text = "larger  ←  →  smaller"
        let textSize = (text as NSString).size(withAttributes: attrs)

        let consumed = swatchSize.width + gap + textSize.width + trailingPad
        guard ColorMode.current == .size, headerRect.width - consumed - 10 >= minEyebrowRoom else { return 0 }

        let swatchRect = CGRect(x: headerRect.maxX - trailingPad - textSize.width - gap - swatchSize.width,
                                y: headerRect.midY - swatchSize.height / 2,
                                width: swatchSize.width, height: swatchSize.height)

        ctx.saveGState()
        let path = CGPath(roundedRect: swatchRect, cornerWidth: swatchSize.height / 2, cornerHeight: swatchSize.height / 2, transform: nil)
        ctx.addPath(path)
        ctx.clip()
        // Largest step on the left, matching the text.
        let cell = swatchRect.width / CGFloat(Palette.steps)
        for i in 0..<Palette.steps {
            ctx.setFillColor(Palette.stepColor(Palette.steps - 1 - i, dark: dark).cgColor)
            ctx.fill(CGRect(x: swatchRect.minX + CGFloat(i) * cell, y: swatchRect.minY, width: cell + 0.5, height: swatchRect.height))
        }
        ctx.restoreGState()

        (text as NSString).draw(at: CGPoint(x: headerRect.maxX - trailingPad - textSize.width, y: headerRect.midY - textSize.height / 2),
                                withAttributes: attrs)
        return consumed
    }

    private static func eyebrowText(forColumn index: Int, focus: FileNode) -> String {
        guard index > 0 else { return "Inside \(displayName(for: focus))" }
        let ordinals = ["One", "Two", "Three"]
        let word = index - 1 < ordinals.count ? ordinals[index - 1] : "\(index)"
        return "\(word) level\(index == 1 ? "" : "s") down"
    }

    private func drawEmptyState(_ ctx: CGContext, dark: Bool) {
        let x = ColumnsConstants.spineWidth + ColumnsConstants.columnGutter
        let rect = CGRect(x: x, y: 0, width: max(0, bounds.width - x), height: bounds.height)
        guard rect.width > 0 else { return }
        let text = "This folder is empty"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: (dark ? NSColor.white : NSColor(calibratedWhite: 0.1, alpha: 1)).withAlphaComponent(0.6),
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attrs)
    }

    // MARK: - Band drawing

    private func drawBand(_ ctx: CGContext, band: LayerBand, rect outerRect: CGRect, focus: FileNode, dark: Bool,
                          alpha: CGFloat, isHovered: Bool, isSelected: Bool, isAncestor: Bool, isEmphasized: Bool) {
        let inset = min(ColumnsConstants.bandInset, max(0, outerRect.height / 2 - 0.5))
        let rect = outerRect.insetBy(dx: 0, dy: inset)
        guard rect.height > 0.5, rect.width > 0.5 else { return }
        let radius = min(ColumnsConstants.cornerRadius, rect.height / 2, rect.width / 2)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        if band.isBucket {
            drawBucketBand(ctx, path: path, rect: rect, band: band, dark: dark)
            drawHighlight(ctx, path: path, tint: nil, dark: dark, alpha: alpha,
                         isHovered: isHovered, isSelected: isSelected, isAncestor: isAncestor, isEmphasized: isEmphasized)
            return
        }
        guard let node = band.node else { return }

        var tint: NSColor?
        if node.kind != .item {
            drawSyntheticBand(ctx, path: path, rect: rect, node: node, dark: dark, alpha: alpha, isHovered: isHovered)
        } else {
            drawItemBand(ctx, path: path, rect: rect, band: band, node: node, focus: focus, dark: dark, alpha: alpha, isHovered: isHovered)
            tint = itemTint(band, node: node, focus: focus, dark: dark)
        }
        drawHighlight(ctx, path: path, tint: tint, dark: dark, alpha: alpha,
                     isHovered: isHovered, isSelected: isSelected, isAncestor: isAncestor, isEmphasized: isEmphasized)
        if let appState, appState.isCollected(node) {
            drawCrateHatch(ctx, path: path, rect: rect, dark: dark)
        }
        drawBandText(ctx, band: band, node: node, rect: rect, focus: focus, dark: dark, alpha: alpha)
    }

    /// The one highlight language shared with Floor (`CanvasHighlight`): a luminous
    /// hue-into-accent ring plus glow for hover, a calmer double outline for selection, a
    /// quiet rim for ancestors in the hovered item's lineage, and a glow-plus-ring for
    /// Findings' emphasized set. States combine (a selected band that's also hovered draws
    /// both rings). Replaces the old single-color `drawBandGlow` — see the owner's "the
    /// border around whichever is selected is boring and too simple" note; `nil` tint (the
    /// bucket band, and Free/Purgeable/Unseen) falls back to the accent hue.
    private func drawHighlight(_ ctx: CGContext, path: CGPath, tint: NSColor?, dark: Bool, alpha: CGFloat,
                               isHovered: Bool, isSelected: Bool, isAncestor: Bool, isEmphasized: Bool) {
        var state: CanvasHighlight.State = []
        if isHovered { state.insert(.hovered) }
        if isSelected { state.insert(.selected) }
        if isAncestor { state.insert(.ancestor) }
        if isEmphasized { state.insert(.emphasized) }
        guard !state.isEmpty else { return }
        CanvasHighlight.draw(state, path: path, tint: tint, dark: dark, in: ctx,
                             increaseContrast: CanvasHighlight.isHighContrast(effectiveAppearance), opacity: alpha)
    }

    /// Real files/folders: the same theme ramp step and sheen the Ball and Floor use for
    /// this node (`Palette.paint`, so "Colour by" applies here too: by default a band's
    /// strength answers "how big is this", the same scale in every column). The hover cue
    /// is the stroke/glow only.
    private func drawItemBand(_ ctx: CGContext, path: CGPath, rect: CGRect, band: LayerBand, node: FileNode, focus: FileNode, dark: Bool,
                              alpha: CGFloat, isHovered: Bool) {
        guard let paint = Palette.paint(for: node, in: focus) else { return }
        let stops = Palette.gradientStops(paint, dark: dark, alpha: alpha)

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: stops.map(\.1) as CFArray, locations: stops.map(\.0)) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.maxX, y: rect.maxY), options: [])
        }
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor(white: dark ? 1 : 0, alpha: alpha * (isHovered ? 0.4 : 0.12)).cgColor)
        ctx.setLineWidth(isHovered ? 1.5 : 1)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// `SpaceAccounting`'s synthetic Free/Purgeable/Unseen bands — `Palette.Synthetic`'s
    /// shared fills/strokes, the same fixed, deliberately-not-gradient treatment
    /// `SunburstNSView`/`FloorNSView` use, so accounting data reads the same regardless of
    /// which canvas mode is showing it.
    private func drawSyntheticBand(_ ctx: CGContext, path: CGPath, rect: CGRect, node: FileNode, dark: Bool,
                                   alpha: CGFloat, isHovered: Bool) {
        let fill: NSColor
        let stroke: NSColor
        var dashed = false
        switch node.kind {
        case .item: return // unreachable; callers already guard on kind != .item
        case .freeSpace:
            fill = Palette.Synthetic.freeFill(dark: dark)
            stroke = Palette.Synthetic.freeStroke(dark: dark, highlighted: isHovered)
        case .purgeable:
            fill = Palette.Synthetic.purgeableFill(dark: dark)
            stroke = Palette.Synthetic.purgeableStroke(dark: dark, highlighted: isHovered)
            dashed = true
        case .hidden, .snapshot:
            fill = Palette.Synthetic.unseenFill(dark: dark)
            stroke = Palette.Synthetic.unseenStroke(dark: dark, highlighted: isHovered)
        }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setFillColor(fill.withAlphaComponent(fill.alphaComponent * alpha).cgColor)
        ctx.fillPath()
        ctx.addPath(path)
        ctx.clip()
        drawHatch(ctx, rect: rect, color: stroke.withAlphaComponent(stroke.alphaComponent * 0.55 * alpha))
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(path)
        ctx.setStrokeColor(stroke.withAlphaComponent(stroke.alphaComponent * alpha).cgColor)
        ctx.setLineWidth(isHovered ? 1.5 : 1)
        if dashed { ctx.setLineDash(phase: 0, lengths: [4, 3]) }
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.restoreGState()
    }

    /// The merged "N smaller items" band — `Palette.Synthetic.otherFill/otherStroke`, the
    /// same quiet neutral hatch language as the Ball's "Everything else" bucket.
    private func drawBucketBand(_ ctx: CGContext, path: CGPath, rect: CGRect, band: LayerBand, dark: Bool) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setFillColor(Palette.Synthetic.otherFill(dark: dark).cgColor)
        ctx.fillPath()
        ctx.addPath(path)
        ctx.clip()
        drawHatch(ctx, rect: rect, color: Palette.Synthetic.otherStroke(dark: dark))
        ctx.restoreGState()

        guard rect.height >= ColumnsConstants.nameOnlyHeight else { return }
        let title = band.bucketCount == 1 ? "1 smaller item" : "\(Count.string(band.bucketCount)) smaller items"
        let textColor = (dark ? NSColor.white : Palette.Synthetic.ink).withAlphaComponent(dark ? 0.75 : 0.65)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        let pad: CGFloat = 10
        if rect.height >= ColumnsConstants.fullDetailHeight {
            let nameAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12.5, weight: .medium), .foregroundColor: textColor, .paragraphStyle: style]
            let capAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular), .foregroundColor: textColor.withAlphaComponent(textColor.alphaComponent * 0.7), .paragraphStyle: style]
            (title as NSString).draw(in: CGRect(x: rect.minX + pad, y: rect.minY + 6, width: rect.width - pad * 2, height: 16), withAttributes: nameAttrs)
            (ByteFormat.string(band.size) as NSString).draw(in: CGRect(x: rect.minX + pad, y: rect.minY + 23, width: rect.width - pad * 2, height: 14), withAttributes: capAttrs)
        } else {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: textColor, .paragraphStyle: style]
            let y = rect.minY + (rect.height - 16) / 2
            (title as NSString).draw(in: CGRect(x: rect.minX + pad, y: y, width: rect.width - pad * 2, height: 16), withAttributes: attrs)
        }
    }

    private func drawCrateHatch(_ ctx: CGContext, path: CGPath, rect: CGRect, dark: Bool) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.setFillColor(NSColor(white: dark ? 0 : 1, alpha: 0.16).cgColor)
        ctx.fill(rect)
        drawHatch(ctx, rect: rect, color: NSColor(white: dark ? 0 : 1, alpha: 0.4))
        ctx.restoreGState()
    }

    private func drawHatch(_ ctx: CGContext, rect: CGRect, color: NSColor) {
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(1)
        var x = rect.minX - rect.height
        while x < rect.maxX {
            ctx.move(to: CGPoint(x: x, y: rect.minY))
            ctx.addLine(to: CGPoint(x: x + rect.height, y: rect.maxY))
            x += ColumnsConstants.hatchSpacing
        }
        ctx.strokePath()
    }

    /// Name (the pass-through chain joined with "›" when this band absorbed one) always,
    /// room permitting; size + share of `focus` once the band is tall enough for a second
    /// line without crowding. Matches `ColumnsConstants.nameOnlyHeight`/`fullDetailHeight`.
    /// Ink color follows `Palette.labelInk` — the "label-ink rule": white on the darker/duller
    /// fills, near-black once a fill itself gets light (deep bands lighten in dark mode
    /// enough that a fixed white would wash out).
    private func drawBandText(_ ctx: CGContext, band: LayerBand, node: FileNode, rect: CGRect, focus: FileNode, dark: Bool, alpha: CGFloat) {
        guard rect.height >= ColumnsConstants.nameOnlyHeight else { return }
        let target = band.childSource ?? node
        let zoomable = isZoomable(target)
        let pad: CGFloat = 10
        let chevronSpace: CGFloat = zoomable ? 14 : 0
        let textWidth = max(0, rect.width - pad * 2 - chevronSpace)
        guard textWidth > 8 else { return }

        let displayName = ([node] + band.passThrough).map(Self.displayName).joined(separator: " › ")
        let ink: NSColor
        if node.kind == .item, let paint = Palette.paint(for: node, in: focus) {
            // The same paint `drawItemBand` fills with, so the ink is picked against the
            // fill actually painted.
            ink = Palette.labelInk(paint, dark: dark)
        } else {
            ink = dark ? .white : Palette.Synthetic.ink
        }
        let textColor = ink.withAlphaComponent(alpha)
        let secondaryColor = textColor.withAlphaComponent(textColor.alphaComponent * 0.68)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        let nameAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12.5, weight: .medium), .foregroundColor: textColor, .paragraphStyle: style]

        if rect.height >= ColumnsConstants.fullDetailHeight {
            let capText = "\(ByteFormat.string(band.size)) · \(Percent.string(shareOfFocus(band)))"
            let capAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular), .foregroundColor: secondaryColor, .paragraphStyle: style]
            (displayName as NSString).draw(in: CGRect(x: rect.minX + pad, y: rect.minY + 6, width: textWidth, height: 16), withAttributes: nameAttrs)
            (capText as NSString).draw(in: CGRect(x: rect.minX + pad, y: rect.minY + 23, width: textWidth, height: 14), withAttributes: capAttrs)
        } else {
            let y = rect.minY + (rect.height - 16) / 2
            (displayName as NSString).draw(in: CGRect(x: rect.minX + pad, y: y, width: textWidth, height: 16), withAttributes: nameAttrs)
        }

        if zoomable {
            drawChevron(ctx, at: CGPoint(x: rect.maxX - 12, y: rect.midY), color: secondaryColor)
        }
    }

    private func shareOfFocus(_ band: LayerBand) -> Double {
        guard let focus = lastFocus, focus.size > 0 else { return 0 }
        return min(1, max(0, Double(band.size) / Double(focus.size)))
    }

    /// A representative single colour for `band`'s real-item fill (the paint
    /// `drawItemBand` uses), for `CanvasHighlight`'s `tint`.
    private func itemTint(_ band: LayerBand, node: FileNode, focus: FileNode, dark: Bool) -> NSColor? {
        Palette.paint(for: node, in: focus).map { Palette.fill($0, dark: dark) }
    }

    private func drawChevron(_ ctx: CGContext, at center: CGPoint, color: NSColor) {
        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(1.4)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let s: CGFloat = 3.2
        ctx.move(to: CGPoint(x: center.x - s * 0.4, y: center.y - s))
        ctx.addLine(to: CGPoint(x: center.x + s * 0.6, y: center.y))
        ctx.addLine(to: CGPoint(x: center.x - s * 0.4, y: center.y + s))
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// The root node's `name` is its full filesystem path (see `FileNode`); show the
    /// friendly volume/folder display name instead, matching the Ball and the path bar.
    private static func displayName(for node: FileNode) -> String {
        node.parent == nil ? FileManager.default.displayName(atPath: node.path) : node.name
    }
}
