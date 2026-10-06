import SwiftUI

extension FileNode {
    /// Children for an outline (Finder-style list): nil for files, empty folders and
    /// synthetic accounting nodes, so they get no disclosure triangle. Already sorted by
    /// size, largest first; returns the stored array, so asking is free.
    var outlineChildren: [FileNode]? {
        guard isDirectory, !isSynthetic, !children.isEmpty else { return nil }
        return children
    }
}

/// What "View items" on a Findings card shows in place of the canvas: a Finder-style list
/// of the finding's items, or of every file in the scan. Nothing here deletes anything;
/// the only writes are `state.collect`, which applies the Crate's safety rules, and
/// `state.uncollect`, which only takes things back out of the Crate.
struct FindingDetailPane: View {
    let finding: Finding
    @EnvironmentObject var state: AppState
    @State private var scope: Scope = {
        #if DEBUG
        return DebugHooks.detailScopeAll ? .all : .finding
        #else
        return .finding
        #endif
    }()
    /// The rows selected in whichever table is showing (⌘-click, ⇧-click, ⌘A).
    @State private var picked: [FileNode] = []

    enum Scope: String, CaseIterable, Identifiable {
        case finding = "This finding"
        case all = "All files"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, Tokens.Space.l)
                .padding(.top, Tokens.Space.s)
            controls
                .padding(.horizontal, Tokens.Space.l)
                .padding(.vertical, Tokens.Space.m)
            Divider()
            switch scope {
            case .finding: FindingItemsTable(finding: finding, picked: $picked)
            case .all:
                if let root = state.root { AllFilesOutline(root: root, state: state, picked: $picked) }
            }
        }
        .onChange(of: scope) { _, _ in picked = [] }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(finding.title), items")
        #if DEBUG
        .onChange(of: picked) { _, nodes in DebugHooks.pickedCount = nodes.count }
        .onAppear { if DebugHooks.selectionTestSpec != nil { DebugHooks.runSelectionTest(state, finding: finding) } }
        #endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.m) {
            Button {
                state.closeFindingDetail()
            } label: {
                Label("Back to chart", systemImage: "chevron.left")
                    .lineLimit(1)
            }
            .buttonStyle(.studioText)
            .keyboardShortcut(.cancelAction)
            .help("Back to the chart (Esc)")
            HStack(alignment: .center, spacing: Tokens.Space.s + Tokens.Space.xxs) {
                IconBadge(systemImage: finding.icon, hue: finding.hue)
                VStack(alignment: .leading, spacing: 1) {
                    Text(finding.title)
                        .font(Tokens.Typeface.cardTitle)
                        .foregroundStyle(Tokens.Colors.textPrimary)
                        .lineLimit(2)
                    summary
                }
                Spacer(minLength: Tokens.Space.m)
                crateAll
            }
        }
    }

    /// "14 projects · 3.8 MB", and once rows are selected "· 3 selected, 1.1 MB".
    private var summary: some View {
        var line = Text("\(finding.countLabel) · \(ByteFormat.string(finding.totalSize))")
            .foregroundStyle(Tokens.Colors.textSecondary)
        if !picked.isEmpty {
            line = line + Text(" · \(Count.string(picked.count)) selected, \(ByteFormat.string(pickedSize))")
                .foregroundStyle(Tokens.Colors.accentText)
        }
        return line
            .font(.caption)
            .lineLimit(1)
    }

    /// Bytes in the selected rows. A row inside a selected folder (All files) is already
    /// counted in that folder, so it isn't added again.
    private var pickedSize: Int64 {
        let ids = Set(picked.map(ObjectIdentifier.init))
        return picked.reduce(0) { sum, node in
            guard !node.isSynthetic else { return sum }
            var ancestor = node.parent
            while let cur = ancestor {
                if ids.contains(ObjectIdentifier(cur)) { return sum }
                ancestor = cur.parent
            }
            return sum + node.size
        }
    }

    private var controls: some View {
        let plan = CratePlan(picked, state: state)
        return HStack(spacing: Tokens.Space.m) {
            Picker("Show", selection: $scope) {
                ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
            Spacer(minLength: Tokens.Space.m)
            // A narrow window drops "Show on chart" to its icon before anything wraps.
            ViewThatFits(in: .horizontal) {
                selectionActions(plan, compact: false)
                selectionActions(plan, compact: true)
            }
        }
    }

    private func selectionActions(_ plan: CratePlan, compact: Bool) -> some View {
        HStack(spacing: Tokens.Space.m) {
            Button {
                if picked.count == 1, let node = picked.first { RowActions.showOnChart(node, state) }
            } label: {
                Label("Show on chart", systemImage: "scope")
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                    .modifier(IconOnly(enabled: compact))
            }
            .buttonStyle(.studioText)
            .disabled(picked.count != 1)
            .help("Close this list and find the selected item on the chart")
            if showsCrateActions {
                Button {
                    plan.addable.forEach(state.collect)
                } label: {
                    Label(plan.addable.isEmpty ? "Add to \(Brand.crate)" : "Add \(Count.string(plan.addable.count)) to \(Brand.crate)",
                          systemImage: "plus")
                        .lineLimit(1)
                }
                .buttonStyle(.studio(.secondary))
                .disabled(plan.addable.isEmpty)
                .help(plan.addHelp)
                .testTarget("add")
                if plan.hasCrateItems {
                    Button {
                        plan.removable.forEach(state.uncollect)
                    } label: {
                        Label(plan.takeOutTitle, systemImage: "minus")
                            .lineLimit(1)
                    }
                    .buttonStyle(.studio(.secondary))
                    .disabled(plan.removable.isEmpty)
                    .help(plan.takeOutHelp)
                    .testTarget("takeOut")
                }
            }
        }
        .fixedSize()
    }

    /// The finding's own rows can go in the Crate. Not for a finding shown only so its
    /// space is visible (the Trash's contents); "All files" lists any file, so it keeps them.
    private var showsCrateActions: Bool { finding.isCollectible || scope == .all }

    /// "Add all to Crate"; once everything is in, "All in Crate" and "Take all out".
    @ViewBuilder private var crateAll: some View {
        if !finding.isCollectible {
            Text("Already in the Trash. Empty it in Finder.")
                .font(.caption)
                .foregroundStyle(Tokens.Colors.textSecondary)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 220, alignment: .trailing)
                .fixedSize(horizontal: false, vertical: true)
                .help("Items already in the Trash can’t go in the \(Brand.crate). Empty the Trash in Finder to free this space.")
        } else if finding.nodes.allSatisfy(state.isCollected) {
            let plan = CratePlan(finding.nodes, state: state)
            HStack(spacing: Tokens.Space.m) {
                Label("All in \(Brand.crate)", systemImage: "checkmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Tokens.Colors.positive)
                    .lineLimit(1)
                Button {
                    plan.removable.forEach(state.uncollect)
                } label: {
                    Label("Take all out", systemImage: "minus")
                        .lineLimit(1)
                }
                .buttonStyle(.studio(.secondary))
                .disabled(plan.removable.isEmpty)
                .help(plan.takeOutHelp)
                .testTarget("takeAllOut")
            }
            .fixedSize()
        } else {
            Button {
                finding.nodes.forEach(state.collect)
            } label: {
                Label("Add all to \(Brand.crate)", systemImage: "plus")
                    .lineLimit(1)
            }
            .buttonStyle(.studio(.secondary))
            .testTarget("addAll")
        }
    }
}

