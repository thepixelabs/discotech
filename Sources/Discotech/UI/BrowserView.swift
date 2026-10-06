import SwiftUI

/// Phase `.browsing`: sidebar list + Crate on the left, the canvas on the right.
struct BrowserView: View {
    @EnvironmentObject var state: AppState
    /// Calm, derived view of `state.hovered` shared by the hover card, path bar and sidebar.
    @StateObject private var hover = HoverModel()
    /// Width of the detail (canvas) column; the responsive rules key off it, not the
    /// window, because the sidebar is resizable.
    @State private var detailWidth: CGFloat = 1000
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let focus = state.focus
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: Tokens.Size.sidebarMin,
                                                ideal: Tokens.Size.sidebarIdeal,
                                                max: Tokens.Size.sidebarMax)
                .background(reduceTransparency ? Tokens.Colors.sidebar : .clear)
        } detail: {
            // The canvas stays inside the safe area (never under the toolbar or path
            // bar). It paints `chartSurface`, and so does everything around it — no seam
            // between toolbar, path bar and canvas.
            //
            // A Findings card's "View items" swaps the canvas for that finding's files
            // view. The canvas is removed from the hierarchy meanwhile (no hidden work);
            // focus, selection and zoom live in `AppState`, so it comes back as it was.
            Group {
                if let finding = state.detailFinding {
                    FindingDetailPane(finding: finding)
                        .id(finding.id)  // another finding swaps the content
                } else {
                    ChartStage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .top, spacing: 0) {
                if state.detailFinding == nil {
                    PathBar(width: detailWidth).padding(.bottom, Tokens.Space.xs)
                }
            }
            .background(Tokens.Colors.chartSurface.ignoresSafeArea())
            .readSize { detailWidth = $0.width }
            .hidingToolbarBackground()
        }
        // Switching the canvas mode is a request to see a chart.
        .onChange(of: state.canvasMode) { _, _ in state.closeFindingDetail() }
        .environmentObject(hover)
        .onAppear { hover.attach(to: state) }
        .navigationTitle(focus.map(CrumbName.of) ?? Brand.name)
        .navigationSubtitle(focus.map { "\(ByteFormat.string($0.size)) · \(Count.files($0.fileCount))" } ?? "")
        .toolbar {
            // Keyboard shortcuts for these live in the View menu (DiscotechApp).
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    state.zoomOut()
                } label: {
                    Label("Enclosing Folder", systemImage: "chevron.left")
                }
                .disabled(focus?.parent == nil)
                .help("Enclosing folder (⌘↑ or ⌫)")
            }
            ToolbarItem(placement: .principal) {
                CanvasModePicker(showsLabels: detailWidth >= Tokens.Breakpoint.pickerLabels)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    state.rescan()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .help("Scan again (⌘R)")

                Button {
                    state.backToStart()
                } label: {
                    Label("All Drives", systemImage: "internaldrive")
                }
                .help("Back to all drives (⇧⌘D)")

                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Settings (⌘,)")

                HelpButton()
            }
        }
        .background {
            // Backspace also goes up a level.
            Button("Enclosing Folder") { state.zoomOut() }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(state.detailFinding != nil)  // nothing to zoom while the files view is up
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            // Space = Quick Look, from the sidebar or the chart.
            WindowReader { window in QuickLookController.shared.install(in: window, state: state) }
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .onDisappear { QuickLookController.shared.uninstall() }
    }
}

// MARK: - Path bar

/// Floating glass capsule of breadcrumbs, with the partial-scan status beside it.
///
/// While something is hovered, faded preview crumbs trail the real ones with the rest
/// of its path below the focus. They're the same height as real crumbs, so the bar
/// only ever grows sideways and nothing below it moves.
///
/// When the row gets tight, in this order: preview crumbs go, then the middle of the
/// real path collapses into a "…" menu (first + last two stay), then only the current
/// folder remains. The status item is fixed-size and never gives way to the crumbs.
struct PathBar: View {
    /// Detail column width (drives the status item's icon-only form).
    let width: CGFloat
    @EnvironmentObject var state: AppState
    @EnvironmentObject private var hover: HoverModel

