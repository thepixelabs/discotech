import Darwin
import Foundation
import Testing
@testable import Discotech

/// Hard-link accounting runs on in-memory trees. `TrashCheck` runs against real files in a
/// temp folder, scanned with the real scanner. Nothing here moves anything to the Trash:
/// `TrashCheck.refusal` only reads.
@Suite("HardLinkIndex")
struct HardLinkIndexTests {
    /// dirA holds the primary name (100 bytes), dirB a secondary name, dirC an unrelated file.
    private func twoNames() -> (root: FileNode, a: FileNode, b: FileNode, primary: FileNode, secondary: FileNode) {
        let primary = fileNode("data", 100, hardLink: .primary, inode: 7)
        let secondary = fileNode("alias", 0, hardLink: .secondary, inode: 7)
        let a = dirNode("a", [primary]), b = dirNode("b", [secondary])
        return (treeNode(root: "/r", [a, b, dirNode("c", [fileNode("plain", 40)])]), a, b, primary, secondary)
    }

    @Test("without hard links, reclaimable is the plain sum of the sizes")
    func noLinks() {
        let root = treeNode(root: "/r", [fileNode("x", 10), fileNode("y", 20)])
        let index = HardLinkIndex(root: root)
        #expect(index.isEmpty)
        #expect(index.reclaimable(root.children) == 30)
    }

    @Test("data is released when every name for it is in the Crate")
    func allNamesRemoved() {
        let t = twoNames()
        #expect(HardLinkIndex(root: t.root).reclaimable([t.a, t.b]) == 100)
    }

    @Test("data is not released while a name outside the Crate keeps it")
    func nameOutsideKeepsData() {
        let t = twoNames()
        #expect(HardLinkIndex(root: t.root).reclaimable([t.a]) == 0)
    }

    @Test("removing only a secondary name releases nothing")
    func onlySecondaryRemoved() {
        let t = twoNames()
        #expect(HardLinkIndex(root: t.root).reclaimable([t.b]) == 0)
    }

    @Test("unrelated items in the Crate still count in full next to a kept hard link")
    func unrelatedItemsCount() {
        let t = twoNames()
        let plain = find("c", in: t.root)!
        #expect(HardLinkIndex(root: t.root).reclaimable([t.a, plain]) == 40)
    }

    @Test("with three names, removing two of them still keeps the data")
    func threeNames() {
        let p = fileNode("p", 90, hardLink: .primary, inode: 5)
        let s1 = fileNode("s1", 0, hardLink: .secondary, inode: 5)
        let s2 = fileNode("s2", 0, hardLink: .secondary, inode: 5)
        let root = treeNode(root: "/r", [dirNode("x", [p]), dirNode("y", [s1]), dirNode("z", [s2])])
        let index = HardLinkIndex(root: root)
        #expect(index.reclaimable([find("x", in: root)!, find("y", in: root)!]) == 0)
        #expect(index.reclaimable(root.children) == 90)
    }

    @Test("names on different devices with the same inode are different files")
    func deviceIsPartOfTheKey() {
        let p1 = fileNode("p1", 50, hardLink: .primary, inode: 3, device: 1)
        let p2 = fileNode("p2", 70, hardLink: .primary, inode: 3, device: 2)
        let root = treeNode(root: "/r", [dirNode("a", [p1]), dirNode("b", [p2])])
        #expect(HardLinkIndex(root: root).reclaimable([find("a", in: root)!]) == 50)
    }

    @Test("moving the credit hands the primary's size to a surviving name and keeps totals equal to the disk")
    func transferCredit() {
        let t = twoNames()
        var index = HardLinkIndex(root: t.root)
        let before = (t.root.size, t.root.fileCount)
        index.transferCredit(awayFrom: t.primary)
        t.primary.removeFromParent()
        #expect(t.secondary.hardLink == .primary)
        #expect(t.secondary.size == 100)
        #expect(t.b.size == 100)
        #expect((t.root.size, t.root.fileCount) == before)
        #expect(isConsistent(t.root, checkOrder: false))
    }

    @Test("after the credit moves, trashing the new primary alone no longer frees anything it shares, and trashing the last name frees it")
    func transferThenReclaim() {
        let t = twoNames()
        var index = HardLinkIndex(root: t.root)
        index.transferCredit(awayFrom: t.primary)
        t.primary.removeFromParent()
        #expect(index.reclaimable([t.b]) == 100)
    }

    @Test("moving the credit re-sorts the heir's folder so it stays largest first")
    func transferCreditResorts() {
        let primary = fileNode("data", 500, hardLink: .primary, inode: 1)
        let alias = fileNode("alias", 0, hardLink: .secondary, inode: 1)
        let root = treeNode(root: "/r", [dirNode("a", [primary]), dirNode("b", [alias, fileNode("small", 10)])])
        var index = HardLinkIndex(root: root)
        index.transferCredit(awayFrom: primary)
        #expect(find("b", in: root)!.children.map(\.name) == ["alias", "small"])
    }

