import Darwin
import Foundation

enum ScannerError: LocalizedError {
    case cannotOpenRoot(path: String, errno: Int32)

    var errorDescription: String? {
        switch self {
        case .cannotOpenRoot(let path, let code):
            return "Can't open \(path): \(String(cString: strerror(code)))"
        }
    }
}

/// One directory queued for listing: an already-open fd (opened relative to its
/// parent via `openat`, so descending never re-resolves the full path from `/`)
/// and the `FileNode` its children should be appended to.
private struct ScanJob {
    let fd: Int32
    let node: FileNode
}

/// Shared work-stealing stack of pending directories. Workers pop from it, list
/// the directory, and push a job per subdirectory found — no per-directory
/// recursion, no one-Task-per-directory explosion.
///
/// `outstanding` counts jobs that exist but haven't finished processing yet
/// (queued *and* in-flight). It reaches zero exactly when there is no more work
/// anywhere, which is how workers agree to stop without a fixed job count known
/// up front. After `cancel()` an idle worker leaves as soon as nothing is queued,
/// rather than waiting on a busy peer that may be stuck in the kernel; whoever is
/// still out pops (and closes) anything it pushes before leaving too.
private final class JobQueue: @unchecked Sendable {
    private let condition = NSCondition()
    private var pending: [ScanJob] = []
    private var outstanding = 0
    private var cancelled = false
    /// Per worker: the folder it is listing, for the stall hint.
    private var listing: [FileNode?]

    init(workers: Int) {
        listing = Array(repeating: nil, count: workers)
    }

    func push(_ job: ScanJob) {
        condition.lock()
        pending.append(job)
        outstanding += 1
        condition.signal()
        condition.unlock()
    }

    /// Blocks until work is available, the whole queue has drained, or the scan
    /// was cancelled and nothing is queued.
    func pop(worker: Int) -> ScanJob? {
        condition.lock()
        defer { condition.unlock() }
        while pending.isEmpty {
            if outstanding == 0 || cancelled { return nil }
            condition.wait()
        }
        let job = pending.removeLast() // LIFO: depth-first, keeps recently-touched dirs (and their dentry cache lines) hot
        listing[worker] = job.node
        return job
    }

    /// Must be called exactly once for every job returned by `pop`, after all of
    /// that job's child jobs (if any) have been pushed.
    func finish(worker: Int) {
        condition.lock()
        listing[worker] = nil
        outstanding -= 1
        if outstanding == 0 { condition.broadcast() }
        condition.unlock()
    }

    func cancel() {
        condition.lock()
        cancelled = true
        condition.broadcast()
        condition.unlock()
    }

    func listingNodes() -> [FileNode] {
        condition.lock()
        defer { condition.unlock() }
        return listing.compactMap { $0 }
    }
}

/// Parallel, `getattrlistbulk`-based disk scanner.
///
/// Design notes (see also the task brief):
/// - **Parallelism**: a fixed pool of worker threads (sized to
///   `ProcessInfo.activeProcessorCount`) pulls directories off a shared LIFO job
///   queue and lists each with `getattrlistbulk(2)`. Every subdirectory found
///   becomes a new job on the same queue — dynamic work-stealing, not a fixed
///   per-core partition, so a worker stuck behind one huge directory doesn't
///   starve the others.
/// - **Volume/firmlink boundary**: macOS presents firmlinked directories
///   (`/Users`, `/Applications`, …) with the *same* `st_dev`/`ATTR_CMN_DEVID` as
///   the root volume — that's the whole point of firmlinks, so `du`-like tools
///   don't need special-case logic for them. A *real* mount point (an actual
///   separate volume, e.g. `/System/Volumes/Data`, `/System/Volumes/VM`, or an
///   external drive under `/Volumes`) is instead flagged via
///   `ATTR_DIR_MOUNTSTATUS`'s `DIR_MNTSTATUS_MNTPOINT` bit — verified empirically
///   on this machine (see scanner report). We stop descending when that bit is
///   set, or (belt-and-suspenders, for filesystems that don't return
///   `ATTR_DIR_MOUNTSTATUS`) when `ATTR_CMN_DEVID` differs from the root's. This
///   means scanning `/` does *not* double-count `/System/Volumes/Data` under
///   both its real path and its firmlinked names.
/// - **Hard links**: regular files with `ATTR_FILE_LINKCOUNT > 1` are deduped by
///   (devID, fileID) via `HardlinkTracker` — only the first occurrence
///   contributes size/count to the tree total.
/// - **Symlinks**: never followed. Subdirectories are opened with
///   `openat(..., O_NOFOLLOW)`, so a symlink can't even be attempted as a
///   directory; it's recorded as a small leaf node instead.
/// - **Stack safety**: neither the traversal nor the final bottom-up size rollup
///   recurses per directory level — traversal is the explicit `JobQueue` above,
///   and `finalizeIterative` is an explicit-stack post-order walk. Worker
///   threads only get 512KB stacks, and real-world trees run deep enough
///   (`node_modules`, Xcode DerivedData, Time Machine-style structures) that
///   naive recursion is a real crash risk.
/// - **Stop never waits for a stuck worker**: `openat` on a folder macOS protects
///   blocks until the person answers the privacy prompt, and a slow volume can stall
///   any call. Stop and Cancel therefore don't join the workers: they seal the
///   `TreeGate` (after a short grace for workers that are merely busy) and hand over
///   what had been published by then. A worker that wakes later can no longer write
///   to that tree, report progress, or touch this scan's result.
///
/// One scan per instance.
final class Scanner: @unchecked Sendable {
    let root: URL

