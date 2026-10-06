import CoreGraphics
import Foundation
import Testing
@testable import Discotech

/// A tree with one dominant folder, a few mid-sized items and many tiny files, so the
/// planner has something to damp, group and fold. Sizes are fixed, so everything is exact.
private func floorTree() -> FileNode {
    var children: [FileNode] = [
        dirNode("Users", [dirNode("me", [fileNode("big.bin", 6_000 * MB), fileNode("mid.bin", 500 * MB)])]),
        dirNode("Applications", (0..<12).map { fileNode("app\($0).bin", 40 * MB) }),
        dirNode("Library", (0..<8).map { fileNode("lib\($0).bin", 30 * MB) }),
        fileNode("swapfile", 1_000 * MB),
        fileNode("hibernate", 400 * MB),
    ]
    children += (0..<60).map { fileNode("tiny\($0).txt", Int64(4_096 + $0)) }
    return treeNode(root: "/Volumes/Disk", children)
}

extension GlobalState {
    @MainActor
    @Suite("Floor: planning and placement")
    struct FloorTests {
        private let area = CGSize(width: 900, height: 600)

        // MARK: Planner

        @Test("area is damped: a block 100 times bigger gets about 10 times the cells, not 100")
        func areaIsDamped() {
            let kids = [fileNode("big", 100_000 * MB), fileNode("small", 1_000 * MB)]
            let plan = FloorPlanner.plan(kids: kids, tiles: 1_000)
            let planned: Int = plan.map(\.count).reduce(0, +)
            #expect(planned == 1_000)
            let ratio = Double(plan[0].count) / Double(plan[1].count)
            #expect(abs(ratio - 10) < 0.5, "ratio \(ratio)")
            #expect(FloorStyle.areaExponent == 0.5)
        }

        @Test("areaWeight is the damped size, zero for nothing and for negatives")
        func areaWeight() {
            #expect(FloorPlanner.areaWeight(0) == 0)
            #expect(FloorPlanner.areaWeight(-5) == 0)
            #expect(FloorPlanner.areaWeight(10_000) == 100)
        }

        @Test("the planner hands out exactly the tiles it was given, to nobody twice")
        func tilesAddUp() {
            for tiles in [120, 500, 1_234, 2_600] {
                let plan = FloorPlanner.plan(kids: floorTree().children, tiles: tiles)
                let handedOut: Int = plan.map(\.count).reduce(0, +)
                #expect(handedOut == tiles, "\(tiles) tiles")
                for region in plan where !region.children.isEmpty {
                    let inside: Int = region.children.map(\.count).reduce(0, +)
                    #expect(inside == region.count, "\(tiles) tiles, \(region.node?.name ?? "bucket")")
                }
            }
        }

        @Test("regions come largest first and the 'Everything else' region is always last")
        func orderAndBucket() {
            let plan = FloorPlanner.plan(kids: floorTree().children, tiles: 600)
            let named = plan.filter { $0.node != nil }
            let counts: [Int] = named.map(\.count)
            #expect(counts == counts.sorted(by: >))
            #expect(plan.last?.node == nil)
            #expect(plan.filter { $0.node == nil }.count == 1)
        }

        @Test("small items fold into one bucket that remembers how many and how many bytes")
        func smallItemsGroup() throws {
            let kids = floorTree().children
            let plan = FloorPlanner.plan(kids: kids, tiles: 400)
            let bucket = try #require(plan.last)
            #expect(bucket.node == nil)
            let named = Set(plan.compactMap(\.node).map(ObjectIdentifier.init))
            let folded = kids.filter { !named.contains(ObjectIdentifier($0)) }
            #expect(bucket.bucketCount == folded.count)
            #expect(bucket.size == folded.reduce(0) { $0 + $1.size })
        }

        @Test("no regions at all for no tiles or an empty folder")
        func emptyPlans() {
            #expect(FloorPlanner.plan(kids: [], tiles: 100).isEmpty)
            #expect(FloorPlanner.plan(kids: floorTree().children, tiles: 0).isEmpty)
        }

        @Test("a folder that is nearly all of its parent is passed through, so /Users/me shows its own content")
        func passThrough() throws {
            let plan = FloorPlanner.plan(kids: floorTree().children, tiles: 1_000)
            let users = try #require(plan.first { $0.node?.name == "Users" })
            #expect(users.chain.map(\.name) == ["me"])
            #expect(users.children.contains { $0.node?.name == "big.bin" })
        }

