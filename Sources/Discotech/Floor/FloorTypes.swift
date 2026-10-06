import AppKit

/// A block of whole grid cells: column and row of its top-left cell, and its size.
struct FloorCells: Equatable {
    var col: Int, row: Int, cols: Int, rows: Int
    static let zero = FloorCells(col: 0, row: 0, cols: 0, rows: 0)
    var area: Int { max(0, cols) * max(0, rows) }
    var isEmpty: Bool { cols <= 0 || rows <= 0 }

    func contains(col c: Int, row r: Int) -> Bool {
        c >= col && c < col + cols && r >= row && r < row + rows
    }

    /// True when the two blocks share part of an edge (corners alone don't count).
    func touches(_ o: FloorCells) -> Bool {
        let xOverlap = min(col + cols, o.col + o.cols) - max(col, o.col)
        let yOverlap = min(row + rows, o.row + o.rows) - max(row, o.row)
        if xOverlap > 0, row + rows == o.row || o.row + o.rows == row { return true }
        if yOverlap > 0, col + cols == o.col || o.col + o.cols == col { return true }
        return false
    }
}

/// One coloured block on the floor: a real item, a synthetic Free/Purgeable/Unseen node,
/// or an "Everything else" block standing in for a folder's many small children.
struct FloorLeaf {
    /// `nil` for an "Everything else" block.
    let node: FileNode?
    /// The folder whose small children an "Everything else" block stands for.
    let bucketParent: FileNode?
    let bucketCount: Int
    let size: Int64
    /// Index into `FloorLayout.regions`.
    let region: Int
    /// 0 = the region itself (drawn flat), 1 = a child inside a region.
    let depth: Int
    /// Cells this leaf is worth (its damped share of its parent's, so siblings add up).
    let count: Int
    /// The cells it owns (`count <= cells.area`).
    var cells: FloorCells = .zero
    /// Its colour (`Palette.paint`); `nil` for synthetic and "Everything else" blocks.
    var paint: Palette.Paint?
    /// Resting rectangle, in points, top-down from the grid's top-left corner.
    var rect: CGRect = .zero

    var isOther: Bool { node == nil }
    var kind: FileNode.Kind { node?.kind ?? .item }
    var isFile: Bool { !(node?.isDirectory ?? true) }
    var displayName: String { nameCandidates[0] }

    /// Label text, longest first ("431 smaller items" → "431 items").
    var nameCandidates: [String] {
        if let node { return FloorLayout.nameVariants(node) }
        return bucketCount == 1 ? ["1 smaller item"] : ["\(bucketCount) smaller items", "\(bucketCount) items"]
    }
}

/// A direct child of the focus (or the focus's own "Everything else"): one rounded
/// rectangle on the floor. Large folders show their children inside, under a header
/// strip that carries the region's name.
struct FloorRegion {
    let node: FileNode?
    /// Folders the split passed straight through because each was nearly all of its
    /// parent (/Users → /Users/you), outermost first. Named in the header.
    let passThrough: [FileNode]
    let size: Int64
    let count: Int
    var leaves: Range<Int> = 0..<0
    var cells: FloorCells = .zero
    /// Rows of cells given to the header strip (0 = drawn flat, no children).
    var headerRows = 0
    var rect: CGRect = .zero
    var headerRect: CGRect = .zero
    /// Its colour (`Palette.paint`); `nil` for synthetic and "Everything else".
    var paint: Palette.Paint?

    var isSubdivided: Bool { headerRows > 0 }
    var kind: FileNode.Kind { node?.kind ?? .item }
    var isOther: Bool { node == nil }
    var displayName: String { nameCandidates[0] }

    /// Label text, longest first: the whole pass-through chain ("Users › you"), then
    /// its ends ("a › … › d"), then the innermost folder.
    var nameCandidates: [String] {
        guard let node else { return ["Everything else"] }
        let chain = ([node] + (isSubdivided ? passThrough : [])).map(FloorLayout.displayName)
        guard chain.count > 1 else { return FloorLayout.nameVariants(node) }
        var out = [chain.joined(separator: " › ")]
        if chain.count > 2 { out.append("\(chain[0]) › … › \(chain[chain.count - 1])") }
        out.append(chain[chain.count - 1])
        return out
    }
}

/// Where a node sits on the floor, for hover, emphasis, selection and the Crate.
enum FloorMark {
    /// Whole regions (the focus itself or one of its ancestors marks every region).
    case regions([Int])
    /// Whole leaves (a pass-through folder is several leaves).
    case leaves([Int])
    /// Something too small for its own block: `count` cells' worth of leaf `leaf`,
    /// starting at cell `first` of that leaf (cells run row by row from its top-left).
    case partial(leaf: Int, first: Int, count: Int)
}

/// What the pointer is over.
enum FloorHit: Equatable {
    case region(Int) // a subdivided region's header strip
    case leaf(Int)
}
