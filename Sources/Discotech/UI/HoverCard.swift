import Combine
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Hover info

/// Everything the hover UI needs about the item under the pointer, derived once per
/// hover change: the item, the focus it's seen from, and the chain of rings between them.
struct HoverInfo: Equatable {
    /// One ring between the focus and the hovered item, with its chart color.
    struct Step: Identifiable {
        let node: FileNode
        let tint: Color
        var id: ObjectIdentifier { ObjectIdentifier(node) }
    }

    let node: FileNode
    let focus: FileNode
    /// From the focus's direct child down to `node` (last). Never includes the focus.
    let lineage: [Step]

    /// Deepest chain we'll walk. The chart draws `SunburstConstants.maxRings`; anything
    /// deeper than this can't come from the chart and isn't worth a card.
    private static let maxSteps = 16

    /// nil when `node` is the focus itself or isn't inside it.
    init?(node: FileNode, focus: FileNode) {
        var chain: [FileNode] = []
        var cur: FileNode? = node
        while let n = cur, n !== focus {
            chain.append(n)
            guard chain.count <= Self.maxSteps else { return nil }
            cur = n.parent
        }
        guard cur === focus, !chain.isEmpty else { return nil }
        self.node = node
        self.focus = focus
        self.lineage = chain.reversed().map { Step(node: $0, tint: Palette.color(for: $0, in: focus)) }
    }

    /// The focus's child that holds `node` — its row in the sidebar.
    var topLevel: FileNode { lineage[0].node }
    var tint: Color { lineage[lineage.count - 1].tint }
    /// The folder the chart shows `node` inside of (the focus for a direct child).
    var parent: FileNode { node.parent ?? focus }
    var isDirectChild: Bool { lineage.count == 1 }

    var shareOfParent: Double { Self.share(node.size, of: parent.size) }
    var shareOfFocus: Double { Self.share(node.size, of: focus.size) }

    private static func share(_ part: Int64, of whole: Int64) -> Double {
        whole > 0 ? min(1, max(0, Double(part) / Double(whole))) : 0
    }

    static func == (a: HoverInfo, b: HoverInfo) -> Bool { a.node === b.node && a.focus === b.focus }
}

// MARK: - Hover model

/// Turns `state.hovered` (which flips on every segment the pointer crosses) into a calm
/// `HoverInfo`: a new item shows at once; losing the item waits `Tokens.Motion.hoverGrace`
/// first, so crossing the hairline gaps between segments doesn't blink the card.
/// Zooming clears it immediately — a card about the old folder would be wrong.
@MainActor
final class HoverModel: ObservableObject {
    @Published private(set) var info: HoverInfo?

    private weak var state: AppState?
    private var subscriptions: Set<AnyCancellable> = []
    private var pendingClear: DispatchWorkItem?

    func attach(to state: AppState) {
        guard self.state !== state else { return }
        self.state = state
        subscriptions = []
        // @Published emits on willSet, synchronously: the new value arrives as the
        // argument and the update lands in the same render pass as the chart's.
        state.$focus
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.reset() } }
            .store(in: &subscriptions)
        state.$hovered
            .sink { [weak self] node in MainActor.assumeIsolated { self?.hoverChanged(to: node) } }
            .store(in: &subscriptions)
    }

    private func hoverChanged(to node: FileNode?) {
        if let node, let focus = state?.focus, let next = HoverInfo(node: node, focus: focus) {
            pendingClear?.cancel()
            pendingClear = nil
            if info != next { info = next }
            return
        }
        guard info != nil, pendingClear == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.pendingClear = nil
                self?.info = nil
            }
        }
        pendingClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Tokens.Motion.hoverGrace, execute: work)
    }

    private func reset() {
        pendingClear?.cancel()
        pendingClear = nil
        if info != nil { info = nil }
    }
}

// MARK: - Chart stage

