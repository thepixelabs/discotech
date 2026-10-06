import Combine
import Foundation
import Testing
@testable import Discotech

/// The Crate's rules, on in-memory trees handed to `AppState`. `trashCollected` is never
/// called: nothing here can move a file.
@MainActor
@Suite("AppState: Crate")
struct CrateTests {
    /// /discotech-test-root
    ///   docs/        (a.txt 300, b.txt 100, sub/deep.bin 600)
    ///   top.txt 50
    ///   Free (synthetic)
    private struct Fixture {
        let state: AppState
        let root, docs, a, b, sub, deep, top, free: FileNode
    }

    private func fixture() -> Fixture {
        let a = fileNode("a.txt", 300), b = fileNode("b.txt", 100), deep = fileNode("deep.bin", 600)
        let sub = dirNode("sub", [deep])
        let docs = dirNode("docs", [a, b, sub])
        let top = fileNode("top.txt", 50)
        let free = FileNode(name: "Free", isDirectory: false, size: 5_000, kind: .freeSpace)
        let root = treeNode(root: "/discotech-test-root", [docs, top])
        root.children.append(free); free.parent = root
        let state = AppState(terms: nil)
        state.root = root
        return Fixture(state: state, root: root, docs: docs, a: a, b: b, sub: sub, deep: deep, top: top, free: free)
    }

    // MARK: collectBlockReason

    @Test("the scanned folder itself cannot go in the Crate")
    func rootIsBlocked() {
        let f = fixture()
        #expect(f.state.collectBlockReason(f.root) == "The scanned folder itself can’t go in the Crate.")
    }

    @Test("a synthetic node cannot go in the Crate")
    func syntheticIsBlocked() {
        let f = fixture()
        #expect(f.state.collectBlockReason(f.free) == "This isn’t a file, so it can’t go in the Crate.")
    }

    @Test("a node Safety protects cannot go in the Crate, and Safety's reason is the one given")
    func protectedIsBlocked() {
        let volume = treeNode(root: "/", [dirNode("System", [fileNode("x", 10)]), dirNode("Projects", [fileNode("y", 10)])])
        let state = AppState()
        state.root = volume
        let system = find("System", in: volume)!
        #expect(state.collectBlockReason(system) == Safety.protectionReason(for: system))
        #expect(state.collectBlockReason(system) != nil)
        #expect(!state.canCollect(system))
        #expect(state.canCollect(find("Projects/y", in: volume)!))
    }

    @Test("an ordinary node can go in the Crate")
    func ordinaryIsAllowed() {
        let f = fixture()
        #expect(f.state.collectBlockReason(f.a) == nil)
    }

    // MARK: collect / uncollect

    @Test("collect puts an item in the Crate and isCollected reports it")
    func collectAdds() {
        let f = fixture()
        f.state.collect(f.a)
        #expect(f.state.collected == [f.a])
        #expect(f.state.isCollected(f.a))
        #expect(!f.state.isCollected(f.b))
    }

    @Test("collecting a refused node leaves the Crate empty")
    func collectRefused() {
        let f = fixture()
        f.state.collect(f.root)
        f.state.collect(f.free)
        #expect(f.state.collected.isEmpty)
    }

    @Test("collecting the same item twice keeps one copy")
    func collectTwice() {
        let f = fixture()
        f.state.collect(f.a)
        f.state.collect(f.a)
        #expect(f.state.collected.count == 1)
    }

    @Test("an item inside an already collected folder is not added again, but still reads as collected")
    func collectInsideCollectedFolder() {
        let f = fixture()
        f.state.collect(f.docs)
        f.state.collect(f.deep)
        #expect(f.state.collected == [f.docs])
        #expect(f.state.isCollected(f.deep))
    }

    @Test("collecting a folder replaces its collected descendants and keeps unrelated items")
    func collectFolderSubsumesDescendants() {
        let f = fixture()
        f.state.collect(f.a)
        f.state.collect(f.deep)
        f.state.collect(f.top)
        f.state.collect(f.docs)
        #expect(Set(f.state.collected) == [f.docs, f.top])
    }

    @Test("uncollect removes exactly that item")
    func uncollectOne() {
        let f = fixture()
        f.state.collect(f.a)
        f.state.collect(f.top)
        f.state.uncollect(f.a)
        #expect(f.state.collected == [f.top])
        #expect(!f.state.isCollected(f.a))
    }

    @Test("uncollectAll empties the Crate and its size")
    func uncollectAll() {
        let f = fixture()
        f.state.collect(f.a)
        f.state.collect(f.top)
        f.state.uncollectAll()
        #expect(f.state.collected.isEmpty)
        #expect(f.state.collectedSize == 0)
    }

    @Test("isCollected is false for the folder holding a collected item and for its siblings")
    func isCollectedDirection() {
        let f = fixture()
        f.state.collect(f.sub)
        #expect(f.state.isCollected(f.deep))
        #expect(!f.state.isCollected(f.docs))
        #expect(!f.state.isCollected(f.a))
    }

    @Test("collecting nothing is zero bytes")
    func emptyCrateSize() {
        #expect(fixture().state.collectedSize == 0)
    }

    @Test("the Crate's size is the sum of its items, a folder counted once for everything inside it")
    func collectedSizeSum() {
        let f = fixture()
        f.state.collect(f.docs)
        f.state.collect(f.top)
        f.state.collect(f.a)
        #expect(f.state.collectedSize == 1_000 + 50)
    }

