import Darwin
import Foundation
import Testing
@testable import Discotech

/// The real scanner against real (tiny) folders in a temp directory. Sizes are allocated
/// blocks, so they are compared with what `lstat` reports for the same file rather than
/// with a guessed block size.
@Suite("Scanner")
struct ScannerTests {
    /// Allocated bytes of `url` as the filesystem reports them.
    private func allocated(_ url: URL) -> Int64 {
        var st = stat()
        #expect(lstat(url.path, &st) == 0)
        return Int64(st.st_blocks) * 512
    }

    /// root/
    ///   a.txt (5000)  empty.txt (0)  emptydir/
    ///   sub/b.bin (100000)  sub/deep/c.bin (4096)
    private func standardTree(_ tree: TempTree) throws {
        try tree.file("a.txt", bytes: 5_000)
        try tree.file("empty.txt", bytes: 0)
        try tree.dir("emptydir")
        try tree.file("sub/b.bin", bytes: 100_000)
        try tree.file("sub/deep/c.bin", bytes: 4_096)
    }

    @Test("a file's size is its allocated bytes: at least its length, and exactly what the filesystem allocated")
    func fileSizes() async throws {
        try await withTempTree { tree in
            try standardTree(tree)
            let root = try await tree.scan()
            for (path, length) in [("a.txt", 5_000), ("sub/b.bin", 100_000), ("sub/deep/c.bin", 4_096)] {
                let node = try #require(find(path, in: root), "\(path)")
                #expect(node.size >= Int64(length), "\(path)")
                #expect(node.size == allocated(tree.url(path)), "\(path)")
                #expect(node.size % 512 == 0, "\(path)")
                #expect(node.fileCount == 1)
                #expect(!node.isDirectory)
            }
        }
    }

    @Test("an empty file is a zero-byte node and still counts as a file")
    func emptyFile() async throws {
        try await withTempTree { tree in
            try standardTree(tree)
            let node = try #require(find("empty.txt", in: try await tree.scan()))
            #expect(node.size == 0)
            #expect(node.fileCount == 1)
        }
    }

    @Test("an empty folder is a folder node with no children and no size")
    func emptyFolder() async throws {
        try await withTempTree { tree in
            try standardTree(tree)
            let node = try #require(find("emptydir", in: try await tree.scan()))
            #expect(node.isDirectory)
            #expect(node.children.isEmpty)
            #expect(node.size == 0)
            #expect(node.fileCount == 0)
        }
    }

    @Test("folders hold the sum of everything below them, sorted largest first")
    func rollUp() async throws {
        try await withTempTree { tree in
            try standardTree(tree)
            let root = try await tree.scan()
            #expect(isConsistent(root))
            #expect(root.fileCount == 4)
            let sub = try #require(find("sub", in: root))
            #expect(sub.size == find("sub/b.bin", in: root)!.size + find("sub/deep/c.bin", in: root)!.size)
            #expect(sub.children.map(\.name) == ["b.bin", "deep"])
        }
    }

    @Test("the root node is named by its full path and carries its inode and device")
    func rootIdentity() async throws {
        try await withTempTree { tree in
            try standardTree(tree)
            let root = try await tree.scan()
            var st = stat()
            #expect(stat(tree.root.path, &st) == 0)
            #expect(root.name == tree.root.path)
            #expect(root.isDirectory)
            #expect(root.fileID == UInt64(st.st_ino))
            #expect(root.deviceID == Int32(st.st_dev))
            #expect(find("sub", in: root)?.fileID != 0)
        }
    }

    @Test("a folder with a bundle extension is marked as a package, an ordinary one is not")
    func packages() async throws {
        try await withTempTree { tree in
            try tree.file("Tool.app/Contents/Info.plist", bytes: 100)
            try tree.file("plain/x", bytes: 100)
            let root = try await tree.scan()
            #expect(find("Tool.app", in: root)?.isPackage == true)
            #expect(find("plain", in: root)?.isPackage == false)
        }
    }

