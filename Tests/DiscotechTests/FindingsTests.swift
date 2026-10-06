import Foundation
import Testing
@testable import Discotech

/// Findings runs on in-memory trees. Rules that are relative to the home folder use the
/// real `NSHomeDirectory()` path text (`treeUnderHome`); no file is created, and the only
/// disk access is `Safety`'s lstat on paths that do not exist.
@Suite("Findings: rule matching")
struct FindingsRuleTests {
    private func ids(_ findings: [Finding]) -> [String] { findings.map(\.id) }
    private func finding(_ id: String, in findings: [Finding]) -> Finding? { findings.first { $0.id == id } }
    private func names(_ finding: Finding?) -> [String] { finding?.nodes.map(\.name) ?? [] }

    private func project(_ name: String, _ entries: [FileNode]) -> FileNode {
        chain("Projects", dirNode(name, entries))
    }

    private func project(_ entries: [FileNode]) -> FileNode { project("app", entries) }

    // MARK: Marker-pair dev output

    @Test("node_modules next to a package.json is a Safe finding")
    func nodeModulesWithManifest() {
        let root = treeUnderHome([project([dirNode("node_modules", [fileNode("big.js", 200 * MB)]), fileNode("package.json", 1)])])
        let found = Findings.find(in: root)
        #expect(ids(found) == ["node-modules"])
        #expect(found.first?.tier == .safe)
        #expect(names(found.first) == ["node_modules"])
    }

    @Test("node_modules with no package.json beside it is left alone")
    func nodeModulesWithoutManifest() {
        let root = treeUnderHome([project([dirNode("node_modules", [fileNode("big.js", 200 * MB)]), fileNode("README.md", 1)])])
        #expect(Findings.find(in: root).isEmpty)
    }

    @Test("the marker may be spelled in any case")
    func markerIsCaseInsensitive() {
        let root = treeUnderHome([project([dirNode("target", [fileNode("a.rlib", 200 * MB)]), fileNode("Cargo.toml", 1)])])
        #expect(ids(Findings.find(in: root)) == ["rust-target"])
    }

    @Test("a Rust target folder needs Cargo.toml, a Maven one needs pom.xml, and a bare target is nothing")
    func targetFolderNeedsItsMarker() {
        let rust = treeUnderHome([project("r", [dirNode("target", [fileNode("a", 100 * MB)]), fileNode("Cargo.toml", 1)])])
        let maven = treeUnderHome([project("m", [dirNode("target", [fileNode("a", 100 * MB)]), fileNode("pom.xml", 1)])])
        let bare = treeUnderHome([project("b", [dirNode("target", [fileNode("a", 100 * MB)])])])
        #expect(ids(Findings.find(in: rust)) == ["rust-target"])
        #expect(ids(Findings.find(in: maven)) == ["maven-target"])
        #expect(Findings.find(in: bare).isEmpty)
    }

    @Test("__pycache__ matches on its name alone")
    func pycacheNeedsNoMarker() {
        let root = treeUnderHome([project([dirNode("__pycache__", [fileNode("m.pyc", 100 * MB)])])])
        #expect(ids(Findings.find(in: root)) == ["pycache"])
    }

    @Test("Unity's Library folder needs both Assets and ProjectSettings beside it")
    func unityNeedsEveryMarker() {
        let library = { dirNode("Library", [fileNode("cache", 200 * MB)]) }
        let both = treeUnderHome([project([library(), dirNode("Assets"), dirNode("ProjectSettings")])])
        let one = treeUnderHome([project([library(), dirNode("Assets")])])
        #expect(ids(Findings.find(in: both)) == ["unity-library"])
        #expect(Findings.find(in: one).isEmpty)
    }

    @Test("a project folder directly in the home folder is not matched (it is ~/.cache or ~/Library, not a project)")
    func homeFolderItselfIsNotAProject() {
        let root = treeUnderHome([dirNode(".cache", [fileNode("x", 200 * MB)]), fileNode("package.json", 1)])
        #expect(Findings.find(in: root).isEmpty)
    }

    @Test("a build folder inside a package bundle is not surfaced on its own")
    func nothingInsideABundle() {
        let bundle = dirNode("Tool.app", package: true, [dirNode("node_modules", [fileNode("x", 200 * MB)]), fileNode("package.json", 1)])
        #expect(Findings.find(in: treeUnderHome([project([bundle])])).isEmpty)
    }

