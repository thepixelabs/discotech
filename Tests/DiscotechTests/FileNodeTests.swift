import Foundation
import Testing
@testable import Discotech

@Suite("FileNode")
struct FileNodeTests {
    private func sample() -> (root: FileNode, docs: FileNode, a: FileNode, b: FileNode, deep: FileNode) {
        let a = fileNode("a.txt", 300)
        let b = fileNode("b.txt", 100)
        let deep = fileNode("deep.bin", 600)
        let docs = dirNode("docs", [a, b, dirNode("sub", [deep])])
        let root = treeNode(root: "/Volumes/Disk", [docs, fileNode("top.txt", 50)])
        return (root, docs, a, b, deep)
    }

    @Test("path joins the root's full path and each name with one slash")
    func path() {
        let s = sample()
        #expect(s.root.path == "/Volumes/Disk")
        #expect(s.deep.path == "/Volumes/Disk/docs/sub/deep.bin")
    }

    @Test("a root of / does not produce a double slash")
    func slashRootPath() {
        let root = treeNode(root: "/", [dirNode("Users", [fileNode("x", 1)])])
        #expect(find("Users/x", in: root)?.path == "/Users/x")
    }

    @Test("url marks a directory node as a directory")
    func url() {
        let s = sample()
        #expect(s.docs.url.hasDirectoryPath)
        #expect(!s.a.url.hasDirectoryPath)
        #expect(s.a.url.path == "/Volumes/Disk/docs/a.txt")
    }

    @Test("ancestry runs root first and self last, and depth counts the parents")
    func ancestryAndDepth() {
        let s = sample()
        #expect(s.deep.ancestry.map(\.name) == ["/Volumes/Disk", "docs", "sub", "deep.bin"])
        #expect(s.root.depth == 0)
        #expect(s.deep.depth == 3)
    }

    @Test("isDescendant is true for the node itself and its ancestors, false for siblings")
    func isDescendant() {
        let s = sample()
        #expect(s.deep.isDescendant(of: s.docs))
        #expect(s.docs.isDescendant(of: s.docs))
        #expect(!s.docs.isDescendant(of: s.deep))
        #expect(!s.a.isDescendant(of: s.b))
    }

    @Test("finalize rolls sizes and file counts up and sorts children largest first")
    func finalize() {
        let s = sample()
        #expect(s.root.size == 1050)
        #expect(s.root.fileCount == 4)
        #expect(s.docs.size == 1000)
        #expect(s.root.children.map(\.name) == ["docs", "top.txt"])
        #expect(s.docs.children.map(\.name) == ["sub", "a.txt", "b.txt"])
        #expect(isConsistent(s.root))
    }

    @Test("removeFromParent detaches the node and takes its size and count off every ancestor")
    func removeFromParent() {
        let s = sample()
        s.deep.removeFromParent()
        #expect(s.deep.parent == nil)
        #expect(s.root.size == 450)
        #expect(s.docs.size == 400)
        #expect(s.root.fileCount == 3)
        #expect(!(find("docs/sub", in: s.root)?.children.contains { $0 === s.deep } ?? true))
        #expect(isConsistent(s.root, checkOrder: false))
    }

    @Test("after a removal every ancestor's children are still sorted largest first")
    func removalKeepsAncestorsSorted() {
        let s = sample()
        s.deep.removeFromParent() // docs/sub drops from 600 to 0, below a.txt (300) and b.txt (100)
        withKnownIssue("FileNode.removeFromParent shrinks ancestors but never re-sorts their parents' children, so the order goes stale until a rescan") {
            #expect(isConsistent(s.root))
        }
    }

    @Test("removeFromParent on a root does nothing")
    func removeRoot() {
        let s = sample()
        s.root.removeFromParent()
        #expect(s.root.size == 1050)
    }

