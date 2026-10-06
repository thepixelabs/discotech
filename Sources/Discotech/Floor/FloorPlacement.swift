import AppKit

/// Placement for `FloorLayout`: the plan's regions and children as squarified blocks of
/// whole grid cells. Pure functions of the plan and the area.
enum FloorPlacement {
    /// Header strip rows needed for a name plus a size line.
    static func headerRows(edge: CGFloat, height: CGFloat) -> Int {
        max(1, Int((height / max(1, edge)).rounded(.up)))
    }

    typealias Placement = (cols: Int, rows: Int, edge: CGFloat, header: Int, top: [FloorCells], inner: [[FloorCells]])
    enum PlaceResult {
        case placed(Placement)
        case gridTooTight
        case regionsTooTight([Int])
    }

    static func place(plans: [FloorPlanner.RegionPlan], area: CGSize, fill: Double, boost: [Double], strict: Bool,
                      headerHeight: CGFloat) -> PlaceResult {
        let tiles = plans.reduce(0) { $0 + $1.count }
        // Estimate the edge first (headers depend on it), then size the grid.
        let aspect = Double(area.width / area.height)
        func grid(cells: Double) -> (Int, Int, CGFloat) {
            var cols = max(1, Int((cells * aspect).squareRoot().rounded()))
            var rows = max(1, Int((cells / Double(cols)).rounded(.up)))
            let edge = min(area.width / CGFloat(cols), area.height / CGFloat(rows))
            // Use the whole area: add the columns or rows the edge leaves room for.
            cols = max(cols, Int(area.width / edge + 1e-6))
            rows = max(rows, Int(area.height / edge + 1e-6))
            return (cols, rows, edge)
        }
        let estimate = grid(cells: Double(tiles) / fill)
        let header = headerRows(edge: estimate.2, height: headerHeight)
        let minHeaderTiles = Int(ceil(pow(Double(header) / FloorStyle.headerMaxShare, 2)))

        // Which regions get a header (and children), and their weights in cells.
        var wantsHeader = [Bool](repeating: false, count: plans.count)
        var weights = [Double](repeating: 0, count: plans.count)
        for (i, plan) in plans.enumerated() {
            wantsHeader[i] = !plan.children.isEmpty && plan.count >= minHeaderTiles
            let headerCells = wantsHeader[i] ? Double(header) * Double(plan.count).squareRoot() * 1.15 : 0
            weights[i] = Double(plan.count) + headerCells
        }
        // The grid is sized from the plain weights; a boost only shifts share toward a
        // region whose children were too tight, at the other regions' expense.
        let (cols, rows, edge) = grid(cells: weights.reduce(0, +) / fill)
        for i in weights.indices { weights[i] *= boost[i] }
        let whole = FloorCells(col: 0, row: 0, cols: cols, rows: rows)
        // A region that shows children needs room for their rounding too.
        let items = plans.indices.map { i -> PlaceItem in
            let plan = plans[i]
            guard wantsHeader[i] else {
                return PlaceItem(weight: weights[i], need: plan.count, headerRows: 0, absorbs: plan.node == nil)
            }
            let need = Int(ceil((Double(plan.count) * 1.03 + Double(plan.children.count)) * boost[i]))
            return PlaceItem(weight: weights[i], need: need, headerRows: header)
        }
        guard let top = squarify(items, in: whole, strict: strict) else {
            debugFail("top fill=\(fill) grid=\(cols)x\(rows) header=\(header)")
            return .gridTooTight
        }
        var tight: [Int] = []

        var inner: [[FloorCells]] = []
        for (i, plan) in plans.enumerated() {
            let box = top[i]
            guard wantsHeader[i], box.rows > header, box.cols >= 2 else {
                if wantsHeader[i], strict { debugFail("thin header region \(i) box=\(box)"); tight.append(i) }
                inner.append([])
                continue
            }
            let content = FloorCells(col: box.col, row: box.row + header, cols: box.cols, rows: box.rows - header)
            let childItems = plan.children.map {
                PlaceItem(weight: Double($0.count), need: $0.count, headerRows: 0, absorbs: $0.node == nil)
            }
            if let placed = squarify(childItems, in: content, strict: strict) {
                inner.append(placed)
            } else if strict {
                debugFail("children of region \(i) box=\(content) need=\(plan.count) cap=\(content.area) kids=\(plan.children.map(\.count))")
                tight.append(i)
                inner.append([])
            } else {
                inner.append([])
            }
        }
        if !tight.isEmpty { return .regionsTooTight(tight) }
        #if DEBUG
        if ProcessInfo.processInfo.environment["DISCOTECH_FLOOR_TIMING"] != nil {
            FileHandle.standardError.write(Data(String(format: "floor placed: fill %.2f, %d tiles in %d cells\n",
                                                       fill, tiles, cols * rows).utf8))
        }
        #endif
        return .placed((cols, rows, edge, header, top, inner))
    }