    @Test("a matched folder is never walked into, so nested matches are not counted twice")
    func nestedMatchesAreNotDoubleCounted() {
        let inner = dirNode("pkg", [dirNode("node_modules", [fileNode("deep.js", 100 * MB)]), fileNode("package.json")])
        let outer = dirNode("node_modules", [inner, fileNode("top.js", 150 * MB)])
        let found = Findings.find(in: treeUnderHome([project([outer, fileNode("package.json")])]))
        #expect(names(finding("node-modules", in: found)) == ["node_modules"])
        #expect(finding("node-modules", in: found)?.totalSize == 250 * MB)
    }

    // MARK: Known folders

    @Test("a package-manager cache folder is one item, in the Safe tier")
    func packageCacheIsOneItem() {
        let root = treeUnderHome([chain("Library/Caches", dirNode("Homebrew", [fileNode("bottle.tar", 300 * MB)]))])
        let found = Findings.find(in: root)
        #expect(ids(found) == ["package-caches"])
        #expect(found.first?.tier == .safe)
    }

    @Test("each Xcode DerivedData project is its own item")
    func derivedDataChildrenAreItems() {
        let derived = dirNode("DerivedData", [dirNode("A-abc", [fileNode("x", 200 * MB)]), dirNode("B-def", [fileNode("y", 100 * MB)])])
        let found = Findings.find(in: treeUnderHome([chain("Library/Developer/Xcode", derived)]))
        #expect(names(finding("xcode-derived-data", in: found)) == ["A-abc", "B-def"])
    }

    @Test("Xcode archives and iPhone backups are Review, not Safe")
    func personalDataIsReviewTier() {
        let archives = chain("Library/Developer/Xcode", dirNode("Archives", [dirNode("2026-01-01", [fileNode("a", 200 * MB)])]))
        let backups = chain("Library/Application Support/MobileSync", dirNode("Backup", [dirNode("UDID", [fileNode("b", 200 * MB)])]))
        let found = Findings.find(in: treeUnderHome([archives, backups]))
        #expect(Set(ids(found)) == ["xcode-archives", "device-backups"])
        #expect(found.allSatisfy { $0.tier == .review })
    }

    @Test("only installers and archives in Downloads are listed, not other files")
    func downloadsOnlyListsInstallers() {
        let downloads = dirNode("Downloads", [fileNode("app.dmg", 300 * MB), fileNode("data.zip", 100 * MB), fileNode("notes.txt", 200 * MB)])
        let found = Findings.find(in: treeUnderHome([downloads]))
        #expect(names(finding("downloads-installers", in: found)) == ["app.dmg", "data.zip"])
    }

    @Test("a Chromium profile's cache folders are browser caches")
    func chromiumProfileCaches() {
        let profile = dirNode("Default", [dirNode("Cache", [fileNode("c", 200 * MB)]), dirNode("History", [fileNode("h", 5 * MB)])])
        let chrome = chain("Library/Application Support/Google", dirNode("Chrome", [profile]))
        let found = Findings.find(in: treeUnderHome([chrome]))
        #expect(names(finding("browser-caches", in: found)) == ["Cache"])
    }

    @Test("an app with Chromium's GPUCache signature gets its web caches listed")
    func appWebCaches() {
        let app = dirNode("SomeChatApp", [dirNode("GPUCache", [fileNode("g", 120 * MB)]), dirNode("Cache", [fileNode("c", 80 * MB)]), fileNode("settings.json", 1)])
        let found = Findings.find(in: treeUnderHome([chain("Library/Application Support", app)]))
        #expect(Set(names(finding("app-web-caches", in: found))) == ["GPUCache", "Cache"])
    }

    // MARK: Dedupe

    @Test("a folder inside a package cache is not also listed under the catch-all Caches rule")
    func claimedFolderIsNotListedTwice() {
        let caches = dirNode("Caches", [dirNode("Homebrew", [fileNode("a", 200 * MB)]), dirNode("com.example.app", [fileNode("b", 300 * MB)])])
        let found = Findings.find(in: treeUnderHome([chain("Library", caches)]))
        #expect(names(finding("package-caches", in: found)) == ["Homebrew"])
        #expect(names(finding("user-caches", in: found)) == ["com.example.app"])
    }

    @Test("a folder that holds a claimed cache is split into its other children")
    func holderOfClaimedNodeIsSplit() {
        let google = dirNode("Google", [dirNode("Chrome", [fileNode("c", 300 * MB)]), dirNode("Updater", [fileNode("u", 100 * MB)])])
        let caches = dirNode("Caches", [google])
        let found = Findings.find(in: treeUnderHome([chain("Library", caches)]))
        #expect(names(finding("browser-caches", in: found)) == ["Chrome"])
        #expect(names(finding("user-caches", in: found)) == ["Updater"])
    }