    @Test("hard-linked data only counts when every name for it is in the Crate")
    func collectedSizeWithHardLinks() {
        let primary = fileNode("data", 100, hardLink: .primary, inode: 7)
        let alias = fileNode("alias", 0, hardLink: .secondary, inode: 7)
        let root = treeNode(root: "/discotech-test-root", [dirNode("a", [primary]), dirNode("b", [alias])])
        let state = AppState()
        state.root = root
        state.collect(find("a", in: root)!)
        #expect(state.collectedSize == 0)
        state.collect(find("b", in: root)!)
        #expect(state.collectedSize == 100)
    }

    // MARK: Paths

    @Test("node(atPath:) resolves paths below the root and nothing else")
    func nodeAtPath() {
        let f = fixture()
        #expect(f.state.node(atPath: "/discotech-test-root") === f.root)
        #expect(f.state.node(atPath: "/discotech-test-root/docs/sub/deep.bin") === f.deep)
        #expect(f.state.node(atPath: "/discotech-test-root/missing") == nil)
        #expect(f.state.node(atPath: "/discotech-test-rootx/docs") == nil)
        #expect(f.state.node(atPath: "/elsewhere") == nil)
    }

    @Test("collect(paths:) accepts one path per line, ignores unknown ones and counts what it added")
    func collectPaths() {
        let f = fixture()
        let added = f.state.collect(paths: ["/discotech-test-root/top.txt\n/discotech-test-root/docs/a.txt", "/nope/nothing"])
        #expect(added == 2)
        #expect(Set(f.state.collected) == [f.top, f.a])
    }

    @Test("a drop reports what was refused and why, and adds the rest")
    func collectDropped() {
        let f = fixture()
        let result = f.state.collectDropped(paths: ["/discotech-test-root/docs", "/discotech-test-root", "/discotech-test-root/Free"])
        #expect(result.added == 1)
        #expect(f.state.collected == [f.docs])
        #expect(result.refused.map(\.reason) == ["The scanned folder itself can’t go in the Crate.", "This isn’t a file, so it can’t go in the Crate."])
    }

    // MARK: Terms gate

    @Test("scans do not start while the terms are not accepted")
    func scanRefusedWithoutTerms() async throws {
        try await withTempTree { tree in
            try tree.file("a.txt", bytes: 100)
            await withIsolatedDefaults { defaults in
                let state = AppState(terms: TermsStore(defaults: defaults, environment: [:]))
                state.startScan(tree.root)
                #expect(state.phase == .start)
                #expect(state.scanRoot == nil)
                #expect(state.root == nil)
            }
        }
    }

    @Test("scans start once the terms are accepted")
    func scanRunsWithTerms() async throws {
        try await withTempTree { tree in
            try tree.file("a.txt", bytes: 100)
            try await withIsolatedDefaults { defaults in
                let state = try await scannedState(tree.root, defaults: defaults)
                #expect(state.phase == .browsing)
                #expect(state.root?.path == tree.root.path)
                #expect(find("a.txt", in: state.root!) != nil)
            }
        }
    }

    // MARK: Scan generation

    @Test("a scan superseded by a newer one never publishes its tree")
    func supersededScanIsIgnored() async throws {
        try await withTempTree { tree in
            for i in 0..<30 { try tree.file("first/dir\(i)/f.bin", bytes: 4_096) }
            try tree.file("second/only.bin", bytes: 4_096)
            try await withIsolatedDefaults { defaults in
                let terms = TermsStore(defaults: defaults, environment: [:])
                terms.accept()
                let state = AppState(terms: terms)
                let published = Locked<[String]>([])
                let watch = state.$root.compactMap { $0?.path }.sink { path in published.withValue { $0.append(path) } }
                defer { watch.cancel() }
                state.startScan(tree.url("first"))
                state.startScan(tree.url("second"))
                try await awaitValue(state.$phase, "second scan to finish") { $0 == .browsing }
                #expect(state.root?.path == tree.url("second").path)
                #expect(state.scanRoot == tree.url("second"))
                #expect(published.withValue { $0 } == [tree.url("second").path])
            }
        }
    }

    @Test("cancelling a scan leaves the scanning screen at once, with no tree")
    func cancelledScan() async throws {
        try await withTempTree { tree in
            try tree.file("a.txt", bytes: 100)
            await withIsolatedDefaults { defaults in
                let terms = TermsStore(defaults: defaults, environment: [:])
                terms.accept()
                let state = AppState(terms: terms)
                state.startScan(tree.root)
                #expect(state.phase == .scanning)
                state.cancelScan()
                #expect(state.phase == .start)
                #expect(state.root == nil)
            }
        }
    }

    @Test("backToStart empties the tree, the Crate and the focus")
    func backToStart() async throws {
        try await withTempTree { tree in
            try tree.file("a.txt", bytes: 100)
            try await withIsolatedDefaults { defaults in
                let state = try await scannedState(tree.root, defaults: defaults)
                state.collect(find("a.txt", in: state.root!)!)
                state.backToStart()
                #expect(state.root == nil)
                #expect(state.focus == nil)
                #expect(state.collected.isEmpty)
                #expect(state.phase == .start)
            }
        }
    }
}