    /// Shared with the workers; set by Task cancellation or by `stopAndKeep()`.
    private let cancelFlag = CancelFlag()
    /// When set, a stopped scan returns what it measured instead of throwing.
    private let keepPartial = CancelFlag()
    private let workerCount = max(2, min(ProcessInfo.processInfo.activeProcessorCount, 32))
    private let queue: JobQueue
    let gate: TreeGate
    private let handoff = ScanHandoff()
    /// Left when the engine's own thread is done with the workers (or gave up).
    private let engineDone = DispatchGroup()

    /// How long Stop lets busy workers finish the folder they're on before it hands
    /// over the tree without them. Short enough that Stop always feels immediate.
    private static let stopGrace: TimeInterval = 0.2

    init(root: URL) {
        self.root = root
        queue = JobQueue(workers: workerCount)
        gate = TreeGate(workers: workerCount)
        engineDone.enter()
        #if DEBUG
        debugBlock = Self.claimDebugBlock()
        #endif
    }

    /// Stops the scan early; `scan` then returns the partial tree (finalized)
    /// instead of throwing, within `stopGrace` plus the finalize, even if workers are
    /// stuck in the kernel. Directories not yet listed show as empty; one being
    /// listed shows what was published from it so far.
    func stopAndKeep() {
        guard !keepPartial.isCancelled else { return }
        keepPartial.cancel()
        interrupt()
        ScanLog.line("stop requested; waiting up to \(Self.stopGrace)s for busy workers")
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let settled = engineDone.wait(timeout: .now() + Self.stopGrace) == .success
            guard gate.seal() else { return } // the engine (or Cancel) got there first
            ScanLog.line(settled ? "stop: workers settled within grace" : "stop: sealing tree without stuck workers")
            deliver()
        }
    }

    /// Folders the scan is waiting on right now: those being opened (where a pending
    /// privacy prompt blocks), or else those being listed. Paths rebuilt on demand,
    /// for the stall hint; call it only while the scan runs.
    func waitingPaths() -> [String] {
        let opening = gate.openingNodes()
        return (opening.isEmpty ? queue.listingNodes() : opening).map(\.path)
    }

    /// Scans `root` and returns the finalized tree (sizes summed, children
    /// sorted). `progress` is called from background threads, throttled to
    /// ~10x/sec. Throws `CancellationError` if the calling Task is cancelled
    /// (but returns the partial tree after `stopAndKeep()`, or throws
    /// `CancellationError` if the root itself was still opening),
    /// or a `ScannerError` if `root` itself can't be opened.
    func scan(progress: @escaping @Sendable (ScanProgress) -> Void) async throws -> FileNode {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<FileNode, Error>) in
                handoff.wait(continuation)
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    runScan(progress: progress)
                }
            }
        } onCancel: { [self] in
            interrupt()
            // Nothing to keep, so nobody to wait for.
            if gate.seal() { handoff.deliver(.failure(CancellationError())) }
        }
    }

    /// Tells workers to wind down: no new folders opened, idle workers leave.
    private func interrupt() {
        cancelFlag.cancel()
        gate.windDown()
        queue.cancel()
    }

    /// Finalizes and hands over the tree. Only for the caller that won `gate.seal()`,
    /// which makes the tree this thread's alone.
    private func deliver() {
        guard !cancelFlag.isCancelled || keepPartial.isCancelled else {
            handoff.deliver(.failure(CancellationError()))
            return
        }
        guard let tree = gate.root else {
            // Stopped while the scanned folder itself was still opening: nothing measured.
            handoff.deliver(.failure(CancellationError()))
            return
        }
        finalizeIterative(tree)
        handoff.deliver(.success(tree))
    }

    // MARK: - Synchronous engine (runs on a background dispatch queue)

    private func runScan(progress: @escaping @Sendable (ScanProgress) -> Void) {
        defer { engineDone.leave() }

        // Subdirectory fds are opened eagerly (relative to their parent, via
        // openat) as soon as they're discovered while listing, since the parent
        // fd is closed the moment its own listing finishes and can't be reopened
        // from later. That means a single very wide directory (tens of thousands
        // of direct subdirectories) can transiently hold that many fds open
        // before workers drain the queue. Raise the soft RLIMIT_NOFILE towards
        // the hard limit so that doesn't silently truncate the scan with EMFILE;
        // best-effort, a lower ceiling just means pathologically wide directories
        // may skip a few subtrees instead of crashing.
        raiseFileDescriptorLimit()

        // Root may itself be a symlink (the user picked it deliberately) — only
        // descendants are opened with O_NOFOLLOW.
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY)
        guard rootFD >= 0 else {
            let error = ScannerError.cannotOpenRoot(path: root.path, errno: errno)
            if gate.seal() { handoff.deliver(.failure(error)) }
            return
        }

        var rootStat = stat()
        guard fstat(rootFD, &rootStat) == 0 else {
            let error = ScannerError.cannotOpenRoot(path: root.path, errno: errno)
            close(rootFD)
            if gate.seal() { handoff.deliver(.failure(error)) }
            return
        }
        let rootDevID = Int32(rootStat.st_dev)

        let rootNode = FileNode(name: root.path, isDirectory: true)
        rootNode.fileID = UInt64(rootStat.st_ino)
        rootNode.deviceID = rootDevID
        guard gate.adopt(root: rootNode) else {
            close(rootFD) // stopped or cancelled while the root was still opening
            return
        }
        let progressTracker = ProgressTracker(gate: gate, callback: progress)
        let hardlinks = HardlinkTracker()

        queue.push(ScanJob(fd: rootFD, node: rootNode))

        DispatchQueue.concurrentPerform(iterations: workerCount) { worker in
            runWorker(worker, rootDevID: rootDevID, progressTracker: progressTracker, hardlinks: hardlinks)
        }

        // A Stop that gave up on stuck workers has already sealed and delivered.
        guard gate.seal() else {
            ScanLog.line("engine: last worker done after the hand-over; \(gate.refusedWrites) late writes refused")
            return
        }
        progressTracker.flush(currentPath: rootNode.path)
        deliver()
    }

    private func runWorker(_ worker: Int, rootDevID: Int32, progressTracker: ProgressTracker, hardlinks: HardlinkTracker) {
        let bufferSize = 256 * 1024
        let scratch = UnsafeMutableRawBufferPointer.allocate(byteCount: bufferSize, alignment: 8)
        defer { scratch.deallocate() }

        while let job = queue.pop(worker: worker) {
            if cancelFlag.isCancelled {
                close(job.fd)
                queue.finish(worker: worker)
                continue
            }
            process(job, worker: worker, rootDevID: rootDevID,
                    progressTracker: progressTracker, hardlinks: hardlinks, scratch: scratch)
        }
    }

    private func process(
        _ job: ScanJob, worker: Int, rootDevID: Int32,
        progressTracker: ProgressTracker, hardlinks: HardlinkTracker,
        scratch: UnsafeMutableRawBufferPointer
    ) {
        var localFiles = 0
        var localBytes: Int64 = 0
        var entryIndex = 0
        // Entries listed since the last publish into `job.node` (see `TreeGate`).
        var batch: [FileNode] = []

        do {
            try listDirectoryBulk(dirFD: job.fd, scratch: scratch) { entry in
                entryIndex += 1
                if entryIndex & 0xFFF == 0, cancelFlag.isCancelled {
                    throw CancellationError() // stop this directory early; queue.finish() below still runs
                }
                // Huge flat directories (e.g. a Rust target/debug/deps with ~1M entries)
                // can take most of a scan on one worker; keep the counters moving.
                if entryIndex & 0x3FFF == 0, localFiles > 0 {
                    progressTracker.report(files: localFiles, directories: 0, bytes: localBytes, node: job.node)
                    localFiles = 0
                    localBytes = 0
                }

                if entry.isDirectory {
                    let isPackage = PackageKind.isPackage(name: entry.name)
                    let child = FileNode(name: entry.name, isDirectory: true, isPackage: isPackage, parent: job.node)
                    child.fileID = entry.fileID
                    child.deviceID = entry.devID
                    batch.append(child)

                    let crossesVolume = entry.isMountPoint || entry.devID != rootDevID
                    // openat can block for as long as a privacy prompt goes unanswered,
                    // so publish everything listed so far (this folder included) first:
                    // a Stop meanwhile still shows it, and everything scanned under the
                    // folders before it.
                    if !crossesVolume,
                       gate.willOpen(child, worker: worker, publishing: &batch, into: job.node) {
                        #if DEBUG
                        debugHoldIfBlocked(child)
                        #endif
                        let childFD = entry.name.withCString { namePtr in
                            openat(job.fd, namePtr, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                        }
                        // The bulk listing reports a synthetic ID for firmlinked
                        // folders (/Users, /Applications, …); the opened folder's own
                        // inode is what a later path lookup will see.
                        var opened = stat()
                        let identity = childFD >= 0 && fstat(childFD, &opened) == 0 ? opened : nil
                        gate.didOpen(child, worker: worker, identity: identity)
                        if childFD >= 0 {
                            queue.push(ScanJob(fd: childFD, node: child))
                        }
                        // EACCES/EPERM/ENOENT (raced away)/ELOOP (shouldn't happen: we
                        // only ever openat() entries getattrlistbulk reported as VDIR)
                        // — skip silently, child stays an empty directory node.
                    }
                } else {
                    var size = entry.allocSize
                    var fileCount = 1
                    var hardLink = FileNode.HardLink.none
                    if entry.hasFileAttrs, entry.linkCount > 1 {
                        let firstTime = hardlinks.claim(devID: entry.devID, fileID: entry.fileID)
                        hardLink = firstTime ? .primary : .secondary
                        if !firstTime {
                            size = 0
                            fileCount = 0
                        }
                    }
                    let child = FileNode(name: entry.name, isDirectory: false, size: size, fileCount: fileCount, parent: job.node)
                    child.fileID = entry.fileID
                    child.deviceID = entry.devID
                    child.hardLink = hardLink
                    batch.append(child)
                    localFiles += fileCount
                    localBytes += size
                }
            }
        } catch is CancellationError {
            // Fall through: still publish, report progress and finish() below so
            // the queue can drain and other workers can terminate.
        } catch {
            // getattrlistbulk itself failed (e.g. EACCES opening was fine but the
            // read faults, or the fd was invalidated by a racing delete) — skip
            // the rest of this directory's contents, never crash.
        }

        gate.attach(&batch, to: job.node)
        close(job.fd)
        progressTracker.report(files: localFiles, directories: 1, bytes: localBytes, node: job.node)
        queue.finish(worker: worker)
    }

    #if DEBUG
    /// DISCOTECH_TEST_BLOCK_OPEN=<path substring>[@seconds]: in the first scan of the
    /// process, opening a folder whose path contains the substring waits that long
    /// (default an hour) right where a pending macOS privacy prompt blocks `openat`.
    /// Later scans (Rescan) are left alone.
    let debugBlock: (substring: String, seconds: Double)?
    #endif


    private func raiseFileDescriptorLimit() {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
        let target = min(limit.rlim_max, 65536)
        guard limit.rlim_cur < target else { return }
        limit.rlim_cur = target
        _ = setrlimit(RLIMIT_NOFILE, &limit) // best-effort
    }

    // MARK: - Iterative finalize

    /// Bottom-up size/fileCount rollup and child sort, equivalent to
    /// `FileNode.finalize()` but iterative — see the stack-safety note above.
    private func finalizeIterative(_ root: FileNode) {
        guard root.isDirectory else { return }

        final class Frame {
            let node: FileNode
            var nextChildIndex = 0
            init(_ node: FileNode) { self.node = node }
        }

        var stack = [Frame(root)]
        while let frame = stack.last {
            if frame.nextChildIndex < frame.node.children.count {
                let child = frame.node.children[frame.nextChildIndex]
                frame.nextChildIndex += 1
                if child.isDirectory {
                    stack.append(Frame(child))
                }
            } else {
                var size: Int64 = 0
                var count = 0
                for child in frame.node.children {
                    size += child.size
                    count += child.fileCount
                }
                frame.node.size += size
                frame.node.fileCount += count
                frame.node.children.sort { $0.size > $1.size }
                stack.removeLast()
            }
        }
    }
}