        @Test("a package is never opened up into its contents")
        func packagesStayWhole() {
            let app = dirNode("Big.app", package: true, (0..<20).map { fileNode("f\($0)", 100 * MB) })
            app.finalize()
            let plan = FloorPlanner.plan(kids: [app, fileNode("other", 100 * MB)], tiles: 800)
            #expect(plan.first { $0.node === app }?.children.isEmpty == true)
        }

        @Test("zero-byte items are not planned")
        func zeroBytes() {
            let plan = FloorPlanner.plan(kids: [fileNode("a", 100), fileNode("zero", 0)], tiles: 200)
            #expect(plan.compactMap(\.node).map(\.name) == ["a"])
        }

        // MARK: Cells

        @Test("FloorCells area, containment and edge contact")
        func cells() {
            let a = FloorCells(col: 0, row: 0, cols: 3, rows: 2)
            #expect(a.area == 6)
            #expect(a.contains(col: 2, row: 1) && !a.contains(col: 3, row: 0) && !a.contains(col: 0, row: 2))
            #expect(FloorCells.zero.isEmpty)
            #expect(a.touches(FloorCells(col: 3, row: 1, cols: 2, rows: 2)))
            #expect(a.touches(FloorCells(col: 1, row: 2, cols: 1, rows: 1)))
            #expect(!a.touches(FloorCells(col: 3, row: 2, cols: 1, rows: 1)), "corners alone do not count")
            #expect(!a.touches(FloorCells(col: 5, row: 0, cols: 1, rows: 1)))
        }

        @Test("a header strip needs as many rows as its height takes, and at least one")
        func headerRows() {
            #expect(FloorPlacement.headerRows(edge: 22, height: 44) == 2)
            #expect(FloorPlacement.headerRows(edge: 22, height: 45) == 3)
            #expect(FloorPlacement.headerRows(edge: 100, height: 10) == 1)
            #expect(FloorPlacement.headerRows(edge: 0, height: 44) == 44)
        }

        // MARK: Layout

        @Test("an empty folder lays out nothing")
        func emptyLayout() {
            let layout = FloorLayout(focus: treeNode(root: "/r", []), area: area)
            #expect(layout.isEmpty)
            #expect(layout.regions.isEmpty && layout.leaves.isEmpty)
        }

        @Test("a zero-sized window lays out no grid and no blocks instead of failing")
        func zeroArea() {
            let layout = FloorLayout(focus: floorTree(), area: .zero)
            #expect(layout.columns == 0 && layout.rows == 0)
            #expect(layout.regions.isEmpty && layout.leaves.isEmpty)
            #expect(layout.hit(CGPoint(x: 1, y: 1)) == nil)
        }

        @Test("the grid spans the area exactly and holds at least every tile")
        func gridSpansArea() {
            let layout = FloorLayout(focus: floorTree(), area: area)
            #expect(layout.size == area)
            #expect(abs(layout.cellWidth * CGFloat(layout.columns) - area.width) < 0.001)
            #expect(abs(layout.cellHeight * CGFloat(layout.rows) - area.height) < 0.001)
            #expect(layout.columns * layout.rows >= layout.tileCount)
            #expect((FloorStyle.minTiles...FloorStyle.maxTiles).contains(layout.tileCount))
        }

        @Test("regions never overlap and stay inside the grid")
        func regionsDoNotOverlap() {
            let layout = FloorLayout(focus: floorTree(), area: area)
            let grid = FloorCells(col: 0, row: 0, cols: layout.columns, rows: layout.rows)
            for (i, a) in layout.regions.enumerated() {
                #expect(a.cells.col >= 0 && a.cells.row >= 0)
                #expect(a.cells.col + a.cells.cols <= grid.cols && a.cells.row + a.cells.rows <= grid.rows, "region \(i)")
                #expect(a.cells.area >= a.count, "region \(i) is too small for its cells")
                for (j, b) in layout.regions.enumerated() where j > i {
                    let overlap = a.cells.col < b.cells.col + b.cells.cols && b.cells.col < a.cells.col + a.cells.cols
                        && a.cells.row < b.cells.row + b.cells.rows && b.cells.row < a.cells.row + a.cells.rows
                    #expect(!overlap, "regions \(i) and \(j) overlap")
                }
            }
        }