    @Test("a symlink is a small leaf: it is not followed and what it points at is not counted twice")
    func symlinksAreNotFollowed() async throws {
        try await withTempTree { tree in
            try standardTree(tree)
            try tree.symlink("link-to-sub", to: tree.url("sub").path)
            try tree.symlink("link-to-file", to: tree.url("a.txt").path)
            let root = try await tree.scan()
            let dirLink = try #require(find("link-to-sub", in: root))
            #expect(!dirLink.isDirectory)
            #expect(dirLink.children.isEmpty)
            #expect(dirLink.size < 4_096 * 2)
            #expect(find("link-to-sub/b.bin", in: root) == nil)
            #expect(find("link-to-file", in: root)?.isDirectory == false)
            let bigFiles = root.children.flatMap { $0.children }.filter { $0.name == "b.bin" }
            #expect(bigFiles.count == 1)
            #expect(isConsistent(root))
        }
    }

    @Test("a symlink loop cannot make the scan recurse forever")
    func symlinkLoop() async throws {
        try await withTempTree { tree in
            try tree.dir("loop")
            try tree.symlink("loop/back", to: tree.root.path)
            try tree.file("loop/x", bytes: 10)
            let root = try await tree.scan()
            #expect(find("loop/back", in: root)?.children.isEmpty == true)
        }
    }

    @Test("hard links are counted once: one primary carries the size, the others show zero bytes and zero files")
    func hardLinks() async throws {
        try await withTempTree { tree in
            try tree.file("data/original.bin", bytes: 50_000)
            try tree.dir("other")
            try tree.hardLink("data/alias1.bin", to: "data/original.bin")
            try tree.hardLink("other/alias2.bin", to: "data/original.bin")
            let root = try await tree.scan()
            let names = ["data/original.bin", "data/alias1.bin", "other/alias2.bin"].compactMap { find($0, in: root) }
            #expect(names.count == 3)
            let primaries = names.filter { $0.hardLink == .primary }
            let secondaries = names.filter { $0.hardLink == .secondary }
            #expect(primaries.count == 1)
            #expect(secondaries.count == 2)
            #expect(primaries[0].size == allocated(tree.url("data/original.bin")))
            #expect(primaries[0].fileCount == 1)
            #expect(secondaries.allSatisfy { $0.size == 0 && $0.fileCount == 0 })
            #expect(root.size == primaries[0].size)
            #expect(root.fileCount == 1)
            #expect(Set(names.map(\.fileID)).count == 1)
        }
    }

    @Test("a folder that cannot be read stays as an empty folder node and the rest of the scan carries on")
    func unreadableFolder() async throws {
        try await withTempTree { tree in
            try standardTree(tree)
            try tree.file("locked/secret.bin", bytes: 8_192)
            tree.chmod("locked", 0o000)
            let root = try await tree.scan()
            let locked = try #require(find("locked", in: root))
            #expect(locked.isDirectory)
            #expect(locked.children.isEmpty)
            #expect(locked.size == 0)
            #expect(find("sub/b.bin", in: root) != nil)
            #expect(isConsistent(root))
        }
    }