    @Test("trashing a plain item changes nothing in the index")
    func transferForUnrelatedNode() {
        let t = twoNames()
        var index = HardLinkIndex(root: t.root)
        let plain = find("c", in: t.root)!
        index.transferCredit(awayFrom: plain)
        #expect(t.primary.hardLink == .primary)
        #expect(index.reclaimable([t.a, t.b]) == 100)
    }
}

@Suite("TrashCheck")
struct TrashCheckTests {
    private static let changed = "It changed since the scan. Rescan, then try again."

    private func scanned(_ tree: TempTree) async throws -> FileNode {
        try tree.file("keep.txt", bytes: 20_000)
        try tree.file("docs/note.txt", bytes: 5_000)
        try tree.file("docs/inner/deep.bin", bytes: 9_000)
        return try await tree.scan()
    }

    @Test("an item that is exactly what was scanned is accepted")
    func unchangedItemIsAccepted() async throws {
        try await withTempTree { tree in
            let root = try await scanned(tree)
            for path in ["keep.txt", "docs", "docs/note.txt", "docs/inner", "docs/inner/deep.bin"] {
                #expect(TrashCheck.refusal(for: find(path, in: root)!) == nil, "\(path)")
            }
        }
    }

    @Test("the scanned folder itself is always refused")
    func rootIsRefused() async throws {
        try await withTempTree { tree in
            let root = try await scanned(tree)
            #expect(TrashCheck.refusal(for: root) == "The scanned folder itself can’t be moved to the Trash.")
        }
    }

    @Test("an item deleted since the scan is reported as gone")
    func deletedItem() async throws {
        try await withTempTree { tree in
            let root = try await scanned(tree)
            try tree.remove("keep.txt")
            #expect(TrashCheck.refusal(for: find("keep.txt", in: root)!) == "It’s no longer there. Rescan to update.")
        }
    }

    @Test("a file deleted and recreated under the same name is a different file and is refused")
    func replacedFile() async throws {
        try await withTempTree { tree in
            let root = try await scanned(tree)
            try tree.remove("keep.txt")
            try tree.file("keep.txt", bytes: 20_000)
            #expect(TrashCheck.refusal(for: find("keep.txt", in: root)!) == Self.changed)
        }
    }

    @Test("a folder replaced by another folder of the same name is refused")
    func replacedFolder() async throws {
        try await withTempTree { tree in
            let root = try await scanned(tree)
            try tree.remove("docs")
            try tree.dir("docs")
            #expect(TrashCheck.refusal(for: find("docs", in: root)!) == Self.changed)
        }
    }

    @Test("a folder swapped for a symlink is refused, for the folder and for anything below it")
    func folderSwappedForSymlink() async throws {
        try await withTempTree { tree in
            let root = try await scanned(tree)
            try tree.dir("elsewhere")
            try tree.remove("docs/inner")
            try tree.symlink("docs/inner", to: tree.url("elsewhere").path)
            #expect(TrashCheck.refusal(for: find("docs/inner", in: root)!) == Self.changed)
            #expect(TrashCheck.refusal(for: find("docs/inner/deep.bin", in: root)!) == Self.changed)
        }
    }

    @Test("a file swapped for a symlink to the same size is refused")
    func fileSwappedForSymlink() async throws {
        try await withTempTree { tree in
            let root = try await scanned(tree)
            try tree.remove("keep.txt")
            try tree.symlink("keep.txt", to: tree.url("docs/note.txt").path)
            #expect(TrashCheck.refusal(for: find("keep.txt", in: root)!) == Self.changed)
        }
    }

    @Test("a file that grew since the scan is refused for its size")
    func grownFile() async throws {
        try await withTempTree { tree in
            let root = try await scanned(tree)
            try tree.append("keep.txt", bytes: 100_000)
            #expect(TrashCheck.refusal(for: find("keep.txt", in: root)!) == "Its size changed since the scan. Rescan, then try again.")
        }
    }

    @Test("a name that could climb out of the tree is refused before any disk access",
          arguments: ["", ".", "..", "a/b", "a\0b"])
    func dangerousNames(_ name: String) {
        let root = treeNode(root: "/discotech-test-root-that-does-not-exist", [dirNode("d", [fileNode(name, 10)])])
        let victim = root.children[0].children[0]
        #expect(TrashCheck.refusal(for: victim) == Self.changed)
    }

    @Test("an item locked after the scan is refused by the final flag check")
    func lockedAfterScan() async throws {
        try await withTempTree { tree in
            let root = try await scanned(tree)
            tree.lock("keep.txt")
            #expect(TrashCheck.refusal(for: find("keep.txt", in: root)!) == "This item is locked, so it can’t be moved to the Trash.")
        }
    }

    @Test("a hard link's secondary name is accepted although it carries no size")
    func secondaryHardLinkSkipsSizeCheck() async throws {
        try await withTempTree { tree in
            try tree.file("original.bin", bytes: 30_000)
            try tree.hardLink("alias.bin", to: "original.bin")
            let root = try await tree.scan()
            let secondary = try #require(root.children.first { $0.hardLink == .secondary })
            #expect(secondary.size == 0)
            #expect(TrashCheck.refusal(for: secondary) == nil)
        }
    }
}
