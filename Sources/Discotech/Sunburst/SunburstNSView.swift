import AppKit
import QuartzCore
import CoreText
import SwiftUI

/// Result of a hit test against the current layout.
private enum SunburstHitRegion {
    case center
    case segment(SunburstSegment)
    case none
}

/// The sunburst chart itself. A plain layer-backed `NSView` rather than a
/// SwiftUI `Canvas`: it gives precise, cheap hit testing (needed for
/// right-click context menus keyed to a specific wedge) and a manual,
/// interpolation-driven repaint loop for the zoom transition, without
/// depending on SwiftUI's view-identity diffing for millions of nodes.
///
/// Layout (`SunburstLayout`) is rebuilt only when `focus` or `treeVersion`
/// changes (see `sync`); hovering only reads the already-built layout, so it
/// never triggers a relayout — this is what keeps hover smooth on huge trees.
/// Color is resolved fresh every frame from `Palette` (each segment's ramp step is
/// fixed in the layout; the fill depends on light-vs-dark), so a live appearance
/// change repaints correctly without a relayout either.
final class SunburstNSView: NSView {
    weak var appState: AppState?

    var currentLayout: SunburstLayout?
    private var previousLayout: SunburstLayout?

    // Transition state, computed once per focus/tree change in `beginTransition`.
    private var matchedPairs: [(old: SunburstSegment, new: SunburstSegment)] = []
    private var appearingOnly: [SunburstSegment] = []
    private var disappearingOnly: [SunburstSegment] = []
    private var animationProgress: CGFloat = 1
    private var animationStartTime: CFTimeInterval = 0
    var displayTimer: Timer?

    private var lastFocus: FileNode?
    private var lastTreeVersion: Int = -1
    private var lastExternalHover: FileNode?

    private var hoveredKey: SunburstSegmentKey?
    private var isMouseInside = false
    private var trackingArea: NSTrackingArea?

    // Findings emphasis: `state.emphasized`, mirrored here so `draw` doesn't touch
    // AppState directly. A Findings card sets this (via `sync`) instead of `hovered`,
    // so it never fights the pointer-driven lineage highlight above.
    var emphasized: Set<FileNode> = []

    /// `state.selected` (a file last clicked in the chart or a sidebar row), mirrored so
    /// `draw` doesn't touch `AppState` directly — gives the Ball the same visible
    /// `CanvasHighlight` selected state Floor and Layers already have.
    private var selected: FileNode?

    private var themeObserver: NSObjectProtocol?

    // Lineage highlight: which segment is hovered, its ancestors back to the center,
    // and its own descendants — recomputed only when the hovered *key* changes (not
    // every frame), then cross-faded in over `hoverBlendDuration`.
    private var lastClassifiedHoverKey: SunburstSegmentKey?
    private var hoverBlendFrom: HoverClassification = .empty
    private var hoverBlendTo: HoverClassification = .empty
    private var hoverBlendProgress: CGFloat = 1
    private var hoverBlendStart: CFTimeInterval = 0
    var hoverBlendTimer: Timer?