    @Test("no node is in two findings, and none sits inside another finding's node")
    func everyNodeAppearsOnce() {
        let home: [FileNode] = [
            chain("Library/Caches", dirNode("Homebrew", [fileNode("a", 200 * MB)])),
            chain("Library/Caches/Google", dirNode("Chrome", [fileNode("c", 200 * MB)])),
            chain("Library", dirNode("Caches", [dirNode("other", [fileNode("o", 200 * MB)])])),
            dirNode("Downloads", [fileNode("a.dmg", 600 * MB), fileNode("big.mov", 700 * MB)]),
            dirNode("Movies", [fileNode("film.mov", 800 * MB)]),
            project([dirNode("node_modules", [fileNode("n", 200 * MB)]), fileNode("package.json", 1), fileNode("huge.bin", 2 * GB)]),
        ]
        let all = Findings.find(in: treeUnderHome(home)).flatMap(\.nodes)
        #expect(Set(all.map(ObjectIdentifier.init)).count == all.count)
        for node in all {
            #expect(!all.contains { $0 !== node && node.isDescendant(of: $0) }, "\(node.path) is inside another finding")
        }
    }

    @Test("a file already in a named group is not repeated in Largest files or Disk images")
    func namedGroupBeatsCatchAll() {
        let downloads = dirNode("Downloads", [fileNode("huge.dmg", 2 * GB)])
        let found = Findings.find(in: treeUnderHome([downloads]))
        #expect(ids(found) == ["downloads-installers"])
    }

    // MARK: Extension and size rules

    @Test("videos count only in Movies, Downloads and Desktop, and only over 500 MB")
    func videosNeedMediaFolderAndSize() {
        let movies = dirNode("Movies", [fileNode("long.mov", 600 * MB), fileNode("short.mov", 400 * MB)])
        let elsewhere = project("clips", [fileNode("render.mp4", 700 * MB)])
        let found = Findings.find(in: treeUnderHome([movies, elsewhere]))
        #expect(names(finding("large-videos", in: found)) == ["long.mov"])
    }

    @Test("the largest-files group needs 1 GB and leaves out files that belong elsewhere")
    func largestFilesThreshold() {
        let found = Findings.find(in: treeUnderHome([project([fileNode("a.bin", 2 * GB), fileNode("b.bin", GB - 1)])]))
        #expect(names(finding("largest-files", in: found)) == ["a.bin"])
    }

    @Test("a disk image over 200 MB is listed, one under it is not")
    func diskImageThreshold() {
        let found = Findings.find(in: treeUnderHome([project([fileNode("a.iso", 300 * MB), fileNode("b.iso", 100 * MB)])]))
        #expect(names(finding("disk-images", in: found)) == ["a.iso"])
    }

    @Test("a hard link's secondary name never becomes a finding")
    func secondaryHardLinkIsIgnored() {
        let big = fileNode("copy.bin", 2 * GB, hardLink: .secondary, inode: 9)
        big.size = 2 * GB // a malformed secondary: still ignored
        #expect(Findings.find(in: treeUnderHome([project([big])])).isEmpty)
    }

    // MARK: Thresholds, ordering, totals

    @Test("a finding under 50 MB in total is hidden; exactly 50 MiB is shown")
    func minimumSize() {
        func tree(_ size: Int64) -> FileNode {
            treeUnderHome([project([dirNode("__pycache__", [fileNode("m.pyc", size)])])])
        }
        #expect(Findings.find(in: tree(Findings.minFindingSize - 1)).isEmpty)
        #expect(ids(Findings.find(in: tree(Findings.minFindingSize))) == ["pycache"])
    }

    @Test("a zero-byte folder is never a card")
    func zeroByteIsHidden() {
        #expect(Findings.find(in: treeUnderHome([project([dirNode("__pycache__"), dirNode("node_modules"), fileNode("package.json", 1)])])).isEmpty)
    }

    @Test("an empty tree has no findings")
    func emptyTree() {
        #expect(Findings.find(in: treeNode(root: "/", [])).isEmpty)
        #expect(Findings.find(in: treeNode(root: "/Volumes/Empty", [])).isEmpty)
    }

