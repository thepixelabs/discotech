import SwiftUI

/// Children of `state.focus`, largest first, capped at `Tokens.sidebarRowLimit` rows.
///
/// A custom `LazyVStack` rather than `List`: full control of the row look, and the
/// `List`/NSTableView backing logged reentrancy warnings when chart hover re-rendered rows.
///
/// Keyboard: ↑/↓ move between rows and select them (the chart highlights the selected
/// row), → or Return opens a folder, ← goes up a level, Space shows Quick Look.
/// Mouse: clicking a folder opens it; clicking anything else selects it.
struct SidebarView: View {
    enum Tab: String {
        case findings, items

        /// The tab a new tree opens on (`AppState.root`): a whole-disk scan opens on
        /// Findings, a folder scan on Items — see `SpaceAccounting.annotate`, which only adds
        /// a `.freeSpace` child for a volume root.
        @MainActor static func initial(for root: FileNode?) -> Tab {
            let byScanKind: Tab = (root?.children.contains { $0.kind == .freeSpace } ?? false) ? .findings : .items
            #if DEBUG
            return DebugHooks.forcedSidebarTab ?? byScanKind
            #else
            return byScanKind
            #endif
        }
    }

    @EnvironmentObject var state: AppState
    @EnvironmentObject private var hover: HoverModel
    @FocusState private var focusedRow: ObjectIdentifier?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Plain reference boxes: written on every hover/scroll, never trigger a redraw.
    @State private var tints = TintCache()
    @State private var reveal = RowReveal()

    /// `state.findings`. Both it and the tab (`state.sidebarTab`) live in `AppState`, so the
    /// window rebuild a theme change makes keeps them.
    @EnvironmentObject private var findingsModel: FindingsModel
    /// Short window: the Crate folds to one line and Findings cards drop their
    /// explanation, so the list keeps usable room.
    @State private var compact = false

    var body: some View {
        let _ = state.treeVersion  // redraw after trashing mutates the tree in place
        // The Crate is a layout sibling below the list (not an overlay/inset), so it is
        // always fully visible and never covers rows.
        VStack(spacing: 0) {
            tabPicker
            Group {
                if state.sidebarTab == .findings {
                    FindingsListView(model: findingsModel, compact: compact)
                } else {
                    content
                }
            }
            .frame(maxHeight: .infinity)
            CrateView(compact: compact)
                .padding(.horizontal, Tokens.Space.s + Tokens.Space.xxs)
                .padding(.bottom, Tokens.Space.s + Tokens.Space.xxs)
                .padding(.top, Tokens.Space.xs)
                .layoutPriority(1)
                #if DEBUG
                .debugFrame("crate")
                #endif
        }
        #if DEBUG
        .debugFrame("sidebar")
        #endif
        .readSize { compact = $0.height < Tokens.Breakpoint.compactSidebarHeight }
        .background(SnapshotSupport.flatSurfaces ? Tokens.Colors.sidebar : .clear)
        .onChange(of: state.focus?.id) { old, _ in
            // Backing out of a folder selects it, like Finder, so Space previews it
            // and ↑/↓ continue from there.
            guard let old, let came = state.focus?.children.first(where: { $0.id == old }) else { return }
            state.selected = came
        }
        // The files view belongs to the Findings tab; leave it when the tab changes.
        .onChange(of: state.sidebarTab) { _, _ in state.closeFindingDetail() }
        #if DEBUG
        .onAppear { DebugHooks.sidebarAppeared(state, instance: ObjectIdentifier(reveal)) }
        .onChange(of: findingsModel.isComputing) { _, computing in
            DebugHooks.findingsComputed(computing, state, findingsModel)
        }
        #endif
    }