/// The canvas plus the hover card, laid out so the card **never covers the canvas** in
/// any mode. The card always gets space of its own, reserved structurally (padding),
/// never floated over content:
///
/// - **Column**: the card floats in a column on the trailing edge and the canvas is
///   padded out of it. Only the Ball uses it, and only when that leaves the ball at
///   least as big as the strip would — a round chart in a landscape area has spare
///   width at its sides, so the column usually costs nothing.
/// - **Strip**: the card docks as a compact strip along the canvas bottom and the
///   canvas is padded above it. Rectangular canvases (Layers, Floor) fill all their
///   area, so a strip — the cheapest reserve in area — is what they always use; the
///   Ball uses it when the canvas is too narrow for a column.
///
/// The reserve is there whether or not anything is hovered, so hovering never moves
/// the canvas.
struct ChartStage: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        GeometryReader { geo in
            let placement = CardPlacement(size: geo.size, mode: state.canvasMode)
            ZStack(alignment: .bottomTrailing) {
                canvas
                    .padding(.leading, placement.leading)
                    .padding(.trailing, placement.trailing)
                    .padding(.bottom, placement.bottom)
                switch placement.style {
                case .column:
                    HoverCardLayer(mode: state.canvasMode)
                        .padding(Tokens.Space.l)
                case .strip:
                    HoverStrip(mode: state.canvasMode)
                        .padding(.horizontal, Tokens.Space.l)
                        .padding(.bottom, Tokens.Space.l)
                }
            }
            #if DEBUG
            .onAppear { DebugHooks.logPlacement(placement, size: geo.size) }
            .onChange(of: placement) { _, p in DebugHooks.logPlacement(p, size: geo.size) }
            #endif
        }
    }

    @ViewBuilder private var canvas: some View {
        switch state.canvasMode {
        case .ball: SunburstView()
        case .columns: ColumnsView()
        case .floor: FloorView()
        }
    }
}

/// Where the hover card lives for a canvas of `size`, and how much of the canvas to
/// hand it.
struct CardPlacement: Equatable {
    enum Style { case column, strip }
    let style: Style
    let trailing: CGFloat
    /// Mirrors `trailing` for the Ball, so the chart stays centred in the window and the
    /// card's column is balanced by empty space on the other side.
    let leading: CGFloat
    let bottom: CGFloat

    /// Card width plus its margin on both sides.
    static let columnReserve = Tokens.Size.hoverCardWidth + Tokens.Space.l * 2
    /// Strip height, its bottom margin and a gap above it.
    static let stripReserve = Tokens.Size.hoverStripHeight + Tokens.Space.l + Tokens.Space.s

    init(size: CGSize, mode: AppState.CanvasMode) {
        let useColumn: Bool
        switch mode {
        case .ball:
            // Pick whichever reserve leaves the bigger ball. Either way the ball is
            // centred: the column is reserved on both sides, the strip only below.
            let withColumn = min(size.width - Self.columnReserve * 2, size.height)
            let withStrip = min(size.width, size.height - Self.stripReserve)
            useColumn = withColumn >= withStrip
        case .columns, .floor:
            useColumn = false
        }
        if useColumn {
            style = .column
            trailing = Self.columnReserve
            leading = mode == .ball ? Self.columnReserve : 0
            bottom = 0
        } else {
            style = .strip
            trailing = 0
            leading = 0
            bottom = Self.stripReserve
        }
    }
}

/// Fades the floating card in and out; swaps its contents in place while it's up.
/// With nothing hovered it shows a quiet hint instead (the column is reserved anyway).
struct HoverCardLayer: View {
    let mode: AppState.CanvasMode
    @EnvironmentObject private var hover: HoverModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let info = hover.info
        ZStack(alignment: .bottomTrailing) {
            if let info {
                HoverCard(info: info)
                    .transition(transition)
            } else {
                IdleHint(mode: mode, stacked: true)
                    .frame(width: Tokens.Size.hoverCardWidth, alignment: .trailing)
                    .transition(.opacity)
            }
        }
        // Keyed on visibility only: moving from one item to the next never re-animates.
        .animation(Tokens.Motion.hover(reduceMotion), value: info == nil)
        .allowsHitTesting(false)
        // The sidebar rows already speak for the item under keyboard focus; the card
        // is a pointer-only echo of them, so VoiceOver skips it.
        .accessibilityHidden(true)
    }

    private var transition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: Tokens.Space.s))
    }
}

/// Empty state for the card's space: teaches the hover interaction, Quick Look and (on
/// the Ball and the Floor) scroll navigation.
private struct IdleHint: View {
    let mode: AppState.CanvasMode
    /// Stacked lines (the column) or one line (the strip).
    let stacked: Bool

    private var pointAt: String {
        switch mode {
        case .ball: "Point at the Ball to see what’s inside"
        case .columns: "Point at a layer to see what’s inside"
        case .floor: "Point at a block to see what’s inside"
        }
    }

