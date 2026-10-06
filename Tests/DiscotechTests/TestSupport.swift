import Combine
import Darwin
import Foundation
import Testing
@testable import Discotech

// Shared helpers for every test file. Rules that hold for all of them:
//  - real files only ever live in a `TempTree` under the system temporary directory;
//  - nothing here (or in any test) moves anything to the Trash;
//  - settings go through isolated `UserDefaults` suites (`IsolatedDefaults`).

typealias DiscoScanner = Discotech.Scanner

// MARK: - In-memory FileNode trees

/// A directory node whose children point back at it (`FileNode.init` does not set `parent`).
func dirNode(_ name: String, package: Bool = false, inode: UInt64 = 0, _ children: [FileNode] = []) -> FileNode {
    let node = FileNode(name: name, isDirectory: true, isPackage: package, children: children)
    node.fileID = inode
    for child in children { child.parent = node }
    return node
}

/// A regular file of `size` allocated bytes. A secondary hard link carries 0 bytes and 0 files,
/// as the scanner records it.
func fileNode(_ name: String, _ size: Int64 = 0, hardLink: FileNode.HardLink = .none,
              inode: UInt64 = 0, device: Int32 = 1) -> FileNode {
    let node = FileNode(name: name, isDirectory: false, size: size, fileCount: hardLink == .secondary ? 0 : 1)
    node.hardLink = hardLink
    node.fileID = inode
    node.deviceID = device
    return node
}

/// A finished tree: `root` named `rootName` (its full path), sizes rolled up and children sorted.
func treeNode(root rootName: String = "/", _ children: [FileNode]) -> FileNode {
    let root = dirNode(rootName, children)
    root.finalize()
    return root
}

/// Looks a node up by a slash-separated path below `root`.
func find(_ path: String, in root: FileNode) -> FileNode? {
    var node: FileNode? = root
    for part in path.split(separator: "/") { node = node?.children.first { $0.name == part } }
    return node
}

/// Builds a tree rooted at "/" that holds `children` inside the real home folder's path
/// (`/Users/<you>/…`), so the home-relative Findings rules apply. Pure memory: no file is
/// created. `NSHomeDirectory()` is what the code under test reads too.
func treeUnderHome(_ children: [FileNode]) -> FileNode {
    var inner = mergingSameNamedFolders(children)
    for part in NSHomeDirectory().split(separator: "/").reversed() { inner = [dirNode(String(part), inner)] }
    return treeNode(root: "/", inner)
}

/// Folders with the same name side by side become one folder holding all their children
/// (so `chain("Library/Caches", x)` and `chain("Library/Developer", y)` share one `Library`).
func mergingSameNamedFolders(_ nodes: [FileNode]) -> [FileNode] {
    var order: [String] = []
    var folders: [String: [FileNode]] = [:]
    var others: [FileNode] = []
    for node in nodes {
        if node.isDirectory && !node.isPackage {
            if folders[node.name] == nil { order.append(node.name) }
            folders[node.name, default: []].append(node)
        } else {
            others.append(node)
        }
    }
    let merged = order.map { name -> FileNode in
        let group = folders[name]!
        return group.count == 1 ? group[0] : dirNode(name, mergingSameNamedFolders(group.flatMap(\.children)))
    }
    return merged + others
}

/// A folder chain `a/b/c` (each created on demand) holding `leaf`.
func chain(_ path: String, _ leaf: FileNode) -> FileNode {
    var result = leaf
    for part in path.split(separator: "/").reversed() { result = dirNode(String(part), [result]) }
    return result
}

let MB: Int64 = 1 << 20
let GB: Int64 = 1 << 30

// MARK: - Real files in a temp folder

/// A throwaway folder under the system temporary directory, with real files, folders,
/// symlinks, hard links and permission/flag changes. Removed (flags and permissions undone
/// first) by `cleanup`; `withTempTree` guarantees that.
final class TempTree: @unchecked Sendable {
    /// Resolved (no symlinked components), unique per tree.
    let root: URL
    private var undo: [() -> Void] = []