    private var tabPicker: some View {
        Picker("Sidebar tab", selection: $state.sidebarTab) {
            Text("Findings").tag(Tab.findings)
            Text("Items").tag(Tab.items)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .padding(.horizontal, Tokens.Space.s + Tokens.Space.xxs)
        .padding(.top, Tokens.Space.xs)
        .padding(.bottom, Tokens.Space.s)
    }

    @ViewBuilder private var content: some View {
        Group {
            if let focus = state.focus {
                if focus.children.isEmpty {
                    ContentUnavailableView("Nothing in here", systemImage: "folder",
                                           description: Text("This folder doesn’t take up any space."))
                        .frame(maxHeight: .infinity)
                } else {
                    list(for: focus).id(focus.id)  // new folder → start at the top
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func list(for focus: FileNode) -> some View {
        let children = focus.children
        let shown = Array(children.prefix(Tokens.sidebarRowLimit))
        let tints = self.tints.colors(for: focus, limit: shown.count, version: state.treeVersion)
        let info = hover.info
        let hovered = info?.node
        let container = info?.topLevel
        let selected = state.selected
        let total = Double(max(focus.size, 1))

        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Tokens.Space.xxs) {
                    Text("\(Count.items(children.count)), largest first")
                        .font(.caption)
                        .foregroundStyle(Tokens.Colors.textTertiary)
                        .padding(.horizontal, Tokens.Space.s)
                        .padding(.bottom, Tokens.Space.xs)

                    ForEach(shown) { node in
                        NodeRow(node: node,
                                fraction: Double(node.size) / total,
                                tint: tints[node.id] ?? Tokens.Colors.accent,
                                hover: node === hovered ? .direct : (node === container ? .contains : .none),
                                isSelected: selected === node,
                                isFocused: focusedRow == node.id,
                                isInCrate: state.isCollected(node),
                                protection: Safety.protectionReason(for: node),
                                state: state)
                            .id(node.id)
                            .focusable()
                            .focusEffectDisabled()
                            .focused($focusedRow, equals: node.id)
                            .modifier(TrackRowVisibility(id: node.id, reveal: reveal))
                    }

                    if children.count > shown.count {
                        let rest = children.dropFirst(shown.count)
                        EverythingElseRow(count: rest.count, size: rest.reduce(0) { $0 + $1.size })
                    }
                }
                .padding(.horizontal, Tokens.Space.s)
                .padding(.top, Tokens.Space.xs)
                .padding(.bottom, Tokens.Space.xl)
            }
            .modifier(BottomFade())
            .onHover { reveal.pointerInList = $0 }
            .onChange(of: container.map(ObjectIdentifier.init)) { _, id in
                revealRow(id, in: shown, proxy: proxy)
            }
            // Keyboard focus and selection move together: focusing a row selects it (so
            // Space previews it and the chart highlights it), and selecting a row by
            // click or from Quick Look arrows focuses it.
            .onChange(of: focusedRow) { _, id in
                guard let id, let node = shown.first(where: { $0.id == id }) else { return }
                proxy.scrollTo(id)
                state.hovered = node
                if state.selected !== node { state.selected = node }
            }
            .onChange(of: state.selected?.id) { _, id in
                guard let id, shown.contains(where: { $0.id == id }), focusedRow != id else { return }
                focusedRow = id
                proxy.scrollTo(id)
            }
            .onAppear {
                // Arriving with a selection already set (e.g. after backing out of a
                // folder, which selects it): show it and keep the keyboard there.
                guard let id = state.selected?.id, shown.contains(where: { $0.id == id }) else { return }
                focusedRow = id
                proxy.scrollTo(id, anchor: .center)
            }
            .onKeyPress(.downArrow) { moveFocus(+1, in: shown) }
            .onKeyPress(.upArrow) { moveFocus(-1, in: shown) }
            .onKeyPress(.rightArrow) { openFocused(in: shown) }
            .onKeyPress(.return) { openFocused(in: shown) }
            .onKeyPress(.leftArrow) {
                state.zoomOut()
                return .handled
            }
        }
    }

    /// When the pointer rests on a chart item whose row is scrolled out of sight, bring
    /// that row just into view (minimal scroll, no re-centering). Skipped while the
    /// pointer is in the list itself, and after a short dwell so sweeping over the chart
    /// doesn't drag the list around.
    private func revealRow(_ id: ObjectIdentifier?, in rows: [FileNode], proxy: ScrollViewProxy) {
        reveal.pending?.cancel()
        reveal.pending = nil
        guard let id, !reveal.pointerInList, !reveal.visible.contains(id),
              rows.contains(where: { $0.id == id }) else { return }
        let animation = Tokens.Motion.state(reduceMotion)
        reveal.pending = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Tokens.Motion.revealDwell * 1_000_000_000))
            guard !Task.isCancelled, !reveal.pointerInList, !reveal.visible.contains(id) else { return }
            withAnimation(animation) { proxy.scrollTo(id) }
        }
    }

    private func moveFocus(_ delta: Int, in rows: [FileNode]) -> KeyPress.Result {
        guard !rows.isEmpty else { return .ignored }
        let current = rows.firstIndex { $0.id == focusedRow } ?? (delta > 0 ? -1 : rows.count)
        focusedRow = rows[max(0, min(rows.count - 1, current + delta))].id
        return .handled
    }

    private func openFocused(in rows: [FileNode]) -> KeyPress.Result {
        guard let node = rows.first(where: { $0.id == focusedRow }) else { return .ignored }
        if node.isDirectory { state.zoom(into: node) } else { state.open(node) }
        return .handled
    }
}