extension View {
    /// Selection test only (DEBUG with DISCOTECH_TEST_SELECT set): remembers where this
    /// control is, so a `b=name` step can click it with a real mouse event. Anywhere
    /// else it returns the view untouched.
    @ViewBuilder fileprivate func testTarget(_ name: String) -> some View {
        #if DEBUG
        if DebugHooks.selectionTestSpec != nil {
            background(DebugHooks.TargetMarker(name: name))
        } else {
            self
        }
        #else
        self
        #endif
    }
}

/// Hides a label's title (keeping it for VoiceOver and the tooltip) when `enabled`.
private struct IconOnly: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.labelStyle(.iconOnly) } else { content }
    }
}

// MARK: - Shared row behaviour

/// What a set of rows can do with the Crate. A row inside a folder that is in the Crate
/// is in it too, but only comes out with that folder: those are kept apart in
/// `viaFolder` so labels can say so, instead of offering a button that does nothing.
@MainActor
private struct CratePlan {
    /// Not in the Crate yet, and allowed in.
    private(set) var addable: [FileNode] = []
    /// In the Crate themselves; `uncollect` takes them out.
    private(set) var removable: [FileNode] = []
    /// In the Crate only because a folder holding them is.
    private(set) var viaFolder: [FileNode] = []
    /// Not in the Crate and not allowed in (protected).
    private(set) var blocked = 0
    /// The Crate folder holding the first of `viaFolder`, for the wording.
    private(set) var holder: FileNode?