    var body: some View {
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .trailing, spacing: Tokens.Space.xs))
                             : AnyLayout(HStackLayout(spacing: Tokens.Space.l))
        layout {
            Label(pointAt, systemImage: "cursorarrow.rays")
                .lineLimit(1)
            Label("Space previews the selection", systemImage: "space")
                .lineLimit(1)
                .foregroundStyle(Tokens.Colors.textTertiary)
            // Scroll navigation (SunburstNSView / FloorNSView scrollWheel, via
            // ScrollLevelNavigator). Last, so in the one-line strip it is what truncates first.
            if mode == .ball || mode == .floor {
                Label(SunburstView.scrollHint, systemImage: "arrow.up.and.down")
                    .lineLimit(1)
                    .foregroundStyle(Tokens.Colors.textTertiary)
            }
        }
        .font(.callout)
        .foregroundStyle(Tokens.Colors.textSecondary)
        .truncationMode(.tail)
    }
}

// MARK: - Docked strip

/// The hover card docked along the canvas bottom: one line of the same facts, scaled
/// to the width it has (lineage and shares drop out first; name and size never do).
struct HoverStrip: View {
    let mode: AppState.CanvasMode
    @EnvironmentObject private var hover: HoverModel

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
        Group {
            if let info = hover.info {
                ViewThatFits(in: .horizontal) {
                    StripContent(info: info, showsLineage: true, showsShares: true)
                    StripContent(info: info, showsLineage: false, showsShares: true)
                    StripContent(info: info, showsLineage: false, showsShares: false)
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    IdleHint(mode: mode, stacked: false)
                    IdleHint(mode: mode, stacked: false).labelStyle(.titleOnly)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, Tokens.Space.l)
        .frame(maxWidth: .infinity, minHeight: Tokens.Size.hoverStripHeight,
               maxHeight: Tokens.Size.hoverStripHeight, alignment: .leading)
        .cardSurface(shape)
        .clipShape(shape)
        .allowsHitTesting(false)
        .accessibilityHidden(true)  // pointer-only echo of the sidebar row, as the card
    }
}

private struct StripContent: View {
    let info: HoverInfo
    let showsLineage: Bool
    let showsShares: Bool

    private var node: FileNode { info.node }

