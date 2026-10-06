import Darwin
import Foundation

/// Cross-thread cancellation signal. Plain worker threads (driven via
/// `DispatchQueue.concurrentPerform`) aren't part of the calling `Task`'s
/// structured-concurrency tree, so `Task.isCancelled` isn't visible to them.
/// `Scanner` bridges the async `Task`'s cancellation into this flag via
/// `withTaskCancellationHandler`, and every worker polls it.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    func cancel() {
        lock.lock()
        flag = true
        lock.unlock()
    }
}

/// Tracks (devID, fileID) pairs for hard-linked regular files so their allocated
/// size and file count are attributed to exactly one `FileNode` — matching how
/// `du -s` reports totals. Subsequent occurrences of an already-seen inode are
/// still added to the tree (so the name shows up where Finder would show it) but
/// contribute zero size/count, since `FileNode` has no "shared, already counted
/// elsewhere" flag to hang a footnote on.
final class HardlinkTracker: @unchecked Sendable {
    private struct Key: Hashable { let devID: Int32; let fileID: UInt64 }
    private let lock = NSLock()
    private var seen = Set<Key>()

    /// Returns true the first time this (devID, fileID) is seen, false on every
    /// subsequent call.
    func claim(devID: Int32, fileID: UInt64) -> Bool {
        let key = Key(devID: devID, fileID: fileID)
        lock.lock()
        defer { lock.unlock() }
        return seen.insert(key).inserted
    }
}

/// The only way scan workers may change the tree, so a stopped scan can hand its tree
/// over while some workers are still stuck in the kernel. (`openat` on a folder macOS
/// protects, such as ~/Music, waits until the person answers the privacy prompt, however
/// long that takes.)
///
/// Workers collect a directory's entries in a private batch and publish it into the
/// directory's node here, before any call that can block and once the listing ends.
/// After `seal()` every later write is refused, so the tree the caller gets can't
/// change under the main actor, whatever the workers do once they wake. Nodes still
/// in a worker's batch are reachable from nothing, so writing to them stays harmless.
final class TreeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var windingDown = false
    private var sealed = false
    private var adoptedRoot: FileNode?
    /// Per worker: the folder whose `openat` is in progress, for the stall hint.
    private var opening: [FileNode?]
    /// Publishes refused because they came after the seal (shown in the scan log).
    private(set) var refusedWrites = 0

    init(workers: Int) {
        opening = Array(repeating: nil, count: workers)
    }

    /// Records the opened root. False if the scan was sealed while its root was still
    /// opening; the caller then drops it.
    func adopt(root: FileNode) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !sealed else { return false }
        adoptedRoot = root
        return true
    }

    /// Stop or Cancel was pressed: open no more folders (each could raise another prompt).
    func windDown() {
        lock.lock()
        windingDown = true
        lock.unlock()
    }

    /// Ends the workers' write access. True only for the first caller, which from then
    /// on owns `root` and everything under it alone.
    func seal() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !sealed else { return false }
        sealed = true
        opening = opening.map { _ in nil }
        return true
    }

    var isSealed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sealed
    }

    /// The root adopted before the seal; nil if it never opened. Read it after winning `seal()`.
    var root: FileNode? {
        lock.lock()
        defer { lock.unlock() }
        return adoptedRoot
    }

    /// Appends `batch` to `node.children`, or drops it once sealed. Leaves `batch` empty.
    func attach(_ batch: inout [FileNode], to node: FileNode) {
        guard !batch.isEmpty else { return }
        lock.lock()
        publish(&batch, into: node)
        lock.unlock()
    }

    /// Publishes `batch` (which ends with `child`) into `node`, then marks `child` as
    /// being opened by `worker`. False, with nothing marked, once the scan is winding down.
    func willOpen(_ child: FileNode, worker: Int, publishing batch: inout [FileNode], into node: FileNode) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        publish(&batch, into: node)
        guard !windingDown else { return false }
        opening[worker] = child
        return true
    }

    /// `worker` is back from opening `child`. Records the opened folder's own identity
    /// (the listing reports a synthetic one for firmlinks) unless the tree is sealed.
    func didOpen(_ child: FileNode, worker: Int, identity: stat?) {
        lock.lock()
        defer { lock.unlock() }
        guard !sealed else { refusedWrites += 1; return }
        opening[worker] = nil
        if let identity {
            child.fileID = UInt64(identity.st_ino)
            child.deviceID = Int32(identity.st_dev)
        }
    }

    /// Runs `body` only while the tree still belongs to the workers.
    func ifUnsealed<T>(_ body: () -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        return sealed ? nil : body()
    }

    /// Folders being opened right now. Their `name`/`parent` never change after they
    /// were published, so their paths can be read without the lock.
    func openingNodes() -> [FileNode] {
        lock.lock()
        defer { lock.unlock() }
        return opening.compactMap { $0 }
    }

    /// Caller holds `lock`.
    private func publish(_ batch: inout [FileNode], into node: FileNode) {
        if sealed {
            if !batch.isEmpty { refusedWrites += 1 }
            batch.removeAll()
        } else if node.children.isEmpty {
            swap(&node.children, &batch) // hand the buffer over instead of copying it
        } else {
            node.children.append(contentsOf: batch)
            batch.removeAll(keepingCapacity: true)
        }
    }
}