    var body: some View {
        let crumbs = state.focus?.ancestry ?? []
        let ghosts = hover.info?.lineage ?? []
        HStack(spacing: Tokens.Space.m) {
            ViewThatFits(in: .horizontal) {
                trail(crumbs, collapsed: false, ghosts: ghosts)
                trail(crumbs, collapsed: false, ghosts: [])
                trail(crumbs, collapsed: true, ghosts: ghosts)
                trail(crumbs, collapsed: true, ghosts: [])
                trail(Array(crumbs.suffix(1)), collapsed: false, ghosts: [])
            }
            .glassSurface(Capsule())
            .frame(maxWidth: .infinity, alignment: .leading)

            // What the colours mean (Settings → Colour by); the crumbs keep most of the row.
            if width >= ColorLegend.minWidth {
                ColorLegend()
                    .frame(maxWidth: min(width * 0.46, 560), alignment: .trailing)
                    .layoutPriority(1)
            }

            if state.isPartialScan {
                PartialScanStatus(iconOnly: width < Tokens.Breakpoint.statusText)
                    .fixedSize()
                    .layoutPriority(2)
            }
        }
        .padding(.horizontal, Tokens.Space.l)
        .padding(.top, Tokens.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Path")
    }

    /// One candidate layout for the bar. Collapsing keeps the first crumb and the last
    /// two, with the rest behind a "…" menu.
    private func trail(_ crumbs: [FileNode], collapsed: Bool, ghosts: [HoverInfo.Step]) -> some View {
        let hidden: [FileNode] = collapsed && crumbs.count > 3 ? Array(crumbs[1..<(crumbs.count - 2)]) : []
        let shown: [FileNode] = hidden.isEmpty ? crumbs : [crumbs[0]] + crumbs.suffix(2)
        let current = crumbs.last
        return HStack(spacing: Tokens.Space.xxs) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, node in
                if index > 0 { CrumbChevron() }
                Crumb(node: node, isCurrent: node === current) { state.zoom(into: node) }
                if index == 0, !hidden.isEmpty {
                    CrumbChevron()
                    CollapsedCrumbs(nodes: hidden) { state.zoom(into: $0) }
                }
            }
            ForEach(ghosts) { step in
                CrumbChevron()
                    .opacity(Tokens.Emphasis.ghost)
                GhostCrumb(step: step)
            }
        }
        .padding(.horizontal, Tokens.Space.xs)
        .padding(.vertical, Tokens.Space.xs)
        .fixedSize()
    }
}

/// The middle of a long path, behind a "…" menu.
private struct CollapsedCrumbs: View {
    let nodes: [FileNode]
    let open: (FileNode) -> Void

    var body: some View {
        Menu {
            ForEach(nodes) { node in
                Button(CrumbName.of(node)) { open(node) }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.callout)
                .foregroundStyle(Tokens.Colors.textSecondary)
                .padding(.horizontal, Tokens.Space.s)
                .padding(.vertical, Tokens.Space.xs)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(nodes.map(CrumbName.of).joined(separator: " › "))
        .accessibilityLabel("\(nodes.count) more folders")
    }
}

private struct CrumbChevron: View {
    var body: some View {
        Image(systemName: "chevron.compact.right")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}

/// A preview of where a click would lead: faded, italic, underlined in its chart color,
/// and inert (the chart segment under the pointer is what you click).
private struct GhostCrumb: View {
    let step: HoverInfo.Step

    var body: some View {
        HStack(spacing: Tokens.Space.xs) {
            NodeIcon(node: step.node, size: Tokens.Size.crumbIcon)
            Text(step.node.name)
                .font(.callout.italic())
                .foregroundStyle(Tokens.Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: Tokens.Size.ghostCrumbMaxWidth, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, Tokens.Space.s)
        .padding(.vertical, Tokens.Space.xs)
        .overlay(alignment: .bottom) {
            Capsule()
                .fill(step.tint)
                .frame(height: 2)
                .padding(.horizontal, Tokens.Space.s)
        }
        .opacity(Tokens.Emphasis.ghost)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Shown after "Stop and Show Results": totals only cover what was measured. A fixed-
/// size status item outside the path capsule, so it can never be squeezed; in a narrow
/// canvas it shows its icon only (the tooltip and VoiceOver label keep the words).
private struct PartialScanStatus: View {
    let iconOnly: Bool
    @EnvironmentObject var state: AppState

    var body: some View {
        Button { state.rescan() } label: {
            HStack(spacing: Tokens.Space.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                if !iconOnly {
                    Text("Partial scan")
                    Text("·").foregroundStyle(Tokens.Colors.textTertiary)
                    Text("Rescan").underline()
                }
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(Tokens.Colors.warning)
            .lineLimit(1)
            .padding(.vertical, Tokens.Space.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("This scan was stopped early, so sizes are incomplete. Click to scan again.")
        .accessibilityLabel("Partial scan. Rescan")
    }
}

private struct Crumb: View {
    let node: FileNode
    let isCurrent: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button {
            if !isCurrent { action() }
        } label: {
            HStack(spacing: Tokens.Space.xs) {
                FileIconView(path: node.path, isDirectory: true, size: Tokens.Size.crumbIcon)
                Text(CrumbName.of(node))
                    .font(.callout.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Tokens.Colors.textPrimary : Tokens.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: Tokens.Size.crumbMaxWidth, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, Tokens.Space.s)
            .padding(.vertical, Tokens.Space.xs)
            .background(hovering && !isCurrent ? Tokens.Colors.hoverFill : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(node.path)
        .accessibilityLabel(node.name)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}


/// Ball / Layers / Floor switch (⌘1–⌘3, in the View menu). Icons only when the canvas
/// is narrow; the tooltip and VoiceOver keep the names.
private struct CanvasModePicker: View {
    let showsLabels: Bool
    @EnvironmentObject var state: AppState

    var body: some View {
        Picker("View", selection: $state.canvasMode) {
            ForEach(AppState.CanvasMode.allCases) { mode in
                Label(mode.title, systemImage: mode.symbol)
                    .help(mode.title)
                    .accessibilityLabel(mode.title)
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelStyle(showsLabels ? AnyLabelStyle(.titleAndIcon) : AnyLabelStyle(.iconOnly))
        .fixedSize()
        .help("Choose how to show the disk (⌘1–⌘3)")
    }
}

/// Type-erased label style, so the picker can switch between icon-only and titled.
private struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView
    init<S: LabelStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