        @Test("children sit inside their region below its header, do not overlap and fit their cells")
        func childrenInsideRegions() {
            let layout = FloorLayout(focus: floorTree(), area: area)
            #expect(layout.regions.contains { $0.isSubdivided }, "the fixture should subdivide at least one region")
            for (ri, region) in layout.regions.enumerated() where region.isSubdivided {
                let kids = region.leaves.map { layout.leaves[$0] }
                for (a, leaf) in kids.enumerated() {
                    let c = leaf.cells
                    #expect(c.col >= region.cells.col && c.col + c.cols <= region.cells.col + region.cells.cols, "region \(ri) leaf \(a)")
                    #expect(c.row >= region.cells.row + region.headerRows && c.row + c.rows <= region.cells.row + region.cells.rows, "region \(ri) leaf \(a)")
                    #expect(leaf.count <= c.area, "region \(ri) leaf \(a) has \(leaf.count) tiles in \(c.area) cells")
                    for (b, other) in kids.enumerated() where b > a {
                        let o = other.cells
                        let overlap = c.col < o.col + o.cols && o.col < c.col + c.cols && c.row < o.row + o.rows && o.row < c.row + c.rows
                        #expect(!overlap, "region \(ri) leaves \(a) and \(b) overlap")
                    }
                }
            }
        }