    init(_ nodes: [FileNode], state: AppState) {
        let inCrate = Set(state.collected.map(ObjectIdentifier.init))
        for node in nodes where !node.isSynthetic {
            if inCrate.contains(ObjectIdentifier(node)) {
                removable.append(node)
            } else if let folder = Self.crateFolder(holding: node, in: inCrate) {
                viaFolder.append(node)
                if holder == nil { holder = folder }
            } else if state.canCollect(node) {
                addable.append(node)
            } else {
                blocked += 1
            }
        }
    }

    /// The nearest ancestor of `node` that is itself in the Crate.
    private static func crateFolder(holding node: FileNode, in inCrate: Set<ObjectIdentifier>) -> FileNode? {
        var ancestor = node.parent
        while let cur = ancestor {
            if inCrate.contains(ObjectIdentifier(cur)) { return cur }
            ancestor = cur.parent
        }
        return nil
    }

    static func holder(of node: FileNode, in state: AppState) -> FileNode? {
        crateFolder(holding: node, in: Set(state.collected.map(ObjectIdentifier.init)))
    }

    var hasCrateItems: Bool { !removable.isEmpty || !viaFolder.isEmpty }

    var addHelp: String {
        var text = "Add the selected items to the \(Brand.crate). Nothing is deleted. "
            + "⌘-click picks several, ⇧-click a range, ⌘A everything."
        if blocked > 0 { text += " \(Count.items(blocked)) can’t go in the \(Brand.crate)." }
        return text
    }

    /// "Take 3 out of Crate", or, when every selected item is only in through its
    /// folder, a disabled "In Crate with its folder".
    var takeOutTitle: String {
        if !removable.isEmpty { return "Take \(Count.string(removable.count)) out of \(Brand.crate)" }
        return viaFolder.count == 1 ? "In \(Brand.crate) with its folder" : "In \(Brand.crate) with their folder"
    }

    var takeOutHelp: String {
        var text = removable.isEmpty ? "" : "Take \(Count.items(removable.count)) out of the \(Brand.crate). Nothing is deleted."
        if let holder, !viaFolder.isEmpty {
            let what = viaFolder.count == 1 ? "1 item is" : "\(Count.string(viaFolder.count)) items are"
            text += (text.isEmpty ? "" : " ")
                + "\(what) in the \(Brand.crate) because the folder “\(holder.name)” is. Take that folder out of the \(Brand.crate) to keep \(viaFolder.count == 1 ? "it" : "them")."
        }
        return text
    }
}

/// What picking and right-clicking a row does, for both tables.
@MainActor
private enum RowActions {
    /// Closes the list, zooms the canvas to the item's folder and selects it there.
    /// Synthetic accounting nodes have no place on the chart to go to.
    static func showOnChart(_ node: FileNode, _ state: AppState) {
        guard !node.isSynthetic, let parent = node.parent else { return }
        state.closeFindingDetail()
        state.zoom(into: parent)
        state.selected = node
        // The sidebar re-selects the folder you just left when the zoom lands on its
        // parent; put the pick back once that has run.
        DispatchQueue.main.async {
            if state.focus === parent { state.selected = node }
        }
    }

    /// One Finder window with every item selected (Return, double-click, the menu),
    /// rather than one reveal per row.
    static func reveal(_ nodes: [FileNode]) {
        let urls = nodes.filter { !$0.isSynthetic }.map(\.url)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// What VoiceOver calls a row. A finding's rows often share a name ("node_modules"),
    /// so the folder it sits in is part of it.
    static func spokenName(_ node: FileNode) -> String {
        guard let parent = node.parent, parent.parent != nil else { return node.name }
        return "\(node.name) in \(parent.name)"
    }
}

private struct RowMenu: View {
    let nodes: [FileNode]
    let state: AppState