/// Hands a scan's outcome to its awaiting caller exactly once, from whichever path
/// gets there first (workers finished, Stop, Cancel), even before the caller waits.
final class ScanHandoff: @unchecked Sendable {
    private let lock = NSLock()
    private var waiter: CheckedContinuation<FileNode, Error>?
    private var early: Result<FileNode, Error>?
    private var delivered = false

    func wait(_ continuation: CheckedContinuation<FileNode, Error>) {
        lock.lock()
        if let early {
            self.early = nil
            lock.unlock()
            continuation.resume(with: early)
        } else {
            waiter = continuation
            lock.unlock()
        }
    }

    func deliver(_ outcome: Result<FileNode, Error>) {
        lock.lock()
        guard !delivered else { lock.unlock(); return }
        delivered = true
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(with: outcome)
        } else {
            early = outcome
            lock.unlock()
        }
    }
}

/// DEBUG-only stderr trace of the scan lifecycle (DISCOTECH_SCAN_LOG=1); nothing in release.
enum ScanLog {
    @inline(__always)
    static func line(_ message: @autoclosure () -> String) {
        #if DEBUG
        guard enabled else { return }
        let t = String(format: "%.3f", ProcessInfo.processInfo.systemUptime - start)
        FileHandle.standardError.write(Data("[scan +\(t)s] \(message())\n".utf8))
        #endif
    }
    #if DEBUG
    private static let enabled = ProcessInfo.processInfo.environment["DISCOTECH_SCAN_LOG"] != nil
    private static let start = ProcessInfo.processInfo.systemUptime
    #endif
}

/// Batches per-worker counters and emits `ScanProgress` snapshots throttled to
/// ~10/sec, as required by the scan contract. Callers report once per completed
/// directory (not per entry) to keep lock contention negligible.
final class ProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var filesScanned = 0
    private var directoriesScanned = 0
    private var bytesScanned: Int64 = 0
    private var lastEmit = DispatchTime.now().uptimeNanoseconds
    private let minIntervalNanos: UInt64 = 100_000_000 // 100ms -> ~10Hz
    private let gate: TreeGate
    private let callback: @Sendable (ScanProgress) -> Void

    init(gate: TreeGate, callback: @escaping @Sendable (ScanProgress) -> Void) {
        self.gate = gate
        self.callback = callback
    }

    /// `node` is the folder just worked on. Its path is only built for the snapshots
    /// actually sent, and never after the seal: the tree is the main actor's by then,
    /// so a worker waking late reports nothing.
    func report(files: Int, directories: Int, bytes: Int64, node: FileNode) {
        lock.lock()
        filesScanned += files
        directoriesScanned += directories
        bytesScanned += bytes
        let now = DispatchTime.now().uptimeNanoseconds
        guard now - lastEmit >= minIntervalNanos else {
            lock.unlock()
            return
        }
        lastEmit = now
        let files = filesScanned, directories = directoriesScanned, bytes = bytesScanned
        lock.unlock()
        guard let path = gate.ifUnsealed({ node.path }) else { return }
        callback(ScanProgress(filesScanned: files, directoriesScanned: directories,
                              bytesScanned: bytes, currentPath: path))
    }

    /// Unconditional final snapshot, called once after the scan completes.
    func flush(currentPath: String) {
        lock.lock()
        let snapshot = ScanProgress(
            filesScanned: filesScanned, directoriesScanned: directoriesScanned,
            bytesScanned: bytesScanned, currentPath: currentPath
        )
        lock.unlock()
        callback(snapshot)
    }
}