    @Test("removing a node clears the memoised content kind of every ancestor")
    func removeClearsKindCache() {
        let root = treeNode(root: "/r", [dirNode("d", [fileNode("a.mp4", 900), fileNode("b.swift", 100)])])
        let folder = find("d", in: root)!
        #expect(folder.contentKind == .media)
        #expect(folder.contentKindCache != 0)
        find("d/a.mp4", in: root)!.removeFromParent()
        #expect(folder.contentKindCache == 0)
        #expect(folder.contentKind == .code)
    }

    @Test("nodes are equal only when they are the same object")
    func identity() {
        let one = fileNode("same", 1), two = fileNode("same", 1)
        #expect(one == one)
        #expect(one != two)
        #expect(Set([one, two]).count == 2)
    }

    @Test("only Free, Purgeable, Unseen and snapshot nodes are synthetic")
    func synthetic() {
        for kind in [FileNode.Kind.freeSpace, .purgeable, .hidden, .snapshot] {
            #expect(FileNode(name: "x", isDirectory: false, kind: kind).isSynthetic)
        }
        #expect(!FileNode(name: "x", isDirectory: false).isSynthetic)
    }
}

@Suite("Formatting")
struct FormattingTests {
    @Test("Bytes spells zero and negative sizes as 0 KB")
    func bytesZero() {
        #expect(Bytes.string(0) == "0 KB")
        #expect(Bytes.string(-1) == "0 KB")
    }

    @Test("Bytes and ByteFormat agree for positive sizes")
    func bytesPositive() {
        for n: Int64 in [1, 999, 1_000, 1_500_000, 3 * GB] {
            #expect(Bytes.string(n) == ByteFormat.string(n))
        }
    }

    @Test("ByteFormat shows 0 as a number, never as a word")
    func byteFormatZero() {
        let text = ByteFormat.string(0)
        #expect(text.contains("0"))
        #expect(!text.lowercased().contains("zero"))
    }

    @Test("ByteFormat orders a kilobyte, megabyte and gigabyte by magnitude unit, using decimal (file) units")
    func byteFormatUnits() {
        // 1 GB in file style is 1,000,000,000 bytes, so it must not read as 1.07.
        let gigabyte = ByteFormat.string(1_000_000_000)
        #expect(gigabyte.hasPrefix("1"))
        #expect(!gigabyte.contains("1.07") && !gigabyte.contains("1,07"))
        #expect(ByteFormat.string(1_000) != ByteFormat.string(1_000_000))
    }

    @Test("Count.string groups digits without changing the number")
    func countString() {
        #expect(Count.string(1_234_567).filter(\.isNumber) == "1234567")
        #expect(Count.string(0).filter(\.isNumber) == "0")
    }

    @Test("Count.items and Count.files use the singular only for exactly one")
    func countPlurals() {
        #expect(Count.items(1) == "1 item")
        #expect(Count.items(0).hasSuffix(" items"))
        #expect(Count.items(2).hasSuffix(" items"))
        #expect(Count.files(1) == "1 file")
        #expect(Count.files(0).hasSuffix(" files"))
        #expect(Count.files(12).hasSuffix(" files"))
    }

    @Test("CrumbName names a child by its own name")
    func crumbChild() {
        let root = treeNode(root: "/Volumes/Disk", [dirNode("Projects", [fileNode("x", 1)])])
        #expect(CrumbName.of(find("Projects", in: root)!) == "Projects")
    }

    @Test("CrumbName names the scan root by its folder's display name, not its full path")
    func crumbRoot() async throws {
        try await withTempTree { tree in
            try tree.dir("Photos 2026")
            let root = treeNode(root: tree.url("Photos 2026").path, [])
            #expect(CrumbName.of(root) == "Photos 2026")
        }
    }

    @Test("PackageKind recognises bundle extensions in any case and ignores plain folders and dotfiles",
          arguments: [("Xcode.app", true), ("Thing.APP", true), ("Photos Library.photoslibrary", true),
                      ("notes.txt", false), ("app", false), (".app", false), ("name.", false), ("folder", false)])
    func packageKind(_ name: String, _ expected: Bool) {
        #expect(PackageKind.isPackage(name: name) == expected)
    }
}