    var body: some View {
        let real = nodes.filter { !$0.isSynthetic }
        if !real.isEmpty {
            let plan = CratePlan(real, state: state)
            let several = real.count > 1
            Button(several && !plan.addable.isEmpty ? "Add \(Count.string(plan.addable.count)) to \(Brand.crate)"
                                                    : "Add to \(Brand.crate)") {
                plan.addable.forEach(state.collect)
            }
            .disabled(plan.addable.isEmpty)
            if plan.addable.isEmpty, plan.removable.isEmpty, plan.viaFolder.isEmpty, let first = real.first {
                // Nothing here may go in (protected, or already in the Trash): say why, as
                // the sidebar menu does, rather than a disabled item with no reason.
                Text(real.count == 1 ? state.collectBlockReason(first) ?? "Can’t go in the \(Brand.crate)"
                                     : "These can’t go in the \(Brand.crate)")
            }
            if !plan.removable.isEmpty {
                Button(several ? "Take \(Count.string(plan.removable.count)) Out of \(Brand.crate)"
                               : "Take Out of \(Brand.crate)") {
                    plan.removable.forEach(state.uncollect)
                }
            }
            if !plan.viaFolder.isEmpty, let holder = plan.holder {
                // Same pattern as the sidebar menu: the reason sits under a disabled item.
                if plan.removable.isEmpty {
                    Button("Take Out of \(Brand.crate)") {}
                        .disabled(true)
                }
                Text("In the \(Brand.crate) with “\(holder.name)”; take that folder out instead")
            }
            Divider()
            if real.count == 1, let node = real.first {
                Button("Show on Chart") { RowActions.showOnChart(node, state) }
                    .disabled(node.parent == nil)
            }
            Button("Show in Finder") { RowActions.reveal(real) }
            if real.count == 1, let node = real.first {
                Button("Quick Look") { QuickLookController.shared.preview(node) }
            }
        }
    }
}

private struct NameCell: View {
    let node: FileNode

    var body: some View {
        HStack(spacing: Tokens.Space.s) {
            NodeIcon(node: node, size: 16)
            Text(node.parent == nil ? CrumbName.of(node) : node.name)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .help(node.isSynthetic ? node.name : node.path)
    }
}

private struct SizeCell: View {
    let node: FileNode

    var body: some View {
        Text(ByteFormat.string(node.size))
            .font(.system(.callout, design: .rounded))
            .monospacedDigit()
            .modifier(RowInk(color: Tokens.Colors.textSecondary))
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// Colour for secondary text and icons in a table row that stays readable when the row
/// is selected: on the selection fill the token colour gives way to white.
private struct RowInk: ViewModifier {
    let color: Color
    @Environment(\.backgroundProminence) private var prominence

    func body(content: Content) -> some View {
        content.foregroundStyle(prominence == .increased ? Color.white.opacity(0.85) : color)
    }
}

/// "In the Crate, click to take it out": the Crate's box with a minus badge, the
/// counterpart of the plus that puts a row in.
private struct TakeOutIcon: View {
    var body: some View {
        Image(systemName: "archivebox.fill")
            .modifier(RowInk(color: Tokens.Colors.textSecondary))
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 8, weight: .bold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Tokens.Colors.accent)
                    .offset(x: 4, y: 3)
            }
    }
}

// MARK: - This finding

private struct FindingItemsTable: View {
    let finding: Finding
    @Binding var picked: [FileNode]
    @EnvironmentObject var state: AppState
    @State private var sortOrder = [KeyPathComparator(\FileNode.size, order: .reverse)]
    @State private var selection = Set<FileNode.ID>()
    /// The list takes the keyboard when it appears, so ⌘A and the arrow keys work
    /// without clicking into it first.
    @FocusState private var focused: Bool