/// One child of the focus. Takes `state` as a plain reference (not an environment
/// object) so hovering one row doesn't re-render all 200.
struct NodeRow: View {
    /// How this row relates to the item under the pointer.
    enum HoverRelation { case none, direct, contains }

    let node: FileNode
    let fraction: Double
    let tint: Color
    let hover: HoverRelation
    let isSelected: Bool
    let isFocused: Bool
    let isInCrate: Bool
    /// Why this item may never go in the Crate (system / locked / key folder), if so.
    let protection: String?
    let state: AppState

    private var isZoomable: Bool { node.isDirectory && (!node.isPackage || !node.children.isEmpty) }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Tokens.Radius.row, style: .continuous) }

    // Kept as small pieces: one long modifier chain here made the type checker time out.
    var body: some View {
        content
            .padding(.horizontal, Tokens.Space.s + Tokens.Space.xxs)
            .padding(.vertical, Tokens.Space.s)
            .background(fill, in: shape)
            .overlay(alignment: .leading) {
                if isSelected { leadingBar(Tokens.Colors.accent) } else if hover == .contains { leadingBar(tint) }
            }
            .overlay { if isFocused { shape.strokeBorder(Tokens.Colors.accent, lineWidth: 2) } }
            .opacity(isInCrate ? Tokens.Emphasis.inCrate : 1)
            .contentShape(shape)
            .onHover(perform: hover)
            .onTapGesture(perform: tap)
            .modifier(NodeDrag(node: node))
            .contextMenu { NodeMenu(node: node, state: state) }
            .modifier(NodeRowAccessibility(node: node, fraction: fraction, isZoomable: isZoomable,
                                           isSelected: isSelected, isInCrate: isInCrate,
                                           protection: protection, state: state))
    }

    private var content: some View {
        HStack(spacing: Tokens.Space.m - Tokens.Space.xxs) {
            NodeIcon(node: node)
            VStack(alignment: .leading, spacing: Tokens.Space.s - Tokens.Space.xxs) {
                titleLine
                FillBar(fraction: fraction, tint: tint, height: Tokens.Size.rowShareBar)
            }
            // Only where it's useful: the whole row is the click target anyway.
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Tokens.Colors.textSecondary)
                .opacity(isZoomable && (hover == .direct || isSelected || isFocused) ? 1 : 0)
                .accessibilityHidden(true)
        }
    }

    private var titleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s) {
            Text(node.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(node.isSynthetic ? Tokens.Colors.textSecondary : Tokens.Colors.textPrimary)
            badges
            Spacer(minLength: Tokens.Space.s)
            Text(ByteFormat.string(node.size))
                .font(.system(.callout, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Tokens.Colors.textSecondary)
                .lineLimit(1)
                .fixedSize()
                .layoutPriority(1)
        }
    }

    /// A short bar on the row's leading edge: accent for the selected row, the row's
    /// chart color for "what you're pointing at is in here".
    private func leadingBar(_ color: Color) -> some View {
        Capsule()
            .fill(color)
            .frame(width: Tokens.Size.containsBar)
            .padding(.vertical, Tokens.Space.s)
            .accessibilityHidden(true)
    }

    @ViewBuilder private var badges: some View {
        if hover == .contains {
            Image(systemName: "arrow.turn.down.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Tokens.Colors.textSecondary)
                .accessibilityHidden(true)
        }
        if let protection {
            Image(systemName: "lock.fill")
                .font(.caption2)
                .foregroundStyle(Tokens.Colors.textSecondary)
                .help(protection)
        }
        if isInCrate {
            Image(systemName: "archivebox.fill")
                .font(.caption2)
                .foregroundStyle(Tokens.Colors.textSecondary)
                .help("In the \(Brand.crate)")
        }
    }

    /// Selection (what Space previews) wins over the chart-linked hover highlight.
    private var fill: Color {
        if isSelected { return Tokens.Colors.selection }
        switch hover {
        case .direct: return tint.opacity(Tokens.Emphasis.directHover)
        case .contains: return tint.opacity(Tokens.Emphasis.containsHover)
        case .none: return .clear
        }
    }

    private func hover(_ inside: Bool) {
        if inside { state.hovered = node } else if state.hovered === node { state.hovered = nil }
    }

    /// Click model: a folder opens in place (same as clicking it in the chart); anything
    /// else becomes the selection. ↑/↓ select folders too, and zooming back out selects
    /// the folder you came from.
    private func tap() {
        if isZoomable { state.zoom(into: node) } else { state.selected = node }
    }
}

/// Real items drag their path (onto the Crate or other apps); synthetic rows don't drag.
private struct NodeDrag: ViewModifier {
    let node: FileNode

    func body(content: Content) -> some View {
        if node.isSynthetic {
            content
        } else {
            content.draggable(node.path) { preview }
        }
    }

    private var preview: some View {
        HStack(spacing: Tokens.Space.s) {
            FileIconView(path: node.path, isDirectory: node.isDirectory)
            Text(node.name).lineLimit(1)
            Text(ByteFormat.string(node.size)).foregroundStyle(Tokens.Colors.textSecondary)
        }
        .padding(.horizontal, Tokens.Space.m)
        .padding(.vertical, Tokens.Space.s)
        .background(.regularMaterial, in: Capsule())
    }
}

/// VoiceOver for a row: one element, the same actions as the context menu.
private struct NodeRowAccessibility: ViewModifier {
    let node: FileNode
    let fraction: Double
    let isZoomable: Bool
    let isSelected: Bool
    let isInCrate: Bool
    let protection: String?
    let state: AppState

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue("\(Int((fraction * 100).rounded())) percent of this folder")
            .accessibilityAddTraits(traits)
            .accessibilityActions { actions }
    }

    private var label: String {
        var parts = [node.name, ByteFormat.string(node.size)]
        if let explanation = node.kind.explanation { parts.append(explanation) }
        if protection != nil { parts.append("protected") }
        if isInCrate { parts.append("in \(Brand.crate)") }
        return parts.joined(separator: ", ")
    }

    private var traits: AccessibilityTraits {
        var traits: AccessibilityTraits = isZoomable ? .isButton : []
        if isSelected { traits.formUnion(.isSelected) }
        return traits
    }

    @ViewBuilder private var actions: some View {
        if isZoomable {
            Button("Open Folder") { state.zoom(into: node) }
        }
        if !node.isSynthetic {
            if !isZoomable { Button("Open") { state.open(node) } }
            Button("Quick Look") { QuickLookController.shared.preview(node) }
            Button("Show in Finder") { state.revealInFinder(node) }
            if state.canCollect(node), !isInCrate {
                Button("Add to \(Brand.crate)") { state.collect(node) }
            }
        }
    }
}

