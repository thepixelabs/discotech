import AppKit

/// The floor for one focus at one size: a squarified treemap snapped to a grid of equal
/// cells (the layout's unit of area; never drawn). Every region and child is a rectangle
/// of whole cells big enough to hold its count. Counts are damped
/// (`FloorStyle.areaExponent`), so area ranks items by size without letting the biggest
/// one swallow the floor; labels carry the true sizes.
/// The grid always spans the whole area edge to edge: a cell's width and height are
/// `area / columns` and `area / rows`, so they differ by at most one cell's worth spread
/// over the whole row (a few percent), instead of leaving a ragged margin.
/// Rebuilt when the focus, the tree or the view size changes; hover only reads it.
final class FloorLayout {
    private static var serial = 0
    /// Unique per built layout (cache key for its bitmaps).
    let id: Int
    let focus: FileNode
    /// Cells in use (sum of every leaf's count).
    let tileCount: Int
    let columns: Int
    let rows: Int
    /// Cell size, points (`size.width / columns`, `size.height / rows`).
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    /// The shorter cell side; gaps and radii are capped against it.
    var edge: CGFloat { min(cellWidth, cellHeight) }
    /// Grid size in points: the whole area it was built for.
    let size: CGSize
    private(set) var regions: [FloorRegion] = []
    private(set) var leaves: [FloorLeaf] = []

    private var regionByNode: [ObjectIdentifier: Int] = [:]
    private var leafByNode: [ObjectIdentifier: Int] = [:]
    private var leavesByPassThrough: [ObjectIdentifier: [Int]] = [:]
    private var bucketByParent: [ObjectIdentifier: Int] = [:]

    var isEmpty: Bool { tileCount == 0 }

    // MARK: - Build

    /// - Parameter area: points available for the grid.
    init(focus: FileNode, area: CGSize) {
        Self.serial += 1
        self.id = Self.serial
        self.focus = focus
        let kids = focus.children.filter { $0.size > 0 }
        let target = Double(area.width * area.height) / Double(FloorStyle.targetTile * FloorStyle.targetTile)
        let targetTiles = min(Double(FloorStyle.maxTiles), max(Double(FloorStyle.minTiles), target))
        let n = kids.isEmpty ? 0 : Int(targetTiles.rounded())

        // 1. What goes on the floor, and how many cells each piece is worth.
        let plans = FloorPlanner.plan(kids: kids, tiles: n)
        self.tileCount = plans.reduce(0) { $0 + $1.count }

        // 2. Grid and placement: start with ~4% spare cells and loosen until every block
        //    fits its tiles (a squarified row can't always hit exact counts).
        var chosen: (cols: Int, rows: Int, edge: CGFloat, header: Int, top: [FloorCells], inner: [[FloorCells]])?
        if tileCount > 0, area.width > 1, area.height > 1 {
            var fill = FloorStyle.gridFill
            var boost = [Double](repeating: 1, count: plans.count)
            for attempt in 0..<FloorStyle.gridAttempts {
                let strict = attempt < FloorStyle.gridAttempts - 1
                switch FloorPlacement.place(plans: plans, area: area, fill: fill, boost: boost, strict: strict,
                                            headerHeight: FloorStyle.headerHeight) {
                case .placed(let found):
                    chosen = found
                case .regionsTooTight(let tight):
                    // Only those regions get more room for their children.
                    for i in tight { boost[i] *= 1.12 }
                case .gridTooTight:
                    fill = max(0.5, fill - 0.05)
                }
                if chosen != nil { break }
            }
        }
        guard let chosen else {
            self.columns = 0; self.rows = 0; self.cellWidth = 0; self.cellHeight = 0; self.size = .zero
            return
        }
        self.columns = chosen.cols
        self.rows = chosen.rows
        // Stretch the grid to the area: no leftover margin on either axis.
        self.size = area
        self.cellWidth = area.width / CGFloat(chosen.cols)
        self.cellHeight = area.height / CGFloat(chosen.rows)

        // 3. Regions and leaves, with their resting rectangles.
        for (ri, plan) in plans.enumerated() {
            var region = FloorRegion(node: plan.node, passThrough: plan.chain, size: plan.size, count: plan.count)
            region.cells = chosen.top[ri]
            let subdivided = !chosen.inner[ri].isEmpty
            region.headerRows = subdivided ? chosen.header : 0
            let first = leaves.count
            if let node = plan.node { regionByNode[ObjectIdentifier(node)] = ri }
            if subdivided {
                for (ci, child) in plan.children.enumerated() {
                    var leaf = FloorLeaf(node: child.node, bucketParent: child.bucketParent, bucketCount: child.bucketCount,
                                         size: child.size, region: ri, depth: 1, count: child.count)
                    leaf.cells = chosen.inner[ri][ci]
                    if let node = child.node { leafByNode[ObjectIdentifier(node)] = leaves.count }
                    if let parent = child.bucketParent { bucketByParent[ObjectIdentifier(parent)] = leaves.count }
                    leaves.append(leaf)
                }
                for node in plan.chain {
                    leavesByPassThrough[ObjectIdentifier(node)] = Array(first..<leaves.count).filter {
                        let leaf = leaves[$0]
                        return leaf.node?.isDescendant(of: node) ?? (leaf.bucketParent?.isDescendant(of: node) ?? false)
                    }
                }
            } else {
                var leaf = FloorLeaf(node: plan.node, bucketParent: plan.node == nil ? focus : nil,
                                     bucketCount: plan.bucketCount, size: plan.size, region: ri, depth: 0, count: plan.count)
                leaf.cells = region.cells
                if let node = plan.node { leafByNode[ObjectIdentifier(node)] = leaves.count }
                else { bucketByParent[ObjectIdentifier(focus)] = leaves.count }
                leaves.append(leaf)
            }
            region.leaves = first..<leaves.count
            regions.append(region)
        }
        computeRects()
        assignPaints()
    }

