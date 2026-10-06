#if DEBUG
import AppKit

/// Layers' DEBUG-only state (one stored property on `ColumnsNSView`), reset on a focus change.
struct ColumnsDebugState {
    var hoverDone = false
    var clickDone = false
    var emphasizeDone = false
    var selectDone = false
}

/// Screenshot-only hooks (never compiled into a release build).
extension ColumnsNSView {
    /// DISCOTECH_LAYERS_HOVER=1   hover the largest band one column in (lineage + card)
    /// DISCOTECH_LAYERS_CLICK=1   click the largest zoomable band in column 0 (zoom transition)
    /// DISCOTECH_LAYERS_EMPHASIZE=name   emphasize every node with that name, as a Findings card would
    /// DISCOTECH_LAYERS_SELECT=1   select the 2nd-largest band in column 0 directly (CanvasHighlight's selected ring)
    func runDebugHooks() {
        guard let layout, !layout.isEmpty else { return }
        let env = ProcessInfo.processInfo.environment
        func center(of band: LayerBand, column: Int) -> CGPoint {
            CGPoint(x: columnX(column) + columnWidths[column] / 2, y: ColumnsConstants.headerHeight + band.y + band.height / 2)
        }
        if !debug.clickDone, env["DISCOTECH_LAYERS_CLICK"] != nil, !layout.columns.isEmpty {
            debug.clickDone = true
            let bands = layout.columns[0].bands
            if let i = bands.indices.filter({ bands[$0].node?.isDirectory == true && !bands[$0].isBucket })
                .max(by: { bands[$0].size < bands[$1].size }) {
                let p = center(of: bands[i], column: 0)
                FileHandle.standardError.write(Data("layers click: \(bands[i].node?.path ?? "?")\n".utf8))
                DispatchQueue.main.async { self.performClick(at: p) }
            }
            return
        }
        if !debug.emphasizeDone, let name = env["DISCOTECH_LAYERS_EMPHASIZE"] {
            debug.emphasizeDone = true
            var found: [FileNode] = []
            var stack = [layout.focus]
            while let node = stack.popLast() {
                if node.name == name { found.append(node); continue }
                stack.append(contentsOf: node.children)
            }
            FileHandle.standardError.write(Data("layers emphasize: \(found.count) × \(name)\n".utf8))
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.appState?.emphasize(found) }
        }
        if !debug.hoverDone, env["DISCOTECH_LAYERS_HOVER"] != nil, layout.columns.count > 1 {
            debug.hoverDone = true
            let bands = layout.columns[1].bands
            if let i = bands.indices.filter({ !bands[$0].isBucket }).max(by: { bands[$0].size < bands[$1].size }) {
                let p = center(of: bands[i], column: 1)
                FileHandle.standardError.write(Data("layers hover: \(bands[i].node?.name ?? "?")\n".utf8))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.performHover(at: p) }
            }
        }
        if !debug.selectDone, env["DISCOTECH_LAYERS_SELECT"] != nil, !layout.columns.isEmpty {
            debug.selectDone = true
            let bands = layout.columns[0].bands
            let bySize = bands.indices.filter { !bands[$0].isBucket }.sorted { bands[$0].size > bands[$1].size }
            if bySize.count > 1, let node = bands[bySize[1]].node {
                FileHandle.standardError.write(Data("layers select: \(node.name)\n".utf8))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.appState?.selected = node }
            }
        }
    }
}
#endif