        @Test("every drawn rectangle lies inside the area")
        func rectsInsideBounds() {
            let layout = FloorLayout(focus: floorTree(), area: area)
            let bounds = CGRect(origin: .zero, size: area).insetBy(dx: -0.01, dy: -0.01)
            for region in layout.regions { #expect(bounds.contains(region.rect), "\(region.displayName)") }
            for leaf in layout.leaves where leaf.rect != .zero { #expect(bounds.contains(leaf.rect), "\(leaf.displayName)") }
        }

        @Test("the sizes on the floor add up to what is in the folder")
        func bytesAreAccountedFor() {
            let focus = floorTree()
            let layout = FloorLayout(focus: focus, area: area)
            #expect(layout.regions.reduce(0) { $0 + $1.size } == focus.children.reduce(0) { $0 + $1.size })
        }

        @Test("the same tree and size always lay out the same way")
        func deterministic() {
            let focus = floorTree()
            let a = FloorLayout(focus: focus, area: area), b = FloorLayout(focus: focus, area: area)
            #expect(a.regions.map(\.cells) == b.regions.map(\.cells))
            #expect(a.leaves.map(\.cells) == b.leaves.map(\.cells))
            #expect(a.id != b.id)
        }

        @Test("a window of any ordinary size keeps the invariants")
        func sizes() {
            for size in [CGSize(width: 900, height: 600), CGSize(width: 1_280, height: 800), CGSize(width: 480, height: 720), CGSize(width: 2_000, height: 500)] {
                let layout = FloorLayout(focus: floorTree(), area: size)
                #expect(!layout.isEmpty, "\(size)")
                #expect(layout.regions.map(\.count).reduce(0, +) == layout.tileCount, "\(size)")
                #expect(layout.regions.allSatisfy { $0.cells.area >= $0.count }, "\(size)")
            }
        }

        @Test("hit-testing the middle of every region finds that region or one of its blocks")
        func hitTesting() {
            let layout = FloorLayout(focus: floorTree(), area: area)
            for (ri, region) in layout.regions.enumerated() {
                let point = CGPoint(x: region.rect.midX, y: region.rect.midY)
                switch layout.hit(point) {
                case .region(let r): #expect(r == ri)
                case .leaf(let l): #expect(region.leaves.contains(l), "region \(ri)")
                case nil: Issue.record("region \(ri) is not hit at its centre")
                }
            }
            #expect(layout.hit(CGPoint(x: -1, y: 5)) == nil)
            #expect(layout.hit(CGPoint(x: area.width + 5, y: 5)) == nil)
        }

        @Test("a node is marked on the floor, and one outside the focus is not")
        func marks() {
            let focus = floorTree()
            let layout = FloorLayout(focus: focus, area: area)
            var used: [Int: Int] = [:]
            let swap = find("swapfile", in: focus)!
            if case .leaves(let leaves)? = layout.mark(for: swap, used: &used) {
                #expect(leaves.count == 1)
            } else {
                Issue.record("swapfile has no block of its own")
            }
            #expect(layout.mark(for: fileNode("stranger", 1), used: &used) == nil)
        }

        @Test("a long name is offered shortest-last, and a package also without its extension")
        func nameVariants() {
            let app = dirNode("Xcode.app", package: true)
            #expect(FloorLayout.nameVariants(app) == ["Xcode.app", "Xcode"])
            #expect(FloorLayout.nameVariants(fileNode("notes.txt", 1)) == ["notes.txt"])
        }
    }

    @MainActor
    @Suite("Ball: layout")
    struct BallTests {
        private func tree() -> FileNode {
            treeNode(root: "/r", [
                dirNode("a", [dirNode("a1", [fileNode("x", 300 * MB), fileNode("y", 100 * MB)]), fileNode("a2", 200 * MB)]),
                dirNode("b", [fileNode("z", 250 * MB), fileNode("w", 150 * MB)]),
                fileNode("c", 400 * MB),
            ])
        }

        @Test("the first ring covers the full circle, in order, without gaps or overlap")
        func firstRingCoversCircle() {
            let layout = SunburstLayout.build(focus: tree())
            let ring = layout.segmentsByDepth[0]
            #expect(ring.first?.startAngle == 0)
            let lastEnd: Double = ring.last?.endAngle ?? 0
            #expect(abs(lastEnd - 2 * .pi) < 1e-9)
            for (a, b) in zip(ring, ring.dropFirst()) { #expect(abs(a.endAngle - b.startAngle) < 1e-9) }
            // Split out: inside `#expect`, older compilers cannot type-check the whole expression.
            let covered: Double = ring.reduce(0) { $0 + ($1.endAngle - $1.startAngle) }
            #expect(abs(covered - 2 * .pi) < 1e-9)
        }

        @Test("a segment's angle is its share of its parent's, and the total adds to 2π")
        func anglesAreProportional() {
            let focus = tree()
            let layout = SunburstLayout.build(focus: focus)
            for segment in layout.segments where segment.depth == 0 {
                let span = segment.endAngle - segment.startAngle
                #expect(abs(span - 2 * .pi * Double(segment.displaySize) / Double(focus.size)) < 1e-9, "\(segment.displayName)")
            }
        }

        @Test("every child sits inside its parent's arc, one ring further out")
        func childrenInsideParentArcs() {
            let focus = tree()
            let layout = SunburstLayout.build(focus: focus)
            for segment in layout.segments where segment.depth > 0 {
                guard let parent = layout.byNodeID[ObjectIdentifier(segment.parentNode)] else {
                    Issue.record("\(segment.displayName) has no parent segment")
                    continue
                }
                #expect(segment.startAngle >= parent.startAngle - 1e-9 && segment.endAngle <= parent.endAngle + 1e-9, "\(segment.displayName)")
                #expect(segment.depth == parent.depth + 1)
                #expect(segment.innerFrac >= parent.outerFrac - 1e-9)
            }
        }

        @Test("rings are ordered from the centre outwards and fit between the centre disc and the edge")
        func ringGeometry() {
            let fractions = SunburstGeometry.ringFractions
            #expect(fractions.count == SunburstConstants.maxRings)
            #expect(fractions.first?.inner == SunburstConstants.centerFraction)
            #expect(abs((fractions.last?.outer ?? 0) - 1) < 1e-9)
            for (a, b) in zip(fractions, fractions.dropFirst()) { #expect(abs(a.outer - b.inner) < 1e-9) }
            #expect(fractions.allSatisfy { $0.outer > $0.inner })
            let widths = fractions.map { $0.outer - $0.inner }
            #expect(widths == widths.sorted(by: >), "each ring is narrower than the one inside it")
        }

        @Test("slivers under the minimum angle are merged into one 'Everything else' wedge that fills the rest of the ring")
        func smallSegmentsMerge() throws {
            let kids = [fileNode("big", 1_000_000)] + (0..<50).map { fileNode("t\($0)", 1) }
            let focus = treeNode(root: "/r", kids)
            let layout = SunburstLayout.build(focus: focus)
            let ring = layout.segmentsByDepth[0]
            let other = try #require(ring.last)
            #expect(other.isOther && other.displayName == "Everything else")
            #expect(other.otherCount == 50)
            #expect(other.displaySize == 50)
            #expect(abs(other.endAngle - 2 * .pi) < 1e-9)
            #expect(ring.filter(\.isOther).count == 1)
        }

        @Test("an empty or zero-sized folder has no segments")
        func emptyFocus() {
            #expect(SunburstLayout.build(focus: treeNode(root: "/r", [])).segments.isEmpty)
            #expect(SunburstLayout.build(focus: treeNode(root: "/r", [fileNode("z", 0)])).segments.isEmpty)
        }

        @Test("no ring is drawn beyond the maximum depth")
        func depthIsCapped() {
            var node = fileNode("leaf", 100)
            for i in 0..<(SunburstConstants.maxRings + 4) { node = dirNode("d\(i)", [node]) }
            let layout = SunburstLayout.build(focus: treeNode(root: "/r", [node]))
            #expect(layout.segments.map(\.depth).max() == SunburstConstants.maxRings - 1)
        }

        @Test("segments are found by their node and by their key")
        func lookups() {
            let focus = tree()
            let layout = SunburstLayout.build(focus: focus)
            let c = find("c", in: focus)!
            let segment = layout.byNodeID[ObjectIdentifier(c)]
            #expect(segment?.node === c)
            #expect(segment.flatMap { layout.byKey[$0.key] }?.node === c)
        }
    }
}