    @Test("scanning a folder that does not exist fails with a message naming it")
    func missingRoot() async throws {
        try await withTempTree { tree in
            let missing = tree.url("nope")
            do {
                _ = try await DiscoScanner(root: missing).scan { _ in }
                Issue.record("expected the scan to throw")
            } catch let error as ScannerError {
                #expect(error.errorDescription?.contains(missing.path) == true)
                if case .cannotOpenRoot(_, let code) = error { #expect(code == ENOENT) }
            }
        }
    }

    @Test("a scan root that is a symlink to a folder is followed, because the person chose it")
    func symlinkRootIsFollowed() async throws {
        try await withTempTree { tree in
            try standardTree(tree)
            try tree.symlink("alias", to: tree.root.path)
            let root = try await DiscoScanner(root: tree.url("alias")).scan { _ in }
            #expect(find("sub/b.bin", in: root) != nil)
        }
    }

    @Test("the last progress report carries the final totals")
    func progressTotals() async throws {
        try await withTempTree { tree in
            try standardTree(tree)
            let reports = Locked<[ScanProgress]>([])
            let root = try await DiscoScanner(root: tree.root).scan { p in reports.withValue { $0.append(p) } }
            let last = try #require(reports.withValue { $0.last })
            #expect(last.filesScanned == root.fileCount)
            #expect(last.bytesScanned == root.size)
            #expect(last.directoriesScanned == 4) // root, emptydir, sub, sub/deep
        }
    }

    // MARK: Stop and cancel

    @Test("a scan whose task is already cancelled throws CancellationError instead of returning a tree")
    func cancelledTask() async throws {
        try await withTempTree { tree in
            try standardTree(tree)
            let scanner = DiscoScanner(root: tree.root)
            let started = ContinuousClock.now
            let task = Task { () -> FileNode in
                while !Task.isCancelled { await Task.yield() }
                return try await scanner.scan { _ in }
            }
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(ContinuousClock.now - started < .seconds(2))
        }
    }

    @Test("Stop requested before any work has nothing worth keeping: CancellationError, or a root with nothing measured, within the grace period")
    func stopBeforeAnyWork() async throws {
        try await withTempTree { tree in
            try standardTree(tree)
            let scanner = DiscoScanner(root: tree.root)
            scanner.stopAndKeep()
            let started = ContinuousClock.now
            do {
                let tree = try await scanner.scan { _ in }
                #expect(isConsistent(tree))
            } catch is CancellationError {
                // Stopped before the root opened.
            }
            #expect(ContinuousClock.now - started < .seconds(2))
        }
    }

    @Test("Stop mid-scan returns promptly with nothing or a self-consistent partial tree, never a half-written one")
    func stopReturnsConsistentTree() async throws {
        try await withTempTree { tree in
            for i in 0..<40 { for j in 0..<5 { try tree.file("d\(i)/e\(j)/f.bin", bytes: 4_096) } }
            let scanner = DiscoScanner(root: tree.root)
            let full = try await DiscoScanner(root: tree.root).scan { _ in }
            let started = ContinuousClock.now
            let task = Task { try await scanner.scan { _ in } }
            scanner.stopAndKeep()
            do {
                let partial = try await task.value
                #expect(isConsistent(partial))
                #expect(partial.size <= full.size)
                #expect(partial.fileCount <= full.fileCount)
            } catch is CancellationError {
                // Stopped before the root opened: nothing was measured.
            }
            #expect(ContinuousClock.now - started < .seconds(2))
        }
    }

    // MARK: Support types

    @Test("HardlinkTracker accepts an inode once per device")
    func hardlinkTracker() {
        let tracker = HardlinkTracker()
        #expect(tracker.claim(devID: 1, fileID: 10))
        #expect(!tracker.claim(devID: 1, fileID: 10))
        #expect(tracker.claim(devID: 2, fileID: 10))
        #expect(tracker.claim(devID: 1, fileID: 11))
    }

    @Test("TreeGate refuses writes after it is sealed and seals only once")
    func treeGateSeal() {
        let gate = TreeGate(workers: 2)
        let root = dirNode("/r")
        #expect(gate.adopt(root: root))
        var batch = [fileNode("a", 1)]
        gate.attach(&batch, to: root)
        #expect(root.children.count == 1)
        #expect(batch.isEmpty)
        #expect(gate.seal())
        #expect(!gate.seal())
        var late = [fileNode("b", 1)]
        gate.attach(&late, to: root)
        #expect(root.children.count == 1)
        #expect(gate.refusedWrites == 1)
        #expect(!gate.adopt(root: dirNode("/other")))
        #expect(gate.root === root)
    }

    @Test("ProgressTracker's final flush always reports, however recently it reported before")
    func progressFlush() {
        let gate = TreeGate(workers: 1)
        let reports = Locked<[ScanProgress]>([])
        let tracker = ProgressTracker(gate: gate) { p in reports.withValue { $0.append(p) } }
        let node = dirNode("/r")
        _ = gate.adopt(root: node)
        tracker.report(files: 3, directories: 1, bytes: 30, node: node)
        tracker.flush(currentPath: "/r")
        let last = reports.withValue { $0.last }
        #expect(last == ScanProgress(filesScanned: 3, directoriesScanned: 1, bytesScanned: 30, currentPath: "/r"))
    }
}