    var body: some View {
        HStack(spacing: Tokens.Space.m) {
            NodeIcon(node: node, size: Tokens.Size.hoverStripIcon, urgent: true)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tokens.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(HoverCard.kindLine(for: node))
                    .font(.caption)
                    .foregroundStyle(Tokens.Colors.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: 240, alignment: .leading)
            .fixedSize(horizontal: showsShares, vertical: false)
            if showsLineage, !info.isDirectChild {
                LineageTrail(info: info, dropsFocus: true)
                    .lineLimit(1)
                    .fixedSize()
            }
            Spacer(minLength: Tokens.Space.m)
            if showsShares {
                if let explanation = node.kind.explanation {
                    Text(explanation)
                        .font(.caption)
                        .foregroundStyle(Tokens.Colors.textSecondary)
                        .lineLimit(1)
                        .frame(maxWidth: 260, alignment: .trailing)
                        .fixedSize()
                } else {
                    VStack(alignment: .trailing, spacing: Tokens.Space.xs) {
                        (Text(Percent.string(info.shareOfParent)).fontWeight(.semibold).monospacedDigit()
                            + Text(" of \(CrumbName.of(info.parent))"))
                            .font(.caption)
                            .foregroundStyle(Tokens.Colors.textSecondary)
                            .lineLimit(1)
                        FillBar(fraction: info.shareOfParent, tint: info.tint, height: Tokens.Size.shareBar)
                            .frame(width: 120)
                    }
                    .fixedSize()
                }
            }
            Text(Bytes.string(node.size))
                .font(Tokens.Typeface.figure(22))
                .foregroundStyle(Tokens.Colors.textPrimary)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

// MARK: - Card

/// The floating glass card for the hovered item. Pure function of `info` (plus the
/// current selection, for the preview hint), so updates are a cheap in-place redraw.
struct HoverCard: View {
    let info: HoverInfo
    @EnvironmentObject private var state: AppState

    private var node: FileNode { info.node }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.m) {
            header
            LineageTrail(info: info, dropsFocus: false)
                .lineLimit(3)
            figures
            if let hint { hintLine(hint) }
        }
        .padding(.horizontal, Tokens.Space.l)
        .padding(.vertical, Tokens.Space.m + Tokens.Space.xxs)
        .frame(width: Tokens.Size.hoverCardWidth, alignment: .leading)
        .glassSurface(RoundedRectangle(cornerRadius: Tokens.Radius.hoverCard, style: .continuous))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Tokens.Space.m) {
            NodeIcon(node: node, size: Tokens.Size.hoverCardIcon, urgent: true)
            VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
                Text(node.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Tokens.Colors.textPrimary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(Self.kindLine(for: node))
                    .font(.caption)
                    .foregroundStyle(Tokens.Colors.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder private var figures: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s) {
            Text(Bytes.string(node.size))
                .font(Tokens.Typeface.figureHero)
                .foregroundStyle(Tokens.Colors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let explanation = node.kind.explanation {
                // Accounting nodes: a share of "the folder" means nothing here.
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(Tokens.Colors.textSecondary)
                    .lineLimit(4)
            } else {
                ShareLines(info: info)
            }
        }
    }

    private func hintLine(_ text: String) -> some View {
        Label(text, systemImage: node.isDirectory ? "cursorarrow.click" : "space")
            .font(.caption)
            .foregroundStyle(Tokens.Colors.textSecondary)
            .lineLimit(1)
    }

    private var isZoomable: Bool { node.isDirectory && (!node.isPackage || !node.children.isEmpty) }

    private var hint: String? {
        if node.isSynthetic { return nil }
        if isZoomable { return "Click to open" }
        // Space previews the selection first, the hovered item only when nothing is selected.
        if let selected = state.selected, selected !== node { return "Click, then Space to preview" }
        return "Space to preview"
    }

    static func kindLine(for node: FileNode) -> String {
        switch node.kind {
        case .freeSpace, .purgeable, .hidden, .snapshot: return "Not a file"
        case .item: break
        }
        let files = Count.files(node.fileCount)
        if node.isPackage { return "\(typeName(node.name) ?? "Package") · \(files)" }
        if node.isDirectory { return "Folder · \(files)" }
        return typeName(node.name) ?? "File"
    }

    /// "PNG image", "Application", … from the extension alone — no disk access on hover.
    private static func typeName(_ name: String) -> String? {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, let description = UTType(filenameExtension: ext)?.localizedDescription else { return nil }
        return description.prefix(1).uppercased() + description.dropFirst()
    }
}

/// "42% of debug" under a thin bar, then "3.1% of lightbox" when the parent isn't the focus.
private struct ShareLines: View {
    let info: HoverInfo

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            FillBar(fraction: info.shareOfParent, tint: info.tint)
            share(info.shareOfParent, of: info.parent, emphasized: true)
            if !info.isDirectChild {
                share(info.shareOfFocus, of: info.focus, emphasized: false)
            }
        }
    }

    private func share(_ fraction: Double, of folder: FileNode, emphasized: Bool) -> some View {
        (Text(Percent.string(fraction)).font(.system(.callout, design: .rounded, weight: .semibold)).monospacedDigit()
            + Text(" of \(CrumbName.of(folder))"))
            .font(.callout)
            .foregroundStyle(emphasized ? Tokens.Colors.textPrimary : Tokens.Colors.textSecondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// `lightbox › target › debug › deps`, each ring marked with its chart color. The
/// color rides on a dot rather than the text so names stay legible on pale glass.
struct LineageTrail: View {
    let info: HoverInfo
    /// Start at the focus's child (the strip, where the path bar already shows the focus).
    let dropsFocus: Bool

    var body: some View {
        trail
            .font(.caption)
            .truncationMode(.head)
    }

    private var trail: Text {
        var text = dropsFocus ? Text("") : Text(CrumbName.of(info.focus)).foregroundStyle(Tokens.Colors.textSecondary)
        let last = info.lineage.count - 1
        for (i, step) in info.lineage.enumerated() {
            if i > 0 || !dropsFocus { text = text + separator }
            text = text + dot(step.tint) + name(step.node.name, isLast: i == last)
        }
        return text
    }

    private var separator: Text { Text("  ›  ").foregroundStyle(Tokens.Colors.textTertiary) }

    private func dot(_ tint: Color) -> Text {
        Text(Image(systemName: "circle.fill")).font(.system(size: 7)).foregroundStyle(tint) + Text(" ")
    }

    private func name(_ name: String, isLast: Bool) -> Text {
        Text(name)
            .fontWeight(isLast ? .semibold : .regular)
            .foregroundStyle(isLast ? Tokens.Colors.textPrimary : Tokens.Colors.textSecondary)
    }
}

// MARK: - Formatting

enum Percent {
    /// "42%", "3.1%", "<0.1%" — one decimal only where whole numbers would read as 0.
    static func string(_ fraction: Double) -> String {
        let p = fraction * 100
        if p <= 0 { return "0%" }
        if p < 0.1 { return "<0.1%" }
        if p < 10 { return String(format: "%.1f%%", p) }
        return "\(Int(p.rounded()))%"
    }
}

enum CrumbName {
    /// The root shows as its volume/folder display name; everything else by its own name.
    static func of(_ node: FileNode) -> String {
        node.parent == nil ? FileManager.default.displayName(atPath: node.path) : node.name
    }
}
