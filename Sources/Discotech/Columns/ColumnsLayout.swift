import Foundation
import CoreGraphics

/// One drawn band inside a column: either a real child (or pass-through-resolved
/// descendant chain) of some ancestor band, or the merged "N smaller items" bucket for a
/// parent whose small children didn't clear `ColumnsConstants.mergeThreshold`.
struct LayerBand {
    /// `nil` for the merged bucket band.
    let node: FileNode?
    /// The folder whose small children this bucket merges. `nil` for a real band.
    let bucketParent: FileNode?
    let bucketCount: Int
    /// Single-dominant-child folders absorbed into this band's own label instead of each
    /// spending a column on a near-total sliver (`/Users` → `you`, `X.app` → `Contents`).
    /// Outermost first. Empty for most bands.
    let passThrough: [FileNode]
    let size: Int64
    /// Top offset within the column, in points, top-down (the view is flipped).
    let y: CGFloat
    let height: CGFloat

    var isBucket: Bool { node == nil }
    /// The node whose own children populate the *next* column for this band — `node`
    /// itself, or the last link of `passThrough` when this band absorbed a chain. `nil`
    /// for a bucket band, which is never split further.
    var childSource: FileNode? { passThrough.last ?? node }
}

/// One depth column's worth of bands. `depth` is a *visual* column index (0 = the focus's
/// direct children), not a literal tree depth — pass-through absorption can make a single
/// column represent several real tree levels at once.
struct LayerColumn {
    let depth: Int
    let bands: [LayerBand]
}

/// The whole Layers partition for one focus at one content height: every band, in every
/// visible column, positioned so a band's height is *exactly* proportional to its size
/// within the vertical span its parent band occupies — the "true macro picture" the Ball's
/// old Miller-columns replacement was missing. Rebuilt only when the focus, the tree, or
/// the view's content height actually changes; hover/emphasis only read it.
final class LayersLayout {
    let focus: FileNode
    let contentHeight: CGFloat
    let columns: [LayerColumn]

    var isEmpty: Bool { columns.isEmpty }

    private init(focus: FileNode, contentHeight: CGFloat, columns: [LayerColumn]) {
        self.focus = focus
        self.contentHeight = contentHeight
        self.columns = columns
    }

    // MARK: - Build

    static func build(focus: FileNode, contentHeight: CGFloat, maxColumns: Int) -> LayersLayout {
        guard contentHeight > 0, maxColumns > 0 else {
            return LayersLayout(focus: focus, contentHeight: contentHeight, columns: [])
        }
        struct Frontier { let parent: FileNode; let y: CGFloat; let height: CGFloat }
        var frontier = [Frontier(parent: focus, y: 0, height: contentHeight)]
        var columns: [LayerColumn] = []

        for depth in 0..<maxColumns {
            guard !frontier.isEmpty else { break }
            var bands: [LayerBand] = []
            for item in frontier {
                bands.append(contentsOf: buildBands(parent: item.parent, y: item.y, height: item.height))
            }
            guard !bands.isEmpty else { break }
            columns.append(LayerColumn(depth: depth, bands: bands))

            var next: [Frontier] = []
            for band in bands {
                guard let source = band.childSource, isSplittable(source) else { continue }
                next.append(Frontier(parent: source, y: band.y, height: band.height))
            }
            frontier = next
        }
        return LayersLayout(focus: focus, contentHeight: contentHeight, columns: columns)
    }

    /// Splits `parent`'s children across `[y, y + height)`, each band's height exactly
    /// `height × size / totalSize` — no floor. Children are sorted by size descending
    /// (`FileNode.finalize`), so once one child's proportional height falls under
    /// `mergeThreshold` every remaining sibling does too; that clean suffix becomes one
    /// "N smaller items" band, matching the Ball's "Everything else" bucket.
    private static func buildBands(parent: FileNode, y: CGFloat, height: CGFloat) -> [LayerBand] {
        guard height > 0 else { return [] }
        let real = parent.children.filter { $0.size > 0 }
        guard !real.isEmpty else { return [] }
        let total = real.reduce(Int64(0)) { $0 + $1.size }
        guard total > 0 else { return [] }

        var shownCount = real.count
        for (i, node) in real.enumerated() {
            let h = height * CGFloat(node.size) / CGFloat(total)
            if h < ColumnsConstants.mergeThreshold { shownCount = i; break }
        }
        let shown = real.prefix(shownCount)
        let tail = real.suffix(from: shownCount)

        var bands: [LayerBand] = []
        bands.reserveCapacity(shownCount + (tail.isEmpty ? 0 : 1))
        var cursor: CGFloat = 0
        for node in shown {
            let h = height * CGFloat(node.size) / CGFloat(total)
            let chain = resolvePassThrough(node)
            bands.append(LayerBand(node: node, bucketParent: nil, bucketCount: 0, passThrough: chain,
                                   size: node.size, y: y + cursor, height: h))
            cursor += h
        }
        if !tail.isEmpty {
            let tailSize = tail.reduce(Int64(0)) { $0 + $1.size }
            // Absorb whatever's left (including float drift) so bands always tile the
            // column's full height exactly, with no seam at the bottom.
            let h = max(0, height - cursor)
            bands.append(LayerBand(node: nil, bucketParent: parent, bucketCount: tail.count, passThrough: [],
                                   size: tailSize, y: y + cursor, height: h))
        }
        return bands
    }