    @Test("cards are Safe before Review, and largest first within a tier")
    func ordering() {
        let home: [FileNode] = [
            project("a", [dirNode("__pycache__", [fileNode("x", 100 * MB)])]),
            chain("Library/Caches", dirNode("Homebrew", [fileNode("y", 400 * MB)])),
            chain("Library/Developer/Xcode", dirNode("Archives", [dirNode("A", [fileNode("z", 900 * MB)])])),
            dirNode("VirtualBox VMs", [dirNode("vm", [fileNode("disk", 300 * MB)])]),
        ]
        let found = Findings.find(in: treeUnderHome(home))
        #expect(ids(found) == ["package-caches", "pycache", "xcode-archives", "virtual-machines"])
    }

    @Test("a finding's nodes are largest first and its total is their sum")
    func nodesAndTotal() {
        let derived = dirNode("DerivedData", [dirNode("Small", [fileNode("s", 60 * MB)]), dirNode("Big", [fileNode("b", 300 * MB)]), dirNode("Mid", [fileNode("m", 100 * MB)])])
        let f = Findings.find(in: treeUnderHome([chain("Library/Developer/Xcode", derived)]))[0]
        #expect(f.nodes.map(\.name) == ["Big", "Mid", "Small"])
        #expect(f.totalSize == 460 * MB)
    }

    @Test("countLabel uses the singular for one item and the plural otherwise")
    func countLabel() {
        let one = Finding(id: "x", title: "", reason: "", icon: "", unitLabel: "cache", tier: .safe, isCollectible: true, nodes: [fileNode("a")])
        let two = Finding(id: "x", title: "", reason: "", icon: "", unitLabel: "cache", tier: .safe, isCollectible: true, nodes: [fileNode("a"), fileNode("b")])
        #expect(one.countLabel == "1 cache")
        #expect(two.countLabel == "2 caches")
    }

    // MARK: Trash, protection, the scan root

    @Test("what is already in the Trash is shown but is not collectible")
    func trashFindingIsInformational() {
        let trash = dirNode(".Trash", [fileNode("old.dmg", 300 * MB), fileNode("older.zip", 200 * MB)])
        let found = Findings.find(in: treeUnderHome([trash]))
        #expect(ids(found) == ["trash"])
        #expect(found[0].isCollectible == false)
        #expect(found[0].nodes.count == 2)
    }

    @Test("every finding except the Trash is collectible")
    func otherFindingsAreCollectible() {
        let home: [FileNode] = [
            dirNode(".Trash", [fileNode("old.dmg", 300 * MB)]),
            chain("Library/Caches", dirNode("Homebrew", [fileNode("y", 400 * MB)])),
        ]
        let found = Findings.find(in: treeUnderHome(home))
        #expect(found.filter { !$0.isCollectible }.map(\.id) == ["trash"])
    }

    @Test("a node the Safety rules refuse is left out of a collectible finding")
    func protectedNodesAreExcluded() async throws {
        try await withTempTree { tree in
            try tree.file("locked-project/node_modules/x.js", bytes: 10)
            try tree.file("locked-project/package.json", bytes: 10)
            try tree.file("open-project/node_modules/x.js", bytes: 10)
            try tree.file("open-project/package.json", bytes: 10)
            tree.lock("locked-project/node_modules")
            func project(_ name: String) -> FileNode {
                dirNode(name, [dirNode("node_modules", [fileNode("x.js", 200 * MB)]), fileNode("package.json", 1)])
            }
            let root = treeNode(root: tree.root.path, [project("locked-project"), project("open-project")])
            let found = Findings.find(in: root)
            #expect(found.first { $0.id == "node-modules" }?.nodes.map(\.path) == [tree.url("open-project/node_modules").path])
        }
    }

    @Test("when the scanned folder is itself a package cache, its children are offered, not the folder")
    func scannedFolderItselfIsNeverOffered() {
        let root = treeNode(root: NSHomeDirectory() + "/Library/Caches/Homebrew", [dirNode("downloads", [fileNode("a", 100 * MB)]), dirNode("Cask", [fileNode("b", 100 * MB)])])
        let found = Findings.find(in: root)
        #expect(Set(names(finding("package-caches", in: found))) == ["downloads", "Cask"])
        #expect(found.flatMap(\.nodes).allSatisfy { $0 !== root })
    }

    @Test("synthetic Free, Purgeable and Unseen nodes are never findings")
    func syntheticNodesAreSkipped() {
        let free = FileNode(name: "Free", isDirectory: false, size: 5 * GB, kind: .freeSpace)
        let root = dirNode("/", [free, FileNode(name: "Unseen", isDirectory: false, size: 3 * GB, kind: .hidden)])
        root.size = 8 * GB
        #expect(Findings.find(in: root).isEmpty)
    }
}