    private static func debugFail(_ message: @autoclosure () -> String) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["DISCOTECH_FLOOR_TIMING"] != nil {
            FileHandle.standardError.write(Data("floor place failed: \(message())\n".utf8))
        }
        #endif
    }

    private struct PlaceItem {
        let weight: Double
        let need: Int
        let headerRows: Int
        /// "Everything else": always placed alone, last, where it soaks up the rounding
        /// slack instead of a real item being stretched into a sliver.
        var absorbs = false
    }

    private static func capacity(_ cells: FloorCells, headerRows: Int) -> Int {
        max(0, cells.cols) * max(0, cells.rows - headerRows)
    }

    /// Squarified treemap on whole cells. Rows are laid along the shorter side of what's
    /// left; each item gets at least enough cells for its `need` tiles (plus its header
    /// rows), and the rest of the row's length is shared out by weight. The last row
    /// takes all remaining space, so nothing is left unassigned. `nil` (in strict mode)
    /// when the counts don't fit; the caller then retries with a roomier grid.
    private static func squarify(_ items: [PlaceItem], in box: FloorCells, strict: Bool) -> [FloorCells]? {
        var out = [FloorCells](repeating: .zero, count: items.count)
        guard !items.isEmpty else { return out }
        var rem = box
        var remWeight = items.reduce(0.0) { $0 + $1.weight }
        var i = 0
        while i < items.count {
            if rem.isEmpty {
                if strict { return nil }
                break
            }
            let vertical = rem.cols >= rem.rows // a column at the left, items stacked downward
            let side = vertical ? rem.rows : rem.cols
            let long = vertical ? rem.cols : rem.rows
            let scale = Double(rem.area) / max(remWeight, 1e-9)

            func worst(_ range: Range<Int>) -> Double {
                let areas = range.map { items[$0].weight * scale }
                let s = areas.reduce(0, +)
                guard s > 0 else { return .infinity }
                let t = s / Double(side)
                return areas.map { a in let l = a / t; return max(l / t, t / l) }.max() ?? .infinity
            }
            var j = i + 1
            var best = worst(i..<j)
            while j < items.count, !items[j].absorbs, !items[i].absorbs {
                let w = worst(i..<(j + 1))
                if w > best { break }
                best = w
                j += 1
            }
            func minLength(_ item: PlaceItem, _ t: Int) -> Int? {
                if vertical {
                    return Int(ceil(Double(item.need) / Double(t))) + item.headerRows
                }
                let usable = t - item.headerRows
                guard usable > 0 else { return nil }
                return Int(ceil(Double(item.need) / Double(usable)))
            }
            func lowerBounds(_ range: Range<Int>, _ t: Int) -> [Int]? {
                var out: [Int] = []
                for k in range {
                    guard let l = minLength(items[k], t) else { return nil }
                    out.append(l)
                }
                return out.reduce(0, +) <= side ? out : nil
            }
            // Thickness: the proportional one, but never less than the row's tiles need,
            // never more than leaves the rest of the items the room theirs need (hard),
            // and preferably a little less (soft, so rounding doesn't starve the tail).
            // If no thickness fits the row, move its last item to the next row.
            var t = 1
            var lower: [Int]?
            var row = i..<j
            while true {
                row = i..<j
                let isLast = j == items.count
                let restNeed = items[j...].reduce(0) { $0 + $1.need + $1.headerRows * Int(Double($1.need).squareRoot().rounded(.up)) }
                let hard = isLast ? long : long - max(1, Int(ceil(Double(restNeed) / Double(side))))
                let soft = isLast ? long : long - (Int(ceil(Double(restNeed) * 1.1 / Double(side))) + 1)
                var fit: Int?
                if hard >= 1 {
                    for candidate in 1...hard where lowerBounds(row, candidate) != nil { fit = candidate; break }
                }
                if let fit {
                    let rowArea = row.reduce(0.0) { $0 + items[$1].weight * scale }
                    t = isLast ? long : min(max(fit, hard), max(fit, min(Int(rowArea / Double(side)), soft)))
                    lower = lowerBounds(row, t)
                    break
                }
                if j - i <= 1 {
                    t = max(1, min(long, hard))
                    break
                }
                j -= 1
            }
            if lower == nil {
                if strict { return nil }
                lower = row.map { _ in 0 }
            }
            let lengths = distribute(side, lower: lower!, weights: row.map { items[$0].weight })
            var offset = 0
            for (k, idx) in row.enumerated() {
                let l = lengths[k]
                out[idx] = vertical
                    ? FloorCells(col: rem.col, row: rem.row + offset, cols: t, rows: l)
                    : FloorCells(col: rem.col + offset, row: rem.row, cols: l, rows: t)
                offset += l
            }
            if vertical { rem.col += t; rem.cols -= t } else { rem.row += t; rem.rows -= t }
            remWeight -= row.reduce(0.0) { $0 + items[$1].weight }
            i = j
        }
        if strict {
            for (k, item) in items.enumerated() where capacity(out[k], headerRows: item.headerRows) < item.need {
                return nil
            }
        }
        return out
    }

    /// Splits `total` cells of length among a row's items: each gets at least its
    /// `lower` bound, and what's left goes where it brings lengths closest to weight.
    private static func distribute(_ total: Int, lower: [Int], weights: [Double]) -> [Int] {
        var out = lower
        let extra = total - lower.reduce(0, +)
        guard extra > 0 else { return out }
        let sumW = weights.reduce(0, +)
        var want = weights.indices.map { max(0, weights[$0] / max(sumW, 1e-9) * Double(total) - Double(lower[$0])) }
        if want.reduce(0, +) <= 0 { want = weights }
        let sumWant = max(want.reduce(0, +), 1e-9)
        let shares = want.map { $0 / sumWant * Double(extra) }
        var given = 0
        for k in out.indices { let s = Int(shares[k]); out[k] += s; given += s }
        let order = out.indices.sorted { (shares[$0] - floor(shares[$0])) > (shares[$1] - floor(shares[$1])) }
        for k in order where given < extra { out[k] += 1; given += 1 }
        return out
    }
}