    // MARK: - Pass-through

    private static func isSplittable(_ node: FileNode) -> Bool {
        node.isDirectory && node.size > 0 && node.children.contains { $0.size > 0 }
    }

    /// Walks `node`'s single dominant child (≥ `mostOfParentShare` of it) as long as that
    /// child is itself splittable, up to `maxPassThroughHops` — the same "this is the same
    /// thing one level down" compression `FloorLayout.split` uses for regions, so an app
    /// bundle whose `Contents` is basically the whole thing doesn't burn a column on a
    /// single near-total band. Returns the chain, outermost first; empty when nothing
    /// dominates.
    private static func resolvePassThrough(_ node: FileNode) -> [FileNode] {
        guard isSplittable(node) else { return [] }
        var current = node
        var chain: [FileNode] = []
        var hops = 0
        while hops < ColumnsConstants.maxPassThroughHops {
            guard let dominant = current.children.first(where: { $0.size > 0 }), current.size > 0,
                  Double(dominant.size) >= ColumnsConstants.mostOfParentShare * Double(current.size),
                  isSplittable(dominant) else { break }
            chain.append(dominant)
            current = dominant
            hops += 1
        }
        return chain
    }

    // MARK: - Lookup (hover lineage, hit testing)

    /// The band showing `node` itself (its own name, not folded into another band's
    /// pass-through chain), if it's visible in the built columns.
    func location(of node: FileNode) -> (column: Int, index: Int)? {
        for (c, col) in columns.enumerated() {
            if let i = col.bands.firstIndex(where: { $0.node === node }) { return (c, i) }
        }
        return nil
    }

    func band(at location: (column: Int, index: Int)) -> LayerBand? {
        guard columns.indices.contains(location.column), columns[location.column].bands.indices.contains(location.index) else { return nil }
        return columns[location.column].bands[location.index]
    }

    /// Bands in every column *before* `column` whose y-range fully contains `range` — the
    /// unbroken chain of ancestor bands back toward the spine. Exactly one per column, by
    /// construction (a child's range is always nested inside its parent's).
    func ancestors(ofColumn column: Int, range: (CGFloat, CGFloat)) -> [(column: Int, index: Int)] {
        guard column > 0 else { return [] }
        var result: [(column: Int, index: Int)] = []
        for c in 0..<column {
            if let i = columns[c].bands.firstIndex(where: {
                $0.y - 0.5 <= range.0 && $0.y + $0.height + 0.5 >= range.1
            }) {
                result.append((c, i))
            }
        }
        return result
    }

    /// Every band in every column *after* `column` nested inside `range` — everything
    /// visually "inside" the hovered band, the descendant half of the lineage highlight.
    func descendants(ofColumn column: Int, range: (CGFloat, CGFloat)) -> [(column: Int, index: Int)] {
        guard column + 1 < columns.count else { return [] }
        var result: [(column: Int, index: Int)] = []
        for c in (column + 1)..<columns.count {
            for (i, band) in columns[c].bands.enumerated()
            where band.y + 0.25 >= range.0 && band.y + band.height - 0.25 <= range.1 {
                result.append((c, i))
            }
        }
        return result
    }
}

/// Pure geometry for column widths — no drawing, no state, so it can be shared between
/// layout and hit testing without ever going stale relative to what's on screen.
enum ColumnsGeometry {
    /// Widths of however many columns fit `totalWidth` (the canvas width minus the spine
    /// and its gutter): column 1 wants `idealFirstColumnWidth`, later columns want at
    /// least `minColumnWidth`, capped at `cap` (normally `ColumnsConstants.maxColumns`, but
    /// callers pass the tree's *actual* populated depth once it's known and it's shallower
    /// than the window could show — a leaf-only folder shouldn't leave the right two-thirds
    /// of the canvas empty just because there was room for a 4th column). The last column
    /// absorbs whatever's left over, so a wide window never leaves a dead band of empty
    /// canvas to the right — the "no huge empty area" rule — instead of scrolling or
    /// centering a fixed-width strip.
    static func columnWidths(totalWidth: CGFloat, cap: Int = ColumnsConstants.maxColumns) -> [CGFloat] {
        let avail = totalWidth - ColumnsConstants.spineWidth - ColumnsConstants.columnGutter
        guard avail > 0, cap > 0 else { return [] }
        guard avail >= ColumnsConstants.idealFirstColumnWidth else { return [avail] }

        var n = 1
        while n < cap {
            let needed = ColumnsConstants.idealFirstColumnWidth
                + CGFloat(n) * (ColumnsConstants.minColumnWidth + ColumnsConstants.columnGutter)
            guard needed <= avail else { break }
            n += 1
        }
        var widths = [CGFloat](repeating: ColumnsConstants.minColumnWidth, count: n)
        widths[0] = ColumnsConstants.idealFirstColumnWidth
        let gutters = CGFloat(n - 1) * ColumnsConstants.columnGutter
        let leftover = avail - widths.reduce(0, +) - gutters
        if leftover > 0 { widths[n - 1] += leftover }
        return widths
    }
}