    // Ring-1/ring-2 name labels, cached per (layout identity, maxR) so hover redraws
    // (which don't change either) never rebuild a `CTLine`.
    private var currentLabelCache: [SunburstSegmentKey: CachedLabel] = [:]
    private var currentLabelCacheLayoutID: ObjectIdentifier?
    private var currentLabelCacheMaxR: CGFloat = -1
    private var previousLabelCache: [SunburstSegmentKey: CachedLabel] = [:]
    private var previousLabelCacheLayoutID: ObjectIdentifier?
    private var previousLabelCacheMaxR: CGFloat = -1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        #if DEBUG
        Self.debugLiveViews += 1
        #endif
        wantsLayer = true
        layer?.backgroundColor = .clear
        // Posted when the theme or the "Colour by" mode changes. Fills and label ink are
        // resolved every draw from `Palette`, but each segment's ramp step (`paint`) is
        // baked into the layout, so rebuild it (no animation) along with the label cache.
        themeObserver = NotificationCenter.default.addObserver(
            forName: .discotechThemeDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            stopAnimations()  // the redraw below is not animated
            currentLabelCache = [:]
            currentLabelCacheLayoutID = nil
            previousLabelCache = [:]
            previousLabelCacheLayoutID = nil
            if let focus = currentLayout?.focus { reload(focus: focus, animate: false) }
            needsDisplay = true
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
        // Normally already stopped when the view left its window (`viewDidMoveToWindow`).
        displayTimer?.invalidate()
        hoverBlendTimer?.invalidate()
        #if DEBUG
        Self.debugLiveViews -= 1
        #endif
    }

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { true } // we always paint our own background

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Leaving the window: a canvas switch, or the rebuild a theme change makes.
        if window == nil { stopAnimations() }
        #if DEBUG
        if window != nil { scheduleScrollSelfTest(); scheduleLeakTest() }
        #endif
    }

    private var isDarkAppearance: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// System Accessibility → Display → Increase Contrast. Where it matters here: the
    /// non-lineage dim goes darker, ancestor/free hairlines get stronger, so the chart
    /// still separates cleanly for low-vision users instead of relying on the calmer
    /// Studio palette's subtler default contrast.
    private var increaseContrast: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    /// System Accessibility → Display → Reduce Transparency. Where it matters here: the
    /// center orb's frosted-glass sheen (the one "glassy" surface this canvas draws)
    /// flattens to a plain matte disc instead of a glossy highlight.
    private var reduceTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    // MARK: - External sync

    /// First-time setup: records the starting focus/version without animating.
    func prime(focus: FileNode?, treeVersion: Int) {
        lastFocus = focus
        lastTreeVersion = treeVersion
        if let focus { reload(focus: focus, animate: false) }
    }

    /// Called from `SunburstRepresentable.updateNSView` on every state change.
    func sync(focus: FileNode?, treeVersion: Int, externalHover: FileNode?, emphasized: Set<FileNode>, selected: FileNode?) {
        if externalHover !== lastExternalHover {
            lastExternalHover = externalHover
            needsDisplay = true
        }
        if emphasized != self.emphasized {
            self.emphasized = emphasized
            needsDisplay = true
        }
        if selected !== self.selected {
            self.selected = selected
            needsDisplay = true
        }
        guard let focus else { return }
        if focus !== lastFocus || treeVersion != lastTreeVersion {
            lastFocus = focus
            lastTreeVersion = treeVersion
            reload(focus: focus, animate: true)
        }
    }

    private func reload(focus: FileNode, animate: Bool) {
        let newLayout = SunburstLayout.build(focus: focus)
        // Node identities are stable, but a relayout can change *which* segments exist
        // for them (sizes reshuffled, tree mutated) — force the lineage highlight to
        // recompute against the new layout rather than trusting a stale classification.
        lastClassifiedHoverKey = nil
        if animate, currentLayout != nil {
            previousLayout = currentLayout
            // Carry the already-built cache forward instead of recomputing it — `reload`
            // can run every time the tree mutates, and CTLine layout isn't free.
            previousLabelCache = currentLabelCache
            previousLabelCacheLayoutID = currentLabelCacheLayoutID
            previousLabelCacheMaxR = currentLabelCacheMaxR
            currentLayout = newLayout
            beginTransition()
        } else {
            currentLayout = newLayout
            previousLayout = nil
            previousLabelCache = [:]
            previousLabelCacheLayoutID = nil
            animationProgress = 1
            displayTimer?.invalidate()
            displayTimer = nil
            needsDisplay = true
        }
    }

    /// Ends a running zoom or hover animation at its last frame and stops its timer. A
    /// repeating timer must never outlive what it animates: this runs when the view leaves
    /// its window (a canvas switch, or the window rebuild a theme change makes) and on a
    /// theme or "Colour by" change.
    private func stopAnimations() {
        displayTimer?.invalidate()
        displayTimer = nil
        animationProgress = 1
        hoverBlendTimer?.invalidate()
        hoverBlendTimer = nil
        hoverBlendFrom = hoverBlendTo
        hoverBlendProgress = 1
    }

    // MARK: - Transition

    private func beginTransition() {
        displayTimer?.invalidate()
        displayTimer = nil
        // Not in a window (a last `sync` while being taken down): nothing to animate on.
        guard window != nil, let old = previousLayout, let new = currentLayout else {
            matchedPairs = []
            appearingOnly = currentLayout?.segments ?? []
            disappearingOnly = []
            animationProgress = 1
            needsDisplay = true
            return
        }
        var matched: [(SunburstSegment, SunburstSegment)] = []
        var appearing: [SunburstSegment] = []
        var usedOldKeys = Set<SunburstSegmentKey>()
        for seg in new.segments {
            if let oldSeg = old.byKey[seg.key] {
                matched.append((oldSeg, seg))
                usedOldKeys.insert(seg.key)
            } else {
                appearing.append(seg)
            }
        }
        let disappearing = old.segments.filter { !usedOldKeys.contains($0.key) }

        matchedPairs = matched
        appearingOnly = appearing
        disappearingOnly = disappearing
        animationProgress = 0
        animationStartTime = CACurrentMediaTime()
        needsDisplay = true
        displayTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] timer in
            #if DEBUG
            SunburstNSView.debugTimerFires += 1
            #endif
            // The view is gone: stop instead of firing forever.
            guard let self else { timer.invalidate(); return }
            self.tickAnimation()
        }
    }

    private func tickAnimation() {
        let elapsed = CACurrentMediaTime() - animationStartTime
        let raw = min(1, elapsed / SunburstConstants.animationDuration)
        animationProgress = CGFloat(raw)
        needsDisplay = true
        if raw >= 1 {
            displayTimer?.invalidate()
            displayTimer = nil
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        #if DEBUG
        let profileStart = debugRepaintStart()
        defer { debugRepaintEnd(profileStart) }
        #endif
        let dark = isDarkAppearance
        drawBackground(ctx, dark: dark)

        let b = bounds
        let maxR = min(b.width, b.height) / 2 - SunburstConstants.outerPadding
        guard maxR > 0 else { return }

        ctx.saveGState()
        ctx.translateBy(x: b.midX, y: b.midY)

        if animationProgress < 1, currentLayout != nil {
            let t = 1 - pow(1 - Double(animationProgress), 3) // ease-out
            for pair in matchedPairs {
                drawInterpolated(ctx, old: pair.old, new: pair.new, t: t, maxR: maxR, dark: dark)
            }
            for seg in disappearingOnly {
                drawSegment(ctx, seg, alpha: CGFloat(1 - t), maxR: maxR, dark: dark, lift: false, strokeEmphasis: false,
                            alphaMul: 1, highlightState: [], highlightOpacity: 0, ancestorOpacity: 0)
            }
            for seg in appearingOnly {
                drawSegment(ctx, seg, alpha: CGFloat(t), maxR: maxR, dark: dark, lift: false, strokeEmphasis: false,
                            alphaMul: 1, highlightState: [], highlightOpacity: 0, ancestorOpacity: 0)
            }
            // Labels don't morph between layouts — they're static per layout, so they
            // just cross-fade out (old) and in (new) alongside the wedges.
            for (_, label) in previousLabels(maxR: maxR) {
                drawLabel(ctx, label, alpha: CGFloat(1 - t), dark: dark, liftPoints: 0)
            }
            for (_, label) in currentLabels(maxR: maxR) {
                drawLabel(ctx, label, alpha: CGFloat(t), dark: dark, liftPoints: 0)
            }
        } else if let layout = currentLayout {
            let hk = effectiveHoverKey()
            refreshHoverClassification(hoverKey: hk, layout: layout)
            let labels = currentLabels(maxR: maxR)
            let emphasisActive = !emphasized.isEmpty
            #if DEBUG
            logGeometryIfNeeded(hk: hk, layout: layout, maxR: maxR)
            #endif
            for seg in layout.segments {
                let isHovered = seg.key == hk
                let roleFrom = role(of: seg.key, in: hoverBlendFrom)
                let roleTo = role(of: seg.key, in: hoverBlendTo)
                var alphaMul = isHovered ? 1 : mixCG(alphaMultiplier(for: roleFrom), alphaMultiplier(for: roleTo), hoverBlendProgress)
                // Cross-fades independently of the instant states below — a segment can
                // fade in/out of "on the path to the hovered wedge" over `hoverBlendDuration`
                // without its own hover/selection/emphasis state animating.
                let ancestorOpacity = isHovered ? 0 : mixCG(ancestorRimAlpha(for: roleFrom), ancestorRimAlpha(for: roleTo), hoverBlendProgress)
                let isEmphasized = emphasisActive && isNodeEmphasized(seg.node)
                if emphasisActive { alphaMul *= isEmphasized ? 1 : SunburstConstants.hoverDimAlpha }
                let isSelectedSeg = selected != nil && seg.node === selected
                var highlightState: CanvasHighlight.State = []
                if isHovered { highlightState.insert(.hovered) }
                if isSelectedSeg { highlightState.insert(.selected) }
                if isEmphasized { highlightState.insert(.emphasized) }
                // Only the exact hovered wedge may change size or position — ancestors,
                // descendants, emphasized items (Findings can emphasize many at once) and
                // everything else only ever change colour, alpha or rim (see `drawSegment`).
                drawSegment(ctx, seg, alpha: 1, maxR: maxR, dark: dark, lift: isHovered,
                            strokeEmphasis: !highlightState.isEmpty, alphaMul: alphaMul,
                            highlightState: highlightState, highlightOpacity: 1, ancestorOpacity: ancestorOpacity)
                if let label = labels[seg.key] {
                    drawLabel(ctx, label, alpha: alphaMul, dark: dark, liftPoints: isHovered ? SunburstConstants.hoverLiftPoints : 0)
                }
            }
        }

        drawCenterOrb(ctx, maxR: maxR, dark: dark)
        ctx.restoreGState()
    }

    /// Studio's `surface.canvas` token (blue-black `#0D0E14` dark / lavender `#F4F2F7`
    /// light) — read from the shared token rather than hard-coded, so this follows
    /// `DesignTokens.swift` if the shell engineer retunes it.
    private func drawBackground(_ ctx: CGContext, dark: Bool) {
        ctx.setFillColor(NSColor(Tokens.Colors.chartSurface).cgColor)
        ctx.fill(bounds)
    }

    private func drawInterpolated(_ ctx: CGContext, old: SunburstSegment, new: SunburstSegment, t: Double, maxR: CGFloat, dark: Bool) {
        let start = old.startAngle + (new.startAngle - old.startAngle) * t
        let end = old.endAngle + (new.endAngle - old.endAngle) * t
        let innerF = old.innerFrac + (new.innerFrac - old.innerFrac) * CGFloat(t)
        let outerF = old.outerFrac + (new.outerFrac - old.outerFrac) * CGFloat(t)
        let isOther = t < 0.5 ? old.isOther : new.isOther
        // Same node throughout an interpolated (matched) pair, so `new`'s kind is `old`'s too.
        let kind = new.node?.kind ?? .item

        let inner = innerF * maxR
        let outer = outerF * maxR
        guard let path = sunburstSectorPath(start: start, end: end, inner: inner, outer: outer) else { return }

        if isOther {
            drawOtherSegment(ctx, path: path, alpha: 1, dark: dark)
            return
        }
        if kind != .item {
            drawAccountingSegment(ctx, path: path, kind: kind, alpha: 1, dark: dark, highlighted: false)
            return
        }
        // The item's step can change with the focus (size is relative to it): blend.
        guard let newPaint = new.paint else { return }
        let newStops = Palette.gradientStops(newPaint, dark: dark, alpha: 1)
        let stops = old.paint.map { Palette.blend(Palette.gradientStops($0, dark: dark, alpha: 1), newStops, t) } ?? newStops
        fillGradientSector(ctx, path: path, stops: stops, start: start, end: end, inner: inner, outer: outer)
    }

    /// - Parameters:
    ///   - lift: true only for the exact hovered wedge. This is the *only* thing allowed to
    ///     change a segment's size or position — ancestors, descendants, selected/emphasized
    ///     items and everything else only ever change colour, alpha or rim, painted via
    ///     `CanvasHighlight` below. (Previously "highlighted" also covered emphasized
    ///     segments, which meant every node in a Findings card's set — however many, however
    ///     far from the hovered wedge — lifted at once; and the hover glow was an unclipped
    ///     `ctx.setShadow`, which bloomed onto whatever real segments happened to sit close
    ///     in *canvas* space, most often the inner rings, since ring gaps are only a few
    ///     points wide. Both read as "other cards near the middle pop or resize" — this is
    ///     the fix.)
    ///   - strokeEmphasis: hovered, selected or emphasized — a modest stroke/width bump for
    ///     synthetic (Free/Purgeable/Unseen/"Everything else") fills only; never changes size.
    ///   - alphaMul: fill opacity multiplier from the lineage/emphasis dim (1 for the hovered
    ///     wedge and its ancestors, `hoverDescendantAlpha` for its descendants, `hoverDimAlpha`
    ///     for everything else while emphasis or a hover is active).
    ///   - highlightState: hovered/selected/emphasized states painted at `highlightOpacity`,
    ///     clipped tight to this wedge's own path by `CanvasHighlight` — never `.ancestor`,
    ///     which cross-fades independently via `ancestorOpacity`.
    private func drawSegment(_ ctx: CGContext, _ seg: SunburstSegment, alpha: CGFloat, maxR: CGFloat, dark: Bool,
                              lift: Bool, strokeEmphasis: Bool, alphaMul: CGFloat,
                              highlightState: CanvasHighlight.State, highlightOpacity: CGFloat, ancestorOpacity: CGFloat) {
        guard alpha > 0.004 else { return }
        var inner = seg.innerFrac * maxR
        var outer = seg.outerFrac * maxR
        if lift {
            inner += SunburstConstants.hoverLiftPoints
            outer += SunburstConstants.hoverLiftPoints
        }
        guard let path = sunburstSectorPath(start: seg.startAngle, end: seg.endAngle, inner: inner, outer: outer) else { return }
        let finalAlpha = alpha * alphaMul
        var tint: NSColor?

        if seg.isOther {
            drawOtherSegment(ctx, path: path, alpha: finalAlpha, dark: dark)
        } else if let kind = seg.node?.kind, kind != .item {
            drawAccountingSegment(ctx, path: path, kind: kind, alpha: finalAlpha, dark: dark, highlighted: strokeEmphasis)
        } else if let paint = seg.paint {
            let stops = Palette.gradientStops(paint, dark: dark, alpha: finalAlpha)
            fillGradientSector(ctx, path: path, stops: stops, start: seg.startAngle, end: seg.endAngle, inner: inner, outer: outer)
            tint = Palette.fill(paint, dark: dark)
        }

        // The one highlight language shared with Floor and Layers: `CanvasHighlight` clips
        // its glow/rings to this wedge's own path (padded by a few points, not the whole
        // canvas), so hovering or emphasizing one segment can never bloom onto a different
        // one nearby. `nil` tint (synthetic/"Everything else") falls back to the accent hue.
        if !highlightState.isEmpty {
            CanvasHighlight.draw(highlightState, path: path, tint: tint, dark: dark, in: ctx,
                                 increaseContrast: increaseContrast, opacity: highlightOpacity)
        }
        if ancestorOpacity > 0.004 {
            CanvasHighlight.draw(.ancestor, path: path, tint: tint, dark: dark, in: ctx,
                                 increaseContrast: increaseContrast, opacity: ancestorOpacity)
        }
    }

    private func fillGradientSector(_ ctx: CGContext, path: CGPath, stops: [(CGFloat, CGColor)],
                                     start: Double, end: Double, inner: CGFloat, outer: CGFloat) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let colors = stops.map(\.1) as CFArray
        let locations = stops.map(\.0)
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: locations) {
            // Radial from the chart center, not linear along the mid-angle: a linear
            // band leaves most of a wide (>~90°) sector unpainted, drawing lens slivers.
            ctx.drawRadialGradient(gradient, startCenter: .zero, startRadius: inner,
                                   endCenter: .zero, endRadius: outer,
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        ctx.restoreGState()
    }

    /// The merged "Everything else" bucket: a quiet neutral fill + diagonal
    /// hatch, deliberately unflashy so it reads as "not worth a color".
    private func drawOtherSegment(_ ctx: CGContext, path: CGPath, alpha: CGFloat, dark: Bool) {
        ctx.saveGState()
        ctx.addPath(path)
        let fillBase = Palette.Synthetic.otherFill(dark: dark)
        ctx.setFillColor(fillBase.withAlphaComponent(fillBase.alphaComponent * alpha).cgColor)
        ctx.fillPath()
        ctx.addPath(path)
        ctx.clip()
        let contrastBoost: CGFloat = increaseContrast ? 1.6 : 1.0
        let strokeBase = Palette.Synthetic.otherStroke(dark: dark)
        ctx.setStrokeColor(strokeBase.withAlphaComponent(min(1, strokeBase.alphaComponent * contrastBoost) * alpha).cgColor)
        ctx.setLineWidth(1)
        let bbox = path.boundingBoxOfPath
        var x = bbox.minX - bbox.height
        while x < bbox.maxX {
            ctx.move(to: CGPoint(x: x, y: bbox.minY))
            ctx.addLine(to: CGPoint(x: x + bbox.height, y: bbox.maxY))
            x += 6
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// `SpaceAccounting`'s synthetic Free/Purgeable/Unseen(+snapshot) segments — each
    /// gets its own fixed, deliberately-not-gradient treatment (see `Palette.syntheticColor`,
    /// the same colors the sidebar uses) so accounting data reads as clearly different
    /// from real file data, in both appearances.
    private func drawAccountingSegment(_ ctx: CGContext, path: CGPath, kind: FileNode.Kind,
                                        alpha: CGFloat, dark: Bool, highlighted: Bool) {
        switch kind {
        case .item:
            return // unreachable; callers already guard on kind != .item
        case .freeSpace:
            drawFreeSegment(ctx, path: path, alpha: alpha, dark: dark, highlighted: highlighted)
        case .purgeable:
            drawPurgeableSegment(ctx, path: path, alpha: alpha, dark: dark, highlighted: highlighted)
        case .hidden, .snapshot:
            drawUnseenSegment(ctx, path: path, alpha: alpha, dark: dark, highlighted: highlighted)
        }
    }

    /// Free: frosted glass, barely-there — a faint fill plus a crisp hairline edge, no
    /// gradient at all. Reads as "empty", never competes with real data's saturated fills.
    /// Colors come from `Palette.Synthetic`, the shared Free token every canvas should use.
    private func drawFreeSegment(_ ctx: CGContext, path: CGPath, alpha: CGFloat, dark: Bool, highlighted: Bool) {
        ctx.saveGState()
        ctx.addPath(path)
        let fill = Palette.Synthetic.freeFill(dark: dark)
        ctx.setFillColor(fill.withAlphaComponent(fill.alphaComponent * alpha).cgColor)
        ctx.fillPath()
        ctx.addPath(path)
        let contrastBoost: CGFloat = increaseContrast ? 1.7 : 1.0
        let stroke = Palette.Synthetic.freeStroke(dark: dark, highlighted: highlighted)
        ctx.setStrokeColor(stroke.withAlphaComponent(min(1, stroke.alphaComponent * contrastBoost) * alpha).cgColor)
        ctx.setLineWidth(highlighted ? 1.5 : 1)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// Purgeable: dashed outline + soft `warning` (amber) fill — visually between real
    /// data (solid) and Free (barely there): "counted as used, but reclaimable". Amber
    /// appears nowhere else in the chart — see `Palette.Synthetic`.
    private func drawPurgeableSegment(_ ctx: CGContext, path: CGPath, alpha: CGFloat, dark: Bool, highlighted: Bool) {
        ctx.saveGState()
        ctx.addPath(path)
        let fill = Palette.Synthetic.purgeableFill(dark: dark)
        ctx.setFillColor(fill.withAlphaComponent(fill.alphaComponent * alpha).cgColor)
        ctx.fillPath()
        ctx.addPath(path)
        let stroke = Palette.Synthetic.purgeableStroke(dark: dark, highlighted: highlighted)
        ctx.setStrokeColor(stroke.withAlphaComponent(stroke.alphaComponent * alpha).cgColor)
        ctx.setLineWidth(highlighted ? 1.75 : 1.25)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.restoreGState()
    }

    /// Unseen (and its Snapshot/other-volume children): a subtle *slate* hatch — the same
    /// "not worth a flashy color" language as `drawOtherSegment`'s neutral hatch, but cool-tinted
    /// so it never reads as the achromatic "Everything else" merge bucket.
    private func drawUnseenSegment(_ ctx: CGContext, path: CGPath, alpha: CGFloat, dark: Bool, highlighted: Bool) {
        ctx.saveGState()
        ctx.addPath(path)
        let fill = Palette.Synthetic.unseenFill(dark: dark)
        ctx.setFillColor(fill.withAlphaComponent(fill.alphaComponent * alpha).cgColor)
        ctx.fillPath()
        ctx.addPath(path)
        ctx.clip()
        let contrastBoost: CGFloat = increaseContrast ? 1.5 : 1.0
        let stroke = Palette.Synthetic.unseenStroke(dark: dark, highlighted: highlighted)
        ctx.setStrokeColor(stroke.withAlphaComponent(min(1, stroke.alphaComponent * contrastBoost) * alpha).cgColor)
        ctx.setLineWidth(1)
        let bbox = path.boundingBoxOfPath
        var x = bbox.minX - bbox.height
        while x < bbox.maxX {
            ctx.move(to: CGPoint(x: x, y: bbox.minY))
            ctx.addLine(to: CGPoint(x: x + bbox.height, y: bbox.maxY))
            x += 6
        }
        ctx.strokePath()
        ctx.restoreGState()
        if highlighted {
            ctx.saveGState()
            ctx.addPath(path)
            ctx.setStrokeColor(Palette.Synthetic.unseenStroke(dark: dark, highlighted: true).withAlphaComponent(0.7 * alpha).cgColor)
            ctx.setLineWidth(1.5)
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    // MARK: - Center orb

    private func drawCenterOrb(_ ctx: CGContext, maxR: CGFloat, dark: Bool) {
        guard let layout = currentLayout else { return }
        let centerR = maxR * SunburstConstants.centerFraction
        let rect = CGRect(x: -centerR, y: -centerR, width: centerR * 2, height: centerR * 2)

        // Lift the orb off the canvas with a soft shadow.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1.5), blur: centerR * 0.4,
                       color: NSColor.black.withAlphaComponent(dark ? 0.55 : 0.16).cgColor)
        ctx.addEllipse(in: rect)
        ctx.setFillColor((dark ? NSColor(calibratedWhite: 0.13, alpha: 1) : NSColor(calibratedWhite: 0.99, alpha: 1)).cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        // Calm frosted-glass sheen, clipped to the disc — a soft top-left highlight that
        // fades to the edge, no orbiting glint and no facet dots (Studio direction:
        // "a calmer centre orb with no sparkle" — the old sparkle was also the idle-CPU
        // bug's source: it needed a continuous 24fps timer to animate the glint).
        // Under Reduce Transparency the sheen flattens to a duller highlight so the orb
        // reads as a plain matte disc rather than glass.
        ctx.saveGState()
        ctx.addEllipse(in: rect)
        ctx.clip()
        let sheenStrength: CGFloat = reduceTransparency ? 0.45 : 1.0
        let highlight = (dark ? NSColor.white.withAlphaComponent(0.16 * sheenStrength) : NSColor.white.withAlphaComponent(0.85 * sheenStrength)).cgColor
        let midTone = (dark ? NSColor.white.withAlphaComponent(0.02 * sheenStrength) : NSColor.white.withAlphaComponent(0.28 * sheenStrength)).cgColor
        let edge = (dark ? NSColor.black.withAlphaComponent(0.22) : NSColor.black.withAlphaComponent(0.03)).cgColor
        if let glass = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [highlight, midTone, edge] as CFArray,
                                   locations: [0, 0.5, 1]) {
            ctx.drawRadialGradient(glass, startCenter: CGPoint(x: -centerR * 0.32, y: centerR * 0.32), startRadius: 0,
                                    endCenter: .zero, endRadius: centerR * 1.35, options: [])
        }
        ctx.restoreGState()

        ctx.addEllipse(in: rect)
        let edgeBoost: CGFloat = increaseContrast ? 1.6 : 1.0
        ctx.setStrokeColor((dark ? NSColor.white.withAlphaComponent(min(1, 0.14 * edgeBoost)) : NSColor.black.withAlphaComponent(min(1, 0.08 * edgeBoost))).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()

        drawCenterText(ctx, layout: layout, centerR: centerR, dark: dark)
    }

    private func roundedFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if let roundedDescriptor = base.fontDescriptor.withDesign(.rounded) {
            return NSFont(descriptor: roundedDescriptor, size: size) ?? base
        }
        return base
    }

    /// Size first (large, bold, rounded) then name (smaller, secondary) — a
    /// hero-number/caption hierarchy, not the old name-first label.
    private func drawCenterText(_ ctx: CGContext, layout: SunburstLayout, centerR: CGFloat, dark: Bool) {
        let resolved = animationProgress >= 1 ? resolvedHoverSegment() : nil
        let name: String
        let sizeStr: String
        if let resolved {
            name = resolved.displayName
            sizeStr = ByteFormat.string(resolved.displaySize)
        } else if let totals = Self.volumeTotals(for: layout.focus) {
            // A scanned volume's own root: `focus.size` is the *whole disk's capacity*
            // (SpaceAccounting made it so), not "used" — say so, instead of repeating
            // the volume name under a number that isn't "how much is on it".
            name = "of \(ByteFormat.string(totals.capacity)) capacity"
            sizeStr = ByteFormat.string(totals.used)
        } else {
            name = Self.displayName(for: layout.focus)
            sizeStr = ByteFormat.string(layout.focus.size)
        }

        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingMiddle

        let sizeFontSize = max(15, centerR * 0.26)
        let nameFontSize = max(10, centerR * 0.135)
        let primaryColor = dark ? NSColor.white : NSColor(calibratedWhite: 0.12, alpha: 1)
        let secondaryColor = dark ? NSColor.white.withAlphaComponent(0.6) : NSColor(calibratedWhite: 0.12, alpha: 0.55)

        let sizeAttrs: [NSAttributedString.Key: Any] = [
            .font: roundedFont(size: sizeFontSize, weight: .bold),
            .foregroundColor: primaryColor,
            .paragraphStyle: style,
        ]
        let nameAttrs: [NSAttributedString.Key: Any] = [
            .font: roundedFont(size: nameFontSize, weight: .medium),
            .foregroundColor: secondaryColor,
            .paragraphStyle: style,
        ]

        let textWidth = centerR * 1.6
        let sizeH = sizeFontSize * 1.2
        let nameH = nameFontSize * 1.3
        let gap: CGFloat = 3
        let totalH = sizeH + gap + nameH
        let sizeY = totalH / 2 - sizeH
        let nameY = sizeY - nameH - gap

        (sizeStr as NSString).draw(in: CGRect(x: -textWidth / 2, y: sizeY, width: textWidth, height: sizeH), withAttributes: sizeAttrs)
        (name as NSString).draw(in: CGRect(x: -textWidth / 2, y: nameY, width: textWidth, height: nameH), withAttributes: nameAttrs)
    }

    // MARK: - Segment labels

    /// A pre-laid-out ring-1/ring-2 name label, set along its ring's arc like a
    /// rainbow: geometry only (per-glyph arc offsets, already-truncated text) and no
    /// baked-in color, so a live light/dark switch or the hover dim/lift treatment needs
    /// no relayout. Built once per (layout, maxR) pair, not per frame.
    private struct CachedLabel {
        let name: ArcText
        let size: ArcText?
        /// Radial offset of each line's baseline from the ring's mid-radius, in the
        /// label's own "up" direction (outward on the top half, inward when flipped).
        let nameBaselineOffset: CGFloat
        let sizeBaselineOffset: CGFloat
        let midAngle: Double
        let midRadius: CGFloat
        /// Bottom-half labels run counterclockwise so they read left-to-right, upright.
        let flipped: Bool
        /// The segment's paint, to pick label ink (`Palette.labelInk`) at draw time —
        /// `nil` for isOther/synthetic segments, which use the fixed canvas-surface rule
        /// instead (their fill is a near-invisible hatch, not a tint the ink must clear).
        let paint: Palette.Paint?
    }

    /// One line of text broken into glyphs, each with its signed distance (center of
    /// the glyph) from the line's middle along the baseline.
    private struct ArcText {
        struct Run { let font: CTFont; let glyphs: [CGGlyph]; let offsets: [CGFloat]; let advances: [CGFloat] }
        let runs: [Run]

        init(_ line: CTLine) {
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            var runs: [Run] = []
            for case let run as CTRun in CTLineGetGlyphRuns(line) as NSArray {
                let count = CTRunGetGlyphCount(run)
                guard count > 0 else { continue }
                var glyphs = [CGGlyph](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                var advances = [CGSize](repeating: .zero, count: count)
                CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
                CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
                CTRunGetAdvances(run, CFRange(location: 0, length: count), &advances)
                let attrs = CTRunGetAttributes(run) as NSDictionary
                let font = attrs[kCTFontAttributeName as String].map { $0 as! CTFont }
                    ?? CTFontCreateWithName("Helvetica" as CFString, 11, nil)
                runs.append(Run(font: font, glyphs: glyphs,
                                offsets: zip(positions, advances).map { $0.x + $1.width / 2 - width / 2 },
                                advances: advances.map(\.width)))
            }
            self.runs = runs
        }
    }

    private func currentLabels(maxR: CGFloat) -> [SunburstSegmentKey: CachedLabel] {
        guard let layout = currentLayout else { return [:] }
        let id = ObjectIdentifier(layout)
        if currentLabelCacheLayoutID == id, abs(currentLabelCacheMaxR - maxR) < 0.5 { return currentLabelCache }
        let built = buildLabelCache(layout: layout, maxR: maxR)
        currentLabelCache = built
        currentLabelCacheLayoutID = id
        currentLabelCacheMaxR = maxR
        return built
    }

    private func previousLabels(maxR: CGFloat) -> [SunburstSegmentKey: CachedLabel] {
        guard let layout = previousLayout else { return [:] }
        let id = ObjectIdentifier(layout)
        if previousLabelCacheLayoutID == id, abs(previousLabelCacheMaxR - maxR) < 0.5 { return previousLabelCache }
        let built = buildLabelCache(layout: layout, maxR: maxR)
        previousLabelCache = built
        previousLabelCacheLayoutID = id
        previousLabelCacheMaxR = maxR
        return built
    }

    /// Labels only ring 1 and ring 2 (depth 0/1) — deeper rings are too thin/short to
    /// carry text at a legible size. Within those, a segment gets a label only if its
    /// arc length and ring thickness actually fit an (optionally middle-truncated)
    /// name at ~11pt; ring 2 is "roomy" exactly when it happens to pass that same test.
    private func buildLabelCache(layout: SunburstLayout, maxR: CGFloat) -> [SunburstSegmentKey: CachedLabel] {
        guard maxR > 0 else { return [:] }
        var result: [SunburstSegmentKey: CachedLabel] = [:]
        let nameAttrs: [NSAttributedString.Key: Any] = [.font: roundedFont(size: 11, weight: .medium)]
        let sizeAttrs: [NSAttributedString.Key: Any] = [.font: roundedFont(size: 9, weight: .regular)]

        for seg in layout.segments where seg.depth <= 1 {
            let inner = seg.innerFrac * maxR
            let outer = seg.outerFrac * maxR
            let ringThickness = outer - inner - SunburstConstants.ringGapPoints
            guard ringThickness >= 13 else { continue }

            let midR = (inner + outer) / 2
            let span = seg.endAngle - seg.startAngle
            guard span > 0.0005 else { continue }
            let arcLen = CGFloat(span) * midR - SunburstConstants.segmentGapPoints * 2 - 6
            guard arcLen >= 22 else { continue }

            var nameLine = CTLineCreateWithAttributedString(NSAttributedString(string: seg.displayName, attributes: nameAttrs))
            var nameAscent: CGFloat = 0, nameDescent: CGFloat = 0, nameLeading: CGFloat = 0
            var nameWidth = CGFloat(CTLineGetTypographicBounds(nameLine, &nameAscent, &nameDescent, &nameLeading))
            if nameWidth > arcLen {
                let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: nameAttrs))
                guard let truncated = CTLineCreateTruncatedLine(nameLine, Double(arcLen), .middle, ellipsis) else { continue }
                nameLine = truncated
                nameWidth = CGFloat(CTLineGetTypographicBounds(nameLine, &nameAscent, &nameDescent, &nameLeading))
                guard nameWidth <= arcLen + 0.5 else { continue } // doesn't even fit truncated — skip rather than clutter
                // "Co…ts" or "…y" tells nobody anything: only keep a truncated label
                // that still shows most of a short name, or at least 8 characters.
                let visible = CTLineGetGlyphCount(nameLine) - 1
                guard visible >= min(8, seg.displayName.count - 1) else { continue }
            }

            var sizeLine: CTLine?
            var sizeAscent: CGFloat = 0, sizeDescent: CGFloat = 0
            if ringThickness >= 27 {
                let candidate = CTLineCreateWithAttributedString(NSAttributedString(string: ByteFormat.string(seg.displaySize), attributes: sizeAttrs))
                var a: CGFloat = 0, d: CGFloat = 0, l: CGFloat = 0
                let w = CGFloat(CTLineGetTypographicBounds(candidate, &a, &d, &l))
                if w <= arcLen + 4 {
                    sizeLine = candidate
                    sizeAscent = a
                    sizeDescent = d
                }
            }

            let midAngle = (seg.startAngle + seg.endAngle) / 2
            // Same stacking as before (name above, size below, block centered on the
            // ring's mid-radius); "above" means outward on the top half and inward on
            // the bottom half, where the text is flipped to stay upright.
            let hasSize = sizeLine != nil
            let gap: CGFloat = hasSize ? 2 : 0
            let totalH = nameAscent + nameDescent + gap + (hasSize ? sizeAscent + sizeDescent : 0)

            result[seg.key] = CachedLabel(
                name: ArcText(nameLine), size: sizeLine.map(ArcText.init),
                nameBaselineOffset: totalH / 2 - nameAscent,
                sizeBaselineOffset: -totalH / 2 + sizeDescent,
                midAngle: midAngle, midRadius: midR,
                flipped: midAngle > .pi / 2 && midAngle < 1.5 * .pi,
                paint: seg.isOther ? nil : seg.paint)
        }
        return result
    }

    private func drawLabel(_ ctx: CGContext, _ label: CachedLabel, alpha: CGFloat, dark: Bool, liftPoints: CGFloat) {
        guard alpha > 0.01 else { return }
        ctx.saveGState()
        // Label-ink rule: pick ink per the segment's own resolved fill lightness, not a
        // blanket "always white in dark mode" — deep rings lighten enough in dark mode
        // that white can lose contrast. Synthetic/"Everything else" labels sit on the
        // plain canvas surface, so they keep the simple dark/light rule.
        let textColor: NSColor
        if let paint = label.paint {
            textColor = Palette.labelInk(paint, dark: dark)
        } else {
            textColor = dark ? NSColor.white : Palette.Synthetic.ink
        }
        let shadowColor = (dark ? NSColor.black : NSColor.white).withAlphaComponent(dark ? 0.6 : 0.7)
        ctx.setShadow(offset: CGSize(width: 0, height: dark ? -0.5 : 0.5), blur: 1.4, color: shadowColor.cgColor)

        let radius = label.midRadius + liftPoints
        ctx.setFillColor(textColor.withAlphaComponent(alpha).cgColor)
        drawArcText(ctx, label.name, label: label, radius: radius, baselineOffset: label.nameBaselineOffset)
        if let size = label.size {
            ctx.setFillColor(textColor.withAlphaComponent(alpha * 0.62).cgColor)
            drawArcText(ctx, size, label: label, radius: radius, baselineOffset: label.sizeBaselineOffset)
        }
        ctx.restoreGState()
    }

    /// Places each glyph on a circle around the chart center, turned to follow the
    /// curve. Angle 0 is twelve o'clock, increasing clockwise (see `sunburstPolarPoint`);
    /// top-half text runs clockwise, flipped bottom-half text counterclockwise.
    private func drawArcText(_ ctx: CGContext, _ text: ArcText, label: CachedLabel, radius: CGFloat, baselineOffset: CGFloat) {
        let direction: Double = label.flipped ? -1 : 1
        let baselineR = label.flipped ? radius - baselineOffset : radius + baselineOffset
        guard baselineR > 1 else { return }
        for run in text.runs {
            for i in run.glyphs.indices {
                let angle = label.midAngle + direction * Double(run.offsets[i] / baselineR)
                ctx.saveGState()
                ctx.translateBy(x: baselineR * CGFloat(sin(angle)), y: baselineR * CGFloat(cos(angle)))
                ctx.rotate(by: CGFloat(-angle) + (label.flipped ? .pi : 0))
                var glyph = run.glyphs[i]
                var origin = CGPoint(x: -run.advances[i] / 2, y: 0)
                CTFontDrawGlyphs(run.font, &glyph, &origin, 1, ctx)
                ctx.restoreGState()
            }
        }
    }

    // MARK: - Hover / hit testing

    private func effectiveHoverKey() -> SunburstSegmentKey? {
        if isMouseInside { return hoveredKey }
        guard let node = lastExternalHover else { return nil }
        return currentLayout?.byNodeID[ObjectIdentifier(node)]?.key
    }

    private func resolvedHoverSegment() -> SunburstSegment? {
        guard let key = effectiveHoverKey() else { return nil }
        return currentLayout?.byKey[key]
    }

    #if DEBUG
    /// DISCOTECH_LOG_RING_GEOMETRY=1: logs every ring-0/ring-1 segment's drawn inner/outer
    /// radius fraction and highlighted flag to stderr whenever the effective hover key
    /// changes, so a before/after hover diff can be read straight from the log instead of
    /// eyeballing screenshots. See the bug report this instruments: "hovering some segments
    /// causes other cards around the middle to pop or change size."
    var debug = SunburstDebugState()
    #endif

    // MARK: - Lineage highlight

    /// The hovered segment plus everything the lineage highlight needs to know about it:
    /// its ancestors (segments between it and the center) and its descendants (segments
    /// nested inside its angular span at a deeper ring). `nil`/empty when nothing is hovered.
    private struct HoverClassification: Equatable {
        var hoveredKey: SunburstSegmentKey?
        var ancestors: Set<SunburstSegmentKey> = []
        var descendants: Set<SunburstSegmentKey> = []
        static let empty = HoverClassification()
    }

    private enum HoverRole { case hovered, ancestor, descendant, dimmed, idle }

    private func role(of key: SunburstSegmentKey, in c: HoverClassification) -> HoverRole {
        guard c.hoveredKey != nil else { return .idle } // nothing hovered — no dimming at all
        if key == c.hoveredKey { return .hovered }
        if c.ancestors.contains(key) { return .ancestor }
        if c.descendants.contains(key) { return .descendant }
        return .dimmed
    }

    private func alphaMultiplier(for role: HoverRole) -> CGFloat {
        switch role {
        case .idle, .hovered, .ancestor: return 1
        case .descendant: return SunburstConstants.hoverDescendantAlpha
        // Increase Contrast: dim harder so the lineage path still reads unmistakably
        // even though the Studio palette's default dim is calmer than the old one.
        case .dimmed: return increaseContrast ? 0.55 : SunburstConstants.hoverDimAlpha
        }
    }

    private func ancestorRimAlpha(for role: HoverRole) -> CGFloat { role == .ancestor ? 1 : 0 }

    /// True when `node` is one of `state.emphasized` (a Findings card's nodes), or nested
    /// inside one — the Ball glows both, the "here, and everything in here" language a
    /// Finding needs (its matched folder, and whatever's drawn deeper inside it).
    func isNodeEmphasized(_ node: FileNode?) -> Bool {
        var n = node
        while let cur = n {
            if emphasized.contains(cur) { return true }
            n = cur.parent
        }
        return false
    }

    private func mixCG(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

    /// Ancestors: walk `parentNode.parent` up to (excluding) `focus`, picking up each
    /// ancestor's own segment — at most `maxRings` hops. Descendants: every other segment
    /// one-or-more rings deeper whose angular span is nested inside the hovered segment's
    /// (true by construction — a child's span is always a subset of its parent's — so this
    /// needs no tree walk at all, just a numeric containment check).
    private func computeClassification(for key: SunburstSegmentKey?, layout: SunburstLayout) -> HoverClassification {
        guard let key, let seg = layout.byKey[key] else { return .empty }
        var ancestors: Set<SunburstSegmentKey> = []
        var node: FileNode? = seg.parentNode
        while let p = node, p !== layout.focus {
            if let pSeg = layout.byNodeID[ObjectIdentifier(p)] { ancestors.insert(pSeg.key) }
            node = p.parent
        }
        var descendants: Set<SunburstSegmentKey> = []
        if !seg.isOther { // the "Everything else" bucket never has children segments of its own
            for other in layout.segments where other.depth > seg.depth {
                if other.startAngle >= seg.startAngle - 1e-9, other.endAngle <= seg.endAngle + 1e-9 {
                    descendants.insert(other.key)
                }
            }
        }
        return HoverClassification(hoveredKey: key, ancestors: ancestors, descendants: descendants)
    }

    /// Starts (or, under Reduce Motion, instantly applies) a cross-fade to the new hover
    /// classification, but only when the hovered *key* actually changed — classification
    /// itself is a Set-building pass, so this keeps every other redraw (dragging the
    /// mouse within the same wedge, an unrelated repaint) free of it.
    private func refreshHoverClassification(hoverKey: SunburstSegmentKey?, layout: SunburstLayout) {
        guard hoverKey != lastClassifiedHoverKey else { return }
        lastClassifiedHoverKey = hoverKey
        let newClass = computeClassification(for: hoverKey, layout: layout)
        // Same lineage as already shown or fading in (a relayout under a still pointer, a
        // theme change): nothing to cross-fade, so no timer.
        guard newClass != hoverBlendTo else { return }
        if reduceMotion || window == nil {
            hoverBlendFrom = newClass
            hoverBlendTo = newClass
            hoverBlendProgress = 1
            hoverBlendTimer?.invalidate()
            hoverBlendTimer = nil
            return
        }
        hoverBlendFrom = hoverBlendTo
        hoverBlendTo = newClass
        hoverBlendProgress = 0
        hoverBlendStart = CACurrentMediaTime()
        hoverBlendTimer?.invalidate()
        hoverBlendTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] timer in
            #if DEBUG
            SunburstNSView.debugTimerFires += 1
            #endif
            // The view is gone: stop instead of firing forever.
            guard let self else { timer.invalidate(); return }
            self.tickHoverBlend()
        }
    }

    private func tickHoverBlend() {
        let elapsed = CACurrentMediaTime() - hoverBlendStart
        let raw = min(1, elapsed / SunburstConstants.hoverBlendDuration)
        hoverBlendProgress = CGFloat(raw)
        needsDisplay = true
        if raw >= 1 {
            hoverBlendTimer?.invalidate()
            hoverBlendTimer = nil
        }
    }

    private func hitRegion(at viewPoint: CGPoint) -> SunburstHitRegion {
        guard let layout = currentLayout else { return .none }
        let b = bounds
        let center = CGPoint(x: b.midX, y: b.midY)
        let dx = viewPoint.x - center.x
        let dy = viewPoint.y - center.y
        let r = hypot(dx, dy)
        let maxR = min(b.width, b.height) / 2 - SunburstConstants.outerPadding
        guard maxR > 0 else { return .none }
        let rf = r / maxR
        if rf < SunburstConstants.centerFraction { return .center }

        var angle = atan2(dx, dy) // matches sunburstPolarPoint's convention: x = r*sin(a), y = r*cos(a)
        if angle < 0 { angle += 2 * .pi }

        for depth in 0..<SunburstConstants.maxRings {
            let frac = SunburstGeometry.fracRange(depth: depth)
            if rf >= frac.inner && rf < frac.outer {
                guard depth < layout.segmentsByDepth.count else { return .none }
                if let seg = binarySearchSegment(layout.segmentsByDepth[depth], angle: angle) {
                    return .segment(seg)
                }
                return .none
            }
        }
        return .none
    }

    private func binarySearchSegment(_ ring: [SunburstSegment], angle: Double) -> SunburstSegment? {
        var lo = 0, hi = ring.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let s = ring[mid]
            if angle < s.startAngle { hi = mid - 1 }
            else if angle >= s.endAngle { lo = mid + 1 }
            else { return s }
        }
        return nil
    }

    private func updateHover(at viewPoint: CGPoint) {
        isMouseInside = true
        let region = hitRegion(at: viewPoint)
        let newKey: SunburstSegmentKey?
        let newHoverNode: FileNode?
        switch region {
        case .center:
            newKey = nil
            newHoverNode = nil
        case .segment(let seg):
            newKey = seg.key
            newHoverNode = seg.node
        case .none:
            newKey = nil
            newHoverNode = nil
        }
        if newKey != hoveredKey {
            hoveredKey = newKey
            needsDisplay = true
        }
        if appState?.hovered !== newHoverNode {
            appState?.hovered = newHoverNode
            lastExternalHover = newHoverNode
        }
    }

    // MARK: - Mouse / tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let ta = NSTrackingArea(rect: bounds,
                                 options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                                 owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func mouseEntered(with event: NSEvent) {
        isMouseInside = true
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        isMouseInside = false
        if hoveredKey != nil { hoveredKey = nil; needsDisplay = true }
        if appState?.hovered != nil {
            appState?.hovered = nil
            lastExternalHover = nil
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch hitRegion(at: point) {
        case .center:
            appState?.zoomOut()
        case .segment(let seg):
            guard let node = seg.node else { return }
            if node.isDirectory {
                appState?.zoom(into: node)
            } else {
                appState?.selected = node
                appState?.hovered = node
                lastExternalHover = node
            }
        case .none:
            break
        }
    }

    // MARK: - Scroll navigation

    /// Vertical scroll over the Ball walks the hierarchy, one level per gesture: up /
    /// forward goes into the folder under the pointer, down / back goes out to the
    /// enclosing folder — the same `zoom(into:)` / `zoomOut()` a click on a wedge or on
    /// the centre makes, so the transition and the state are identical. The gesture
    /// rules (thresholds, momentum, cooldown) are `ScrollLevelNavigator`, shared with the Floor.
    private var scrollNavigator = ScrollLevelNavigator()

    override func scrollWheel(with event: NSEvent) {
        if !navigate(byScroll: event, at: convert(event.locationInWindow, from: nil)) {
            super.scrollWheel(with: event)
        }
    }

    /// Handles one scroll event at `point` (view coordinates). Returns false for events
    /// that aren't the Ball's to take (mostly horizontal, or nothing laid out yet), which
    /// then travel up the responder chain as before.
    func navigate(byScroll event: NSEvent, at point: CGPoint) -> Bool {
        guard appState != nil, currentLayout != nil else { return false }
        return scrollNavigator.handle(event) { [weak self] inward in
            guard let self, let appState = self.appState else { return }
            if inward {
                if let target = self.scrollTarget(at: point) { appState.zoom(into: target) }
            } else {
                appState.zoomOut()
            }
        }
    }

    /// The folder a scroll up goes into: the one under the pointer if it can be opened,
    /// else the selected item if it is an openable folder inside the focus, else none.
    private func scrollTarget(at point: CGPoint) -> FileNode? {
        func opens(_ node: FileNode) -> Bool {
            node.isDirectory && (!node.isPackage || !node.children.isEmpty)
        }
        if case .segment(let seg) = hitRegion(at: point), let node = seg.node, opens(node) { return node }
        if let selected = appState?.selected, let focus = appState?.focus,
           selected !== focus, selected.isDescendant(of: focus), opens(selected) {
            return selected
        }
        return nil
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard case .segment(let seg) = hitRegion(at: point), let node = seg.node, let appState else {
            super.rightMouseDown(with: event)
            return
        }
        let menu = NSMenu()
        menu.autoenablesItems = false  // so a blocked "Add to Crate" can show disabled
        /// A greyed-out line that explains, rather than acts.
        func note(_ text: String) {
            let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        if node.isSynthetic {
            // Not a file: no Quick Look, Finder or Crate actions.
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
        } else if !appState.isCollected(node) {
            menu.addItem(SunburstClosureMenuItem(title: "Add to \(Brand.crate)") { appState.collect(node) })
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    /// The root node's `name` is its full filesystem path (see `FileNode`); show
    /// the friendly volume/folder display name instead, matching the breadcrumb bar.
    private static func displayName(for node: FileNode) -> String {
        node.parent == nil ? FileManager.default.displayName(atPath: node.path) : node.name
    }

    /// `(used, capacity)` when `focus` is a scanned volume's own root (it has a
    /// `SpaceAccounting`-added `.freeSpace` child), else `nil` for an ordinary folder.
    private static func volumeTotals(for focus: FileNode) -> (used: Int64, capacity: Int64)? {
        guard focus.parent == nil, let free = focus.children.first(where: { $0.kind == .freeSpace }) else { return nil }
        return (used: focus.size - free.size, capacity: focus.size)
    }
}

/// `angle = 0` is twelve o'clock, increasing clockwise: x = r*sin(a), y = r*cos(a)
/// (view is not flipped, so +y is up). `hitRegion` inverts this with `atan2(dx, dy)`.
func sunburstPolarPoint(angle: Double, radius: CGFloat) -> CGPoint {
    CGPoint(x: radius * CGFloat(sin(angle)), y: radius * CGFloat(cos(angle)))
}

/// Builds a rounded-corner annular-sector path: a real gap is cut on both the
/// angular and radial sides (so segments never touch — a modern segmented
/// donut, not a flat pie), then the four resulting corners are rounded via
/// `CGPath`'s tangent-arc primitive. The two arc edges are walked in ~3° steps
/// (our clockwise-from-12-o'clock angle convention doesn't match
/// `CGPath.addArc`'s), which stay plain `addLine`s — only the four true
/// corners (where an arc meets a radial edge) get `addArc(tangent1End:tangent2End:)`.
/// Returns `nil` if the gaps consume the whole segment (vanishingly thin wedges).
private func sunburstSectorPath(start: Double, end: Double, inner: CGFloat, outer: CGFloat) -> CGPath? {
    let midR = max(1, (inner + outer) / 2)
    let angularGapHalf = Double(SunburstConstants.segmentGapPoints / 2) / Double(midR)
    let s = start + angularGapHalf
    let e = end - angularGapHalf
    let i = inner + SunburstConstants.ringGapPoints / 2
    let o = outer - SunburstConstants.ringGapPoints / 2
    guard e > s, o > i + 0.5 else { return nil }

    let span = e - s
    let steps = max(1, Int(ceil(abs(span) * 180 / .pi / 3)))
    var outerPts: [CGPoint] = []
    var innerPts: [CGPoint] = []
    outerPts.reserveCapacity(steps + 1)
    innerPts.reserveCapacity(steps + 1)
    for k in 0...steps {
        let a = s + span * Double(k) / Double(steps)
        outerPts.append(sunburstPolarPoint(angle: a, radius: o))
        innerPts.append(sunburstPolarPoint(angle: a, radius: i))
    }
    let n = outerPts.count // == innerPts.count, >= 2
    let firstChord = max(1, hypot(outerPts[1].x - outerPts[0].x, outerPts[1].y - outerPts[0].y))
    let r = max(0, min(SunburstConstants.cornerRadiusPoints, (o - i) / 2.4, firstChord / 2.2))

    let mid = CGPoint(x: (outerPts[0].x + innerPts[0].x) / 2, y: (outerPts[0].y + innerPts[0].y) / 2)
    let path = CGMutablePath()
    path.move(to: mid)
    sunburstRoundedCorner(path, tangent1: outerPts[0], tangent2: outerPts[1], radius: r) // corner D
    if n > 2 { for k in 1...(n - 2) { path.addLine(to: outerPts[k]) } }
    sunburstRoundedCorner(path, tangent1: outerPts[n - 1], tangent2: innerPts[n - 1], radius: r) // corner A
    sunburstRoundedCorner(path, tangent1: innerPts[n - 1], tangent2: innerPts[n - 2], radius: r) // corner B
    if n > 2 { for k in stride(from: n - 2, through: 1, by: -1) { path.addLine(to: innerPts[k]) } }
    sunburstRoundedCorner(path, tangent1: innerPts[0], tangent2: mid, radius: r) // corner C
    path.closeSubpath()
    return path
}

private func sunburstRoundedCorner(_ path: CGMutablePath, tangent1: CGPoint, tangent2: CGPoint, radius: CGFloat) {
    if radius > 0.15 {
        path.addArc(tangent1End: tangent1, tangent2End: tangent2, radius: radius)
    } else {
        path.addLine(to: tangent1)
    }
}