    init() throws {
        let base = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path).resolvingSymlinksInPath()
        root = base.appendingPathComponent("discotech-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func url(_ path: String) -> URL { path.isEmpty ? root : root.appendingPathComponent(path) }

    @discardableResult
    func dir(_ path: String) throws -> URL {
        let u = url(path)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// A file of exactly `bytes` non-zero bytes (so it is never sparse).
    @discardableResult
    func file(_ path: String, bytes: Int = 0) throws -> URL {
        let u = url(path)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: bytes).write(to: u)
        return u
    }

    func append(_ path: String, bytes: Int) throws {
        let handle = try FileHandle(forWritingTo: url(path))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 0xCD, count: bytes))
    }

    func symlink(_ path: String, to target: String) throws {
        try FileManager.default.createSymbolicLink(atPath: url(path).path, withDestinationPath: target)
    }

    func hardLink(_ path: String, to existing: String) throws {
        try FileManager.default.linkItem(atPath: url(existing).path, toPath: url(path).path)
    }

    func remove(_ path: String) throws { try FileManager.default.removeItem(at: url(path)) }

    /// `chmod`, undone at cleanup.
    func chmod(_ path: String, _ mode: mode_t) {
        let p = url(path).path
        var old = stat()
        if lstat(p, &old) == 0 { let previous = old.st_mode & 0o7777; undo.append { _ = Darwin.chmod(p, previous) } }
        _ = Darwin.chmod(p, mode)
    }

    /// Sets the user-immutable flag (`chflags uchg`), cleared at cleanup.
    func lock(_ path: String) {
        let p = url(path).path
        undo.append { _ = chflags(p, 0) }
        _ = chflags(p, UInt32(UF_IMMUTABLE))
    }

    func unlock(_ path: String) { _ = chflags(url(path).path, 0) }

    func scan() async throws -> FileNode {
        try await DiscoScanner(root: root).scan { _ in }
    }

    func cleanup() {
        for restore in undo.reversed() { restore() }
        undo = []
        // Never delete anything that is not one of our own folders under the temp directory.
        let base = FileManager.default.temporaryDirectory.path
        let resolvedBase = URL(fileURLWithPath: base).resolvingSymlinksInPath().path
        guard root.path.hasPrefix(resolvedBase + "/"), root.lastPathComponent.hasPrefix("discotech-tests-") else { return }
        try? FileManager.default.removeItem(at: root)
    }
}

func withTempTree<T>(_ body: (TempTree) async throws -> T) async throws -> T {
    let tree = try TempTree()
    defer { tree.cleanup() }
    return try await body(tree)
}

// MARK: - Isolated settings

/// A `UserDefaults` suite of its own, so a test never reads or writes the real settings.
final class IsolatedDefaults: @unchecked Sendable {
    let defaults: UserDefaults
    private let name: String

    init() {
        name = "discotech.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
    }

    func cleanup() { defaults.removePersistentDomain(forName: name) }
}

func withIsolatedDefaults<T>(_ body: (UserDefaults) async throws -> T) async rethrows -> T {
    let box = IsolatedDefaults()
    defer { box.cleanup() }
    return try await body(box.defaults)
}

// MARK: - Waiting on observable state (no sleeps)

struct WaitTimedOut: Error, CustomStringConvertible {
    let what: String
    var description: String { "timed out waiting for \(what)" }
}

/// Resolves when `publisher` emits a value satisfying `predicate` (including its current
/// value), or throws `WaitTimedOut` after `seconds`.
@MainActor
func awaitValue<P: Publisher>(_ publisher: P, _ what: String, seconds: Double = 5,
                              where predicate: @escaping @Sendable (P.Output) -> Bool) async throws
    where P.Failure == Never, P.Output: Sendable {
    let satisfied = CurrentValueSubject<Bool, Never>(false)
    let cancellable = publisher.sink { if predicate($0) { satisfied.send(true) } }
    defer { cancellable.cancel() }
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { for await ok in satisfied.values where ok { return } }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw WaitTimedOut(what: what)
        }
        try await group.next()
        group.cancelAll()
    }
}

/// An `AppState` whose terms are accepted (in an isolated suite) and whose scan of `url`
/// has finished.
@MainActor
func scannedState(_ url: URL, defaults: UserDefaults) async throws -> AppState {
    let terms = TermsStore(defaults: defaults, environment: [:])
    terms.accept()
    let state = AppState(terms: terms)
    state.startScan(url)
    try await awaitValue(state.$phase, "scan to finish") { $0 == .browsing }
    return state
}

/// Thread-safe collector for values delivered by `@Sendable` callbacks.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withValue<R>(_ body: (inout Value) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}

/// Sizes and file counts of every folder equal the sum of its children, children sorted
/// largest first. The invariant every finished tree must hold.
func isConsistent(_ root: FileNode, checkOrder: Bool = true) -> Bool {
    var stack = [root]
    while let node = stack.popLast() {
        guard node.isDirectory else { continue }
        if node.size != node.children.reduce(0, { $0 + $1.size }) { return false }
        if node.fileCount != node.children.reduce(0, { $0 + $1.fileCount }) { return false }
        if checkOrder, zip(node.children, node.children.dropFirst()).contains(where: { $0.size < $1.size }) { return false }
        stack.append(contentsOf: node.children)
    }
    return true
}