/// Context menu for a row.
struct NodeMenu: View {
    let node: FileNode
    let state: AppState

    var body: some View {
        if node.isDirectory, !node.isPackage || !node.children.isEmpty {
            Button("Open Folder Here") { state.zoom(into: node) }
            Divider()
        }
        if node.isSynthetic {
            // Not a file: nothing to preview, reveal, open or clear out.
            Text(node.kind.explanation ?? "Not a file")
        } else {
            fileActions
        }
    }

    @ViewBuilder private var fileActions: some View {
        Button("Quick Look") { QuickLookController.shared.preview(node) }
        Button("Show in Finder") { state.revealInFinder(node) }
        Button(node.isDirectory && !node.isPackage ? "Open in Finder" : "Open") { state.open(node) }
        Divider()
        crateActions
        Divider()
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(node.path, forType: .string)
        }
    }

    /// Protected items keep a disabled "Add to Crate" with the reason right under it.
    @ViewBuilder private var crateActions: some View {
        if state.collected.contains(where: { $0 === node }) {
            Button("Take Out of \(Brand.crate)") { state.uncollect(node) }
        } else if let reason = state.collectBlockReason(node) {
            Button("Add to \(Brand.crate)") {}
                .disabled(true)
            Text(reason)
        } else {
            Button("Add to \(Brand.crate)") { state.collect(node) }
                .disabled(state.isCollected(node))
        }
    }
}