    // MARK: - Geometry

    /// Cells → points, top-down from the grid's top-left corner (the full cell extent,
    /// before any gap).
    func rect(of cells: FloorCells) -> CGRect {
        let x0 = CGFloat(cells.col) * cellWidth, x1 = CGFloat(cells.col + cells.cols) * cellWidth
        let y0 = CGFloat(cells.row) * cellHeight, y1 = CGFloat(cells.row + cells.rows) * cellHeight
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Gaps, capped against the cell edge so a one-cell block keeps most of its cell at
    /// the smallest window sizes.
    var gutter: CGFloat { min(FloorStyle.regionGap, edge * 0.42) }
    var childGap: CGFloat { min(FloorStyle.childGap, edge * 0.26) }
    var regionPad: CGFloat { min(FloorStyle.regionPad, edge * 0.3) }

    /// `r` inset by `interior` on every side that is inside `bounds`, and by `boundary`
    /// on every side that lies on `bounds`' edge. That keeps gaps between neighbours equal
    /// and the outer margin exactly the padding the caller chose.
    private static func inset(_ r: CGRect, in bounds: CGRect, interior: CGFloat, boundary: CGFloat) -> CGRect {
        let eps: CGFloat = 0.01
        let l = abs(r.minX - bounds.minX) < eps ? boundary : interior
        let rt = abs(r.maxX - bounds.maxX) < eps ? boundary : interior
        let t = abs(r.minY - bounds.minY) < eps ? boundary : interior
        let b = abs(r.maxY - bounds.maxY) < eps ? boundary : interior
        return CGRect(x: r.minX + l, y: r.minY + t, width: max(0, r.width - l - rt), height: max(0, r.height - t - b))
    }

    private func computeRects() {
        let whole = CGRect(origin: .zero, size: size)
        for ri in regions.indices {
            var region = regions[ri]
            region.rect = Self.inset(rect(of: region.cells), in: whole, interior: gutter / 2, boundary: 0)
            if region.isSubdivided {
                let headerCells = FloorCells(col: region.cells.col, row: region.cells.row, cols: region.cells.cols,
                                             rows: region.headerRows)
                let headerBottom = rect(of: headerCells).maxY
                region.headerRect = CGRect(x: region.rect.minX, y: region.rect.minY,
                                           width: region.rect.width, height: max(0, headerBottom - region.rect.minY))
                // Children fill the region below the header: `regionPad` from the region's
                // edges, `childGap` between each other.
                let content = CGRect(x: region.rect.minX, y: headerBottom, width: region.rect.width,
                                     height: max(0, region.rect.maxY - headerBottom))
                for li in region.leaves {
                    let cell = rect(of: leaves[li].cells).intersection(content)
                    guard !cell.isNull else { leaves[li].rect = .zero; continue }
                    // Measured against a content box that reaches above the header, so the
                    // top row is never "on the edge": the header's own bottom padding
                    // stands in for the region pad there.
                    let bounds = CGRect(x: content.minX, y: content.minY - 1, width: content.width, height: content.height + 1)
                    let r = Self.inset(cell, in: bounds, interior: childGap / 2, boundary: regionPad)
                    leaves[li].rect = r.width > 0.5 && r.height > 0.5 ? r : .zero
                }
            } else {
                for li in region.leaves { leaves[li].rect = region.rect }
            }
            regions[ri] = region
        }
    }

    /// Resting rectangle covering cells `first ..< first + count` of `leaf`: the rows
    /// they occupy, as a band of the leaf's rectangle.
    func bandRect(ofLeaf index: Int, first: Int, count: Int) -> CGRect {
        let leaf = leaves[index]
        guard leaf.cells.cols > 0, leaf.cells.rows > 0 else { return leaf.rect }
        let r0 = first / leaf.cells.cols
        let r1 = min(leaf.cells.rows, (first + count + leaf.cells.cols - 1) / leaf.cells.cols)
        let top = CGFloat(leaf.cells.row + r0) * cellHeight
        let bottom = CGFloat(leaf.cells.row + max(r1, r0 + 1)) * cellHeight
        let band = CGRect(x: leaf.rect.minX, y: top, width: leaf.rect.width, height: bottom - top)
        let clipped = band.intersection(leaf.rect)
        return clipped.isNull ? leaf.rect : clipped
    }

    // MARK: - Colour

    /// Every region and block takes its own `Palette` paint, the same mapping as the Ball
    /// and Layers: by size, kind or top-level folder (the user's "Colour by"). Touching
    /// blocks may share a colour; that is the meaning, not a clash.
    private func assignPaints() {
        for ri in regions.indices {
            regions[ri].paint = regions[ri].node.flatMap { Palette.paint(for: $0, in: focus) }
        }
        for li in leaves.indices {
            leaves[li].paint = leaves[li].node.flatMap { Palette.paint(for: $0, in: focus) }
        }
    }

    /// A node's label candidates, longest first: "Xcode.app", then "Xcode" for a package.
    static func nameVariants(_ node: FileNode) -> [String] {
        let name = displayName(node)
        let ext = (name as NSString).pathExtension
        let isBundle = node.isPackage || ["app", "bundle", "framework", "plugin", "component", "vst3"].contains(ext.lowercased())
        return isBundle && !ext.isEmpty && node.isDirectory ? [name, (name as NSString).deletingPathExtension] : [name]
    }

    /// The root node's `name` is its full path; show the friendly volume/folder name.
    static func displayName(_ node: FileNode) -> String {
        node.parent == nil ? FileManager.default.displayName(atPath: node.path) : node.name
    }

    // MARK: - Lookup

    /// What's under `point` (top-down points from the grid's top-left). Gutters belong to
    /// the region around them, so moving between blocks never flickers to "nothing".
    func hit(_ point: CGPoint) -> FloorHit? {
        guard cellWidth > 0, cellHeight > 0, point.x >= 0, point.y >= 0 else { return nil }
        let c = Int(point.x / cellWidth), r = Int(point.y / cellHeight)
        guard c < columns, r < rows else { return nil }
        guard let ri = regions.firstIndex(where: { $0.cells.contains(col: c, row: r) }) else { return nil }
        let region = regions[ri]
        if region.isSubdivided {
            if r < region.cells.row + region.headerRows { return .region(ri) }
            if let li = region.leaves.first(where: { leaves[$0].cells.contains(col: c, row: r) }) { return .leaf(li) }
            return .region(ri)
        }
        return .leaf(region.leaves.lowerBound)
    }

    /// The node a hit stands for (a region header stands for the region's folder).
    func node(for hit: FloorHit) -> FileNode? {
        switch hit {
        case .region(let ri): return regions[ri].node
        case .leaf(let li): return leaves[li].node
        }
    }

    /// Where `node` is on the floor. `used` counts cells already handed out inside a
    /// leaf (key: leaf index), so several small items in one block stack instead of
    /// overlapping. `nil` when `node` is outside the focus.
    func mark(for node: FileNode, used: inout [Int: Int]) -> FloorMark? {
        if node === focus || focus.isDescendant(of: node) { return .regions(Array(regions.indices)) }
        guard node.isDescendant(of: focus) else { return nil }
        var cur = node
        while cur !== focus {
            let id = ObjectIdentifier(cur)
            if let ri = regionByNode[id], regions[ri].isSubdivided {
                return cur === node ? .regions([ri]) : .leaves(Array(regions[ri].leaves))
            }
            if let li = leafByNode[id] {
                return cur === node ? .leaves([li]) : partial(node, in: li, used: &used)
            }
            if let list = leavesByPassThrough[id] {
                return .leaves(list)
            }
            guard let parent = cur.parent else { return nil }
            if let bucket = bucketByParent[ObjectIdentifier(parent)] {
                return partial(node, in: bucket, used: &used)
            }
            cur = parent
        }
        return nil
    }

    private func partial(_ node: FileNode, in leaf: Int, used: inout [Int: Int]) -> FloorMark {
        // Inside one block, area is proportional to bytes again.
        let owner = leaves[leaf].count
        let share = Double(node.size) / Double(max(1, leaves[leaf].size))
        let n = min(owner, max(1, Int((share * Double(owner)).rounded())))
        let offset = min(max(0, owner - 1), used[leaf, default: 0])
        used[leaf] = offset + n
        return .partial(leaf: leaf, first: offset, count: min(n, owner - offset))
    }

    /// Resting rectangles for a mark, with the corner radius each is drawn with.
    func rects(for mark: FloorMark) -> [(CGRect, CGFloat)] {
        switch mark {
        case .regions(let list):
            return list.map { (regions[$0].rect, regionRadius(regions[$0].rect)) }
        case .leaves(let list):
            return list.map { (leaves[$0].rect, leafRadius(leaves[$0])) }
        case .partial(let leaf, let first, let count):
            let band = bandRect(ofLeaf: leaf, first: first, count: count)
            return [(band, min(leafRadius(leaves[leaf]), band.height / 2))]
        }
    }

    func regionRadius(_ rect: CGRect) -> CGFloat {
        min(FloorStyle.regionRadius, min(rect.width, rect.height) * 0.3)
    }

    /// Children are concentric with their region where they touch its edge.
    func leafRadius(_ leaf: FloorLeaf) -> CGFloat {
        leaf.depth == 0 ? regionRadius(leaf.rect) : min(FloorStyle.childRadius, min(leaf.rect.width, leaf.rect.height) * 0.3)
    }
}
