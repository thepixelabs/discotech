import Foundation

/// One file or directory in a scanned tree.
///
/// Built off the main thread by `Scanner`, then handed to `AppState` and only
/// read or mutated on the main actor afterwards. Reference type so the tree can
/// hold millions of nodes without copying, and so views can use identity.
final class FileNode: Identifiable, @unchecked Sendable {
    /// Real files/folders are `.item`. The others are synthetic nodes added after a
    /// volume scan to account for space no file owns; they have no real path and
    /// must never be revealed, opened, previewed or put in the Crate.
    enum Kind: Sendable {
        case item
        case freeSpace   // available to apps right now
        case purgeable   // counted as used, but macOS can reclaim it on demand
        case hidden      // used space the scan couldn't attribute to any file
        case snapshot    // one APFS local snapshot (child of `.hidden`)
    }

    /// Whether this file shares its data with other names (a hard link).
    enum HardLink: UInt8, Sendable {
        case none
        /// Carries the size for its inode; other links show 0 bytes.
        case primary
        /// Another name for data already counted on the primary.
        case secondary
    }

    let name: String
    let kind: Kind
    /// Inode number and device at scan time. Used to confirm, right before acting
    /// on a node, that the path still refers to the same item that was scanned.
    var fileID: UInt64 = 0
    var deviceID: Int32 = 0
    var hardLink: HardLink = .none
    let isDirectory: Bool
    /// Bundles (.app, .photoslibrary, …) are directories but shown as a single item.
    let isPackage: Bool
    /// Memoised `ContentKind` raw value (0 = not worked out yet); see `contentKind`.
    /// Main actor only. Cleared up the parent chain by `removeFromParent`.
    var contentKindCache: UInt8 = 0
    weak var parent: FileNode?

    /// Allocated bytes on disk. For directories: the sum of all descendants.
    var size: Int64
    /// Number of regular files at or below this node (1 for a file).
    var fileCount: Int
    /// Sorted by `size`, largest first. Empty for files.
    var children: [FileNode]

    init(name: String, isDirectory: Bool, isPackage: Bool = false, size: Int64 = 0,
         fileCount: Int = 0, children: [FileNode] = [], parent: FileNode? = nil, kind: Kind = .item) {
        self.name = name
        self.kind = kind
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.size = size
        self.fileCount = fileCount
        self.children = children
        self.parent = parent
    }

    /// Absolute path, rebuilt from the parent chain. The root node's `name` is its full path.
    var path: String {
        guard let parent else { return name }
        let p = parent.path
        return p.hasSuffix("/") ? p + name : p + "/" + name
    }

    var url: URL { URL(fileURLWithPath: path, isDirectory: isDirectory) }

    /// True for free/purgeable/hidden/snapshot accounting nodes (no file on disk).
    var isSynthetic: Bool { kind != .item }

    /// Root first, self last.
    var ancestry: [FileNode] {
        var chain: [FileNode] = []
        var n: FileNode? = self
        while let cur = n { chain.append(cur); n = cur.parent }
        return chain.reversed()
    }

    var depth: Int {
        var d = 0
        var n = parent
        while let cur = n { d += 1; n = cur.parent }
        return d
    }

    func isDescendant(of other: FileNode) -> Bool {
        var n: FileNode? = self
        while let cur = n { if cur === other { return true }; n = cur.parent }
        return false
    }

    /// Detaches this node from its parent and subtracts its size/fileCount up the chain.
    func removeFromParent() {
        guard let parent else { return }
        parent.children.removeAll { $0 === self }
        var n: FileNode? = parent
        while let cur = n {
            cur.size -= size
            cur.fileCount -= fileCount
            cur.contentKindCache = 0 // what dominates a folder can change with its content
            n = cur.parent
        }
        self.parent = nil
    }

    /// Recomputes size/fileCount from children and sorts them, bottom-up.
    func finalize() {
        guard isDirectory else { return }
        var s: Int64 = 0, c = 0
        for child in children {
            child.finalize()
            s += child.size
            c += child.fileCount
        }
        size += s
        fileCount += c
        children.sort { $0.size > $1.size }
    }
}

extension FileNode: Hashable {
    static func == (a: FileNode, b: FileNode) -> Bool { a === b }
    func hash(into h: inout Hasher) { h.combine(ObjectIdentifier(self)) }
}

/// Snapshot of scan progress, delivered periodically to the UI.
struct ScanProgress: Sendable, Equatable {
    var filesScanned: Int = 0
    var directoriesScanned: Int = 0
    var bytesScanned: Int64 = 0
    var currentPath: String = ""
}

enum ByteFormat {
    private static let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false // "0 bytes", not "Zero KB"
        return f
    }()

    static func string(_ bytes: Int64) -> String { formatter.string(fromByteCount: bytes) }
}
