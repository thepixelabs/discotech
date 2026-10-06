import Darwin
import Foundation

/// Confirms, right before something is moved to the Trash, that its path still
/// refers to the item that was scanned. The tree can be minutes or hours old: a
/// folder may have been renamed, replaced, or swapped for a symlink since, and
/// trashing by path alone would then hit the wrong thing.
enum TrashCheck {
    /// nil when `node` is still exactly what was scanned and may be trashed;
    /// otherwise a short, user-facing reason to refuse.
    static func refusal(for node: FileNode) -> String? {
        let chain = node.ancestry
        guard chain.count >= 2, let root = chain.first else {
            return "The scanned folder itself can’t be moved to the Trash."
        }
        let changed = "It changed since the scan. Rescan, then try again."

        // Names come from our own scan, but refuse anything that could step outside
        // the tree if joined into a path.
        for component in chain.dropFirst() {
            let name = component.name
            if name.isEmpty || name == "." || name == ".." || name.contains("/") || name.contains("\0") {
                return changed
            }
        }

        // Walk down from the scan root one directory at a time without following
        // symlinks, checking each directory is the one we scanned. The root itself may
        // be a symlink the person chose deliberately, as in the scanner.
        var fd = open(root.name, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { return changed }
        defer { close(fd) }
        guard matches(fd: fd, node: root) else { return changed }

        for directory in chain.dropFirst().dropLast() {
            let next = openat(fd, directory.name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard next >= 0 else { return changed }
            close(fd)
            fd = next
            guard matches(fd: fd, node: directory) else { return changed }
        }

        var info = stat()
        guard fstatat(fd, node.name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            return "It’s no longer there. Rescan to update."
        }
        guard UInt64(info.st_ino) == node.fileID, info.st_dev == node.deviceID else { return changed }
        let isDirectory = (info.st_mode & S_IFMT) == S_IFDIR
        guard isDirectory == node.isDirectory else { return changed }
        // A regular file that grew or shrank is still "the same" inode, but the size
        // the person agreed to free is wrong. Hard-link secondaries carry no size.
        if (info.st_mode & S_IFMT) == S_IFREG, node.hardLink != .secondary,
           Int64(info.st_blocks) * 512 != node.size {
            return "Its size changed since the scan. Rescan, then try again."
        }

        // File flags (SIP, locked) can change after the cached safety lookup.
        return Safety.protectionReasonUncached(forPath: node.path)
    }

    private static func matches(fd: Int32, node: FileNode) -> Bool {
        var info = stat()
        guard fstat(fd, &info) == 0 else { return false }
        return UInt64(info.st_ino) == node.fileID && info.st_dev == node.deviceID
    }
}

/// Hard links make "how much space does trashing this free" subtle: the data is
/// released only when every name for it is gone, and the scan credits its size to
/// just one of those names (the primary). This index finds all names per inode.
struct HardLinkIndex {
    private var links: [UInt64: [FileNode]] = [:]

    init(root: FileNode) {
        var stack = [root]
        while let node = stack.popLast() {
            if node.hardLink != .none {
                links[key(node), default: []].append(node)
            }
            stack.append(contentsOf: node.children)
        }
    }

    var isEmpty: Bool { links.isEmpty }

    /// Bytes actually released if every node in `roots` (and everything inside them)
    /// goes to the Trash: their sizes, minus hard-linked data that some name outside
    /// `roots` still keeps alive.
    func reclaimable(_ roots: [FileNode]) -> Int64 {
        let total = roots.reduce(Int64(0)) { $0 + $1.size }
        guard !links.isEmpty else { return total }
        let removed = Set(roots.map(ObjectIdentifier.init))
        var kept: Int64 = 0
        for names in links.values {
            guard let primary = names.first(where: { $0.hardLink == .primary }),
                  Self.isInside(primary, removed) else { continue }
            if names.contains(where: { !Self.isInside($0, removed) }) { kept += primary.size }
        }
        return total - kept
    }

    /// Call before `trashed` leaves the tree: moves the size credit of any primary
    /// inside it to a surviving name elsewhere, so totals keep matching the disk.
    mutating func transferCredit(awayFrom trashed: FileNode) {
        let removed: Set<ObjectIdentifier> = [ObjectIdentifier(trashed)]
        for (id, names) in links {
            let survivors = names.filter { !Self.isInside($0, removed) }
            guard survivors.count != names.count else { continue }
            links[id] = survivors.isEmpty ? nil : survivors
            guard let primary = names.first(where: { $0.hardLink == .primary }),
                  Self.isInside(primary, removed), let heir = survivors.first else { continue }
            heir.hardLink = .primary
            var n: FileNode? = heir
            while let cur = n {
                cur.size += primary.size
                cur.fileCount += primary.fileCount
                cur.parent?.children.sort { $0.size > $1.size }
                n = cur.parent
            }
        }
    }

    private func key(_ node: FileNode) -> UInt64 {
        // Inode numbers are per device; mix the device in (scans stay on one device,
        // so collisions here are only theoretical).
        node.fileID ^ (UInt64(UInt32(bitPattern: node.deviceID)) << 48)
    }

    private static func isInside(_ node: FileNode, _ roots: Set<ObjectIdentifier>) -> Bool {
        var n: FileNode? = node
        while let cur = n {
            if roots.contains(ObjectIdentifier(cur)) { return true }
            n = cur.parent
        }
        return false
    }
}