    var body: some View {
        let _ = state.treeVersion  // items trashed elsewhere drop out
        let rows = finding.nodes.filter { $0.parent != nil }.sorted(using: sortOrder)
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { node in
                NameCell(node: node)
            }
            .width(min: 90, ideal: 130)
            TableColumn("Where") { node in
                Text(node.parent?.path ?? "")
                    .font(.callout)
                    .modifier(RowInk(color: Tokens.Colors.textSecondary))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(node.parent?.path ?? "")
            }
            .width(min: 60, ideal: 100)
            TableColumn("Size", value: \.size) { node in
                SizeCell(node: node)
            }
            .width(min: 76, ideal: 84, max: 120)
            TableColumn("") { node in
                crateMark(node)
            }
            .width(24)
        }
        .scrollContentBackground(.hidden)
        .focused($focused)
        .onAppear { focused = true }
        .contextMenu(forSelectionType: FileNode.ID.self) { ids in
            RowMenu(nodes: rows.filter { ids.contains($0.id) }, state: state)
        } primaryAction: { ids in
            RowActions.reveal(rows.filter { ids.contains($0.id) })
        }
        .onChange(of: selection) { _, ids in
            picked = rows.filter { ids.contains($0.id) }
        }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView("Nothing left here", systemImage: "checkmark.circle")
            }
        }
    }

    /// One click puts the row in the Crate or takes it back out. A row that is only in
    /// through a folder in the Crate can't come out alone, so it shows a plain box.
    @ViewBuilder private func crateMark(_ node: FileNode) -> some View {
        let name = RowActions.spokenName(node)
        if state.collected.contains(where: { $0 === node }) {
            Button {
                state.uncollect(node)
            } label: {
                TakeOutIcon()
            }
            .buttonStyle(.borderless)
            .help("In the \(Brand.crate). Click to take it out (nothing is deleted).")
            .accessibilityLabel("Take \(name) out of the \(Brand.crate)")
        } else if let holder = CratePlan.holder(of: node, in: state) {
            Image(systemName: "archivebox.fill")
                .modifier(RowInk(color: Tokens.Colors.textTertiary))
                .help("In the \(Brand.crate) with the folder “\(holder.name)”. Take that folder out to keep this.")
                .accessibilityLabel("\(name) is in the \(Brand.crate) with the folder \(holder.name)")
        } else if state.canCollect(node) {
            Button {
                state.collect(node)
            } label: {
                Image(systemName: "plus.circle")
                    .modifier(RowInk(color: Tokens.Colors.accentText))
            }
            .buttonStyle(.borderless)
            .help("Add to \(Brand.crate)")
            .accessibilityLabel("Add \(name) to the \(Brand.crate)")
        }
    }
}

// MARK: - All files

/// The whole scanned tree as a Finder-style list. Folders open on demand: the outline
/// only ever asks for the children of rows you expand, so a 100k-node tree costs nothing
/// until you dig into it. Holds `state` as a plain reference (not observed) so hovering
/// the chart doesn't rebuild thousands of rows.
private struct AllFilesOutline: View {
    let root: FileNode
    let state: AppState
    @Binding var picked: [FileNode]
    @State private var selection = Set<FileNode.ID>()
    /// Rows the table has shown, so a selection id can be turned back into its node
    /// without walking the tree. Filled as rows appear; never persisted.
    @State private var seen = SeenNodes()
    /// See `FindingItemsTable.focused`.
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Table(root.children, children: \.outlineChildren, selection: $selection) {
                TableColumn("Name") { node in
                    NameCell(node: node)
                        .onAppear { seen.map[node.id] = node }
                }
                .width(min: 120, ideal: 220)
                TableColumn("Size") { node in
                    SizeCell(node: node)
                }
                .width(min: 76, ideal: 84, max: 120)
            }
            .scrollContentBackground(.hidden)
            .focused($focused)
            .onAppear { focused = true }
            .contextMenu(forSelectionType: FileNode.ID.self) { ids in
                RowMenu(nodes: seen.nodes(for: ids, under: root), state: state)
            } primaryAction: { ids in
                RowActions.reveal(seen.nodes(for: ids, under: root))
            }
            .onChange(of: selection) { _, ids in
                picked = seen.nodes(for: ids, under: root)
            }
            Divider()
            Text(CrumbName.of(root))
                .font(.caption)
                .foregroundStyle(Tokens.Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.head)
                .padding(.horizontal, Tokens.Space.m)
                .padding(.vertical, Tokens.Space.xs + 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(root.path)
        }
        .id(ObjectIdentifier(root))
    }

    final class SeenNodes {
        var map: [FileNode.ID: FileNode] = [:]
        /// Ids a walk has already failed to find (a row trashed meanwhile), so they
        /// don't cost another walk on every selection change.
        private var gone = Set<FileNode.ID>()

        /// The nodes for `ids`. ⌘A and ⇧-click ranges select rows that were never drawn
        /// (so never `seen`); those are found with one walk of the tree that stops as
        /// soon as every one has turned up.
        func nodes(for ids: Set<FileNode.ID>, under root: FileNode) -> [FileNode] {
            var missing = ids.filter { map[$0] == nil && !gone.contains($0) }
            if !missing.isEmpty {
                var stack = root.children
                while !missing.isEmpty, let node = stack.popLast() {
                    if missing.remove(node.id) != nil { map[node.id] = node }
                    if let children = node.outlineChildren { stack.append(contentsOf: children) }
                }
                gone.formUnion(missing)
            }
            return ids.compactMap { map[$0] }
        }
    }
}