private struct EverythingElseRow: View {
    let count: Int
    let size: Int64

    var body: some View {
        HStack(spacing: Tokens.Space.m - Tokens.Space.xxs) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 14))
                .foregroundStyle(Tokens.Colors.textSecondary)
                .frame(width: Tokens.Size.rowIcon)
            VStack(alignment: .leading, spacing: 0) {
                Text("Everything else")
                Text(Count.items(count))
                    .font(.caption)
                    .foregroundStyle(Tokens.Colors.textSecondary)
            }
            Spacer()
            Text(ByteFormat.string(size))
                .font(.system(.callout, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Tokens.Colors.textSecondary)
        }
        .padding(.horizontal, Tokens.Space.s + Tokens.Space.xxs)
        .padding(.vertical, Tokens.Space.s)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Hover support

/// Row colors for the current focus, computed once per folder (and per tree change)
/// instead of on every hover. `Palette` walks each row's siblings, so this matters for
/// big folders.
final class TintCache {
    private var key: (focus: ObjectIdentifier, version: Int, limit: Int)?
    private var colors: [ObjectIdentifier: Color] = [:]

    func colors(for focus: FileNode, limit: Int, version: Int) -> [ObjectIdentifier: Color] {
        let id = ObjectIdentifier(focus)
        if let key, key.focus == id, key.version == version, key.limit == limit { return colors }
        colors = NodeTint.colors(for: focus, limit: limit)
        key = (id, version, limit)
        return colors
    }
}

/// Which rows are on screen and whether the pointer is over the list — bookkeeping
/// for "scroll the row into view only if it's hidden".
@MainActor
final class RowReveal {
    var visible: Set<ObjectIdentifier> = []
    var pointerInList = false
    var pending: Task<Void, Never>?
}

/// Records whether a row is (almost) fully visible in the list's scroll view.
private struct TrackRowVisibility: ViewModifier {
    let id: ObjectIdentifier
    let reveal: RowReveal

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollVisibilityChange(threshold: 0.9) { isVisible in
                if isVisible { reveal.visible.insert(id) } else { reveal.visible.remove(id) }
            }
        } else {
            // Lazy stacks create rows a little beyond the viewport, so this over-reports
            // visibility slightly; the cost is a missed reveal, never a needless scroll.
            content
                .onAppear { reveal.visible.insert(id) }
                .onDisappear { reveal.visible.remove(id) }
        }
    }
}
