import AppKit

/// Planning for `FloorLayout`: what goes on the floor and how many cells (tiles) each
/// region and child is worth. Pure functions of the tree and the tile budget.
enum FloorPlanner {
    /// A child block inside a region.
    struct ChildPlan {
        let node: FileNode?
        let bucketParent: FileNode?
        let bucketCount: Int
        let size: Int64
        let count: Int
    }

    /// A top-level region and, if it is big enough to show them, its children.
    struct RegionPlan {
        let node: FileNode?
        let bucketCount: Int
        let size: Int64
        let count: Int
        var chain: [FileNode] = []
        var children: [ChildPlan] = []
    }

    static func plan(kids: [FileNode], tiles n: Int) -> [RegionPlan] {
        var plans: [RegionPlan] = []
        let minTiles = max(FloorStyle.minRegionTiles, Double(n) * FloorStyle.minRegionShare)
        for entry in allocate(children: kids, tiles: n, minTiles: minTiles, maxItems: FloorStyle.maxRegions) {
            switch entry.kind {
            case .bucket(let count, let bytes):
                plans.append(RegionPlan(node: nil, bucketCount: count, size: bytes, count: entry.count))
            case .node(let node):
                var plan = RegionPlan(node: node, bucketCount: 0, size: node.size, count: entry.count)
                if !node.isPackage, entry.count >= FloorStyle.minSubdivideTiles {
                    var chain: [FileNode] = []
                    let children = split(node, count: entry.count, hops: 0, chain: &chain)
                    if children.count >= 2 {
                        plan.children = sortedForPlacement(children)
                        plan.chain = chain
                    }
                }
                plans.append(plan)
            }
        }
        // Largest first, "Everything else" always last.
        return plans.enumerated().sorted { a, b in
            if (a.element.node == nil) != (b.element.node == nil) { return a.element.node != nil }
            if a.element.count != b.element.count { return a.element.count > b.element.count }
            return a.offset < b.offset
        }.map(\.element)
    }

    private static func sortedForPlacement(_ children: [ChildPlan]) -> [ChildPlan] {
        children.enumerated().sorted { a, b in
            if (a.element.node == nil) != (b.element.node == nil) { return a.element.node != nil }
            if a.element.count != b.element.count { return a.element.count > b.element.count }
            return a.offset < b.offset
        }.map(\.element)
    }

    private static func isSplittable(_ node: FileNode) -> Bool {
        node.isDirectory && !node.isPackage && !node.children.isEmpty
    }

    /// Splits `count` tiles among `node`'s children. A child that is nearly all of
    /// `node` (≥ `mostOfParent`) is the same thing one level down, so it is split in turn
    /// (up to four hops); that is how a dominant region such as /Users still shows its
    /// structure.
    private static func split(_ node: FileNode, count: Int, hops: Int, chain: inout [FileNode]) -> [ChildPlan] {
        guard isSplittable(node) else { return [] }
        let kids = node.children.filter { $0.size > 0 }
        let sum = kids.reduce(Int64(0)) { $0 + $1.size }
        var out: [ChildPlan] = []
        let minTiles = max(FloorStyle.minChildTiles, Double(count) * FloorStyle.minChildShare)
        for entry in allocate(children: kids, tiles: count, minTiles: minTiles, maxItems: FloorStyle.maxChildren) {
            switch entry.kind {
            case .bucket(let n, let bytes):
                out.append(ChildPlan(node: nil, bucketParent: node, bucketCount: n, size: bytes, count: entry.count))
            case .node(let child):
                if hops < 4, entry.count >= 2, isSplittable(child),
                   Double(child.size) >= FloorStyle.mostOfParent * Double(max(1, sum)) {
                    chain.append(child)
                    let inner = split(child, count: entry.count, hops: hops + 1, chain: &chain)
                    if inner.isEmpty {
                        chain.removeLast()
                        out.append(ChildPlan(node: child, bucketParent: nil, bucketCount: 0, size: child.size, count: entry.count))
                    } else {
                        out.append(contentsOf: inner)
                    }
                } else {
                    out.append(ChildPlan(node: child, bucketParent: nil, bucketCount: 0, size: child.size, count: entry.count))
                }
            }
        }
        return out
    }

    private enum EntryKind { case node(FileNode), bucket(count: Int, bytes: Int64) }
    private struct Entry { let kind: EntryKind; let count: Int }

    /// Damped area weight of `bytes` (see `FloorStyle.areaExponent`).
    static func areaWeight(_ bytes: Int64) -> Double {
        pow(Double(max(0, bytes)), FloorStyle.areaExponent)
    }

    /// Splits `tiles` among `children` by damped weight, by largest remainder, so the
    /// counts always add up exactly to the parent's. The largest children get their own
    /// entry while the smallest of them is still worth `minTiles` cells (at most
    /// `maxItems` of them); the rest fold into a trailing "Everything else" entry,
    /// weighted as one item of their combined size.
    private static func allocate(children: [FileNode], tiles: Int, minTiles: Double, maxItems: Int) -> [Entry] {
        guard tiles > 0 else { return [] }
        let sorted = children.filter { $0.size > 0 }.sorted { $0.size > $1.size }
        let totalBytes = sorted.reduce(Int64(0)) { $0 + $1.size }
        guard totalBytes > 0 else { return [] }
        // Fewer own entries only ever enlarge the smallest one's share (the weight is
        // concave, so the bucket grows by less than the item it absorbs), so count down.
        var keep = min(sorted.count, maxItems)
        var keptWeights = sorted[..<keep].map { areaWeight($0.size) }
        while keep > 0 {
            let restBytes = totalBytes - sorted[..<keep].reduce(Int64(0)) { $0 + $1.size }
            let sum = keptWeights.reduce(0, +) + (restBytes > 0 ? areaWeight(restBytes) : 0)
            if keptWeights[keep - 1] / sum * Double(tiles) >= minTiles { break }
            keep -= 1
            keptWeights.removeLast()
        }
        var kinds: [EntryKind] = sorted[..<keep].map { .node($0) }
        var weights = keptWeights
        let otherCount = sorted.count - keep
        if otherCount > 0 {
            let otherBytes = sorted[keep...].reduce(Int64(0)) { $0 + $1.size }
            kinds.append(.bucket(count: otherCount, bytes: otherBytes))
            weights.append(areaWeight(otherBytes))
        }
        let sum = weights.reduce(0, +)
        let raws = weights.map { $0 / sum * Double(tiles) }
        var counts = raws.map { Int($0) }
        var left = tiles - counts.reduce(0, +)
        let order = raws.indices.sorted { (raws[$0] - Double(counts[$0])) > (raws[$1] - Double(counts[$1])) }
        for i in order where left > 0 { counts[i] += 1; left -= 1 }
        return zip(kinds, counts).compactMap { $1 > 0 ? Entry(kind: $0, count: $1) : nil }
    }
}
