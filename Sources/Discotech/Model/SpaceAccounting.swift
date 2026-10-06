import Darwin
import Foundation

/// Explains the grey "System Data" mystery: after a full-volume scan, appends synthetic
/// top-level children to `root` so `root.size` becomes the disk's whole capacity, broken
/// into what the scan found plus what it can't ever find as files:
///
/// - **Free** — `volumeAvailableCapacityKey`: available to apps right now.
/// - **Purgeable** — `volumeAvailableCapacityForImportantUsageKey` minus Free: counted as
///   used, but macOS reclaims it on demand (caches, local snapshots, re-fetchable data).
/// - **Unseen** — `total − available − scanned − purgeable`: used space the scan couldn't
///   attribute to any file. Broken down, read-only, into whatever this machine's other
///   APFS-container volumes (VM/swap, Preboot, Recovery, Update — never the scanned
///   volume itself) and `Snapshots.list` can account for, with any leftover kept as a
///   single "Other" child so the numbers still add up.
///
/// `annotate` does real (if read-only) I/O — `diskutil info`/`diskutil apfs list` and
/// `Snapshots.list`'s `tmutil` call — so it must never run on the main actor; see the
/// `Task.detached` wrapping the call in `AppState.startScan`.
enum SpaceAccounting {

    /// If `scannedURL` is a volume root, appends synthetic `.freeSpace`, `.purgeable` and
    /// `.hidden` children to `root` (with `.hidden`/`.snapshot` children under `.hidden`
    /// for whatever of Unseen could be attributed), then re-sorts `root.children`.
    /// Leaves `root` untouched for a non-root (ordinary folder) scan. Keeps
    /// `root.size == sum(root.children.size)` (and the same for the `.hidden` node and
    /// its own children) so the sunburst's proportions stay correct.
    static func annotate(root: FileNode, scannedURL: URL) {
        guard isVolumeRoot(scannedURL), let cap = capacities(for: scannedURL) else { return }

        let scannedSize = root.size // real files the scan found, before we add anything
        let free = cap.available
        let purgeable = max(0, cap.availableForImportantUsage - cap.available)
        let unseenTotal = max(0, cap.total - free - scannedSize - purgeable)

        let freeNode = FileNode(name: "Free", isDirectory: false, size: free, parent: root, kind: .freeSpace)
        let purgeableNode = FileNode(name: "Purgeable", isDirectory: false, size: purgeable, parent: root, kind: .purgeable)

        let breakdown = unseenBreakdown(for: scannedURL, budget: unseenTotal)
        let hiddenNode = FileNode(name: "Unseen", isDirectory: !breakdown.isEmpty, size: unseenTotal,
                                   children: breakdown, parent: root, kind: .hidden)
        for child in breakdown { child.parent = hiddenNode }

        root.children.append(contentsOf: [freeNode, purgeableNode, hiddenNode])
        root.children.sort { $0.size > $1.size }
        root.size = scannedSize + free + purgeable + unseenTotal

        #if DEBUG
        FileHandle.standardError.write(Data("""
        SpaceAccounting: total=\(cap.total) available=\(cap.available) \
        availableImportant=\(cap.availableForImportantUsage) scanned=\(scannedSize) \
        free=\(free) purgeable=\(purgeable) unseen=\(unseenTotal) \
        (breakdown: \(breakdown.map { "\($0.name)=\($0.size)" }.joined(separator: ", ")))\n
        """.utf8))
        #endif
    }

    // MARK: - Volume capacity

    private struct Capacities {
        let available: Int64
        let availableForImportantUsage: Int64
        let total: Int64
    }

    /// True only for a volume's own mount point — never a folder within it — so an
    /// ordinary folder scan never gets synthetic children. `statfs` rather than
    /// `URLResourceValues`: it hands back the mount point (`f_mntonname`) directly, no
    /// ambiguity about which resource key/property pairs with it.
    private static func isVolumeRoot(_ url: URL) -> Bool {
        var st = statfs()
        guard statfs(url.path, &st) == 0 else { return false }
        let mountPoint = withUnsafeBytes(of: st.f_mntonname) { raw -> String in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        func normalized(_ path: String) -> String { path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path }
        return normalized(url.standardizedFileURL.path) == normalized(mountPoint)
    }

    private static func capacities(for url: URL) -> Capacities? {
        let keys: Set<URLResourceKey> = [
            .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys),
              let available = values.volumeAvailableCapacity, let total = values.volumeTotalCapacity else { return nil }
        let importantAvailable = values.volumeAvailableCapacityForImportantUsage ?? Int64(available)
        return Capacities(available: Int64(available), availableForImportantUsage: importantAvailable, total: Int64(total))
    }

    // MARK: - Unseen breakdown

    /// Roles of sibling APFS volumes that hold real used space but are never part of the
    /// scanned (System/Data) volume, so the scan structurally can't see them.
    private static let breakdownRoles: [String: String] = [
        "VM": "Swap & Sleep Image",
        "Preboot": "Preboot",
        "Recovery": "Recovery",
        "Update": "Software Update Staging",
    ]

    /// Best-effort, read-only breakdown of `budget` bytes of Unseen space, as `.hidden`
    /// children (other same-container volumes, plus a residual "Other" for whatever's
    /// left) and `.snapshot` children (from `Snapshots.list`). Never exceeds `budget`:
    /// if the known pieces would sum past it, they're scaled down proportionally rather
    /// than risk `hidden.size` no longer matching `sum(hidden.children.size)`. Returns
    /// `[]` (no breakdown, so `Unseen` stays a plain leaf) when nothing could be found.
    private static func unseenBreakdown(for scannedURL: URL, budget: Int64) -> [FileNode] {
        let volumes = containerReference(for: scannedURL).map(otherVolumes(inContainer:)) ?? []
        let snapshots = Snapshots.list(volumeURL: scannedURL)

        let knownTotal = volumes.reduce(Int64(0)) { $0 + $1.size } + snapshots.reduce(Int64(0)) { $0 + ($1.estimatedSize ?? 0) }
        let scale = (knownTotal > budget && knownTotal > 0) ? Double(budget) / Double(knownTotal) : 1.0

        var children: [FileNode] = []
        for volume in volumes {
            let size = Int64((Double(volume.size) * scale).rounded())
            guard size > 0 else { continue }
            children.append(FileNode(name: volume.name, isDirectory: false, size: size, kind: .hidden))
        }
        for snapshot in snapshots {
            // `estimatedSize` is nil whenever macOS won't hand us a real per-snapshot byte
            // count (see `Snapshots.list`'s doc comment) — listed at 0 bytes rather than
            // guessed, so it can never double-count against Purgeable or another entry here.
            let raw = snapshot.estimatedSize ?? 0
            let size = max(0, Int64((Double(raw) * scale).rounded()))
            children.append(FileNode(name: snapshotDisplayName(snapshot), isDirectory: false, size: size, kind: .snapshot))
        }

        guard !children.isEmpty else { return [] }
        let attributed = children.reduce(Int64(0)) { $0 + $1.size }
        let residual = max(0, budget - attributed)
        if residual > 0 {
            children.append(FileNode(name: "Other", isDirectory: false, size: residual, kind: .hidden))
        }
        return children.sorted { $0.size > $1.size }
    }

    private static func snapshotDisplayName(_ snapshot: LocalSnapshot) -> String {
        guard let date = snapshot.date else { return snapshot.name }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Snapshot — \(formatter.string(from: date))"
    }

    // MARK: - diskutil (read-only: `info` / `apfs list` only)

    private static func containerReference(for url: URL) -> String? {
        guard let data = run("/usr/sbin/diskutil", ["info", "-plist", url.path], timeout: 3),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else { return nil }
        return plist["APFSContainerReference"] as? String
    }

    private static func otherVolumes(inContainer containerID: String) -> [(name: String, size: Int64)] {
        guard let data = run("/usr/sbin/diskutil", ["apfs", "list", "-plist"], timeout: 5),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let containers = plist["Containers"] as? [[String: Any]],
              let container = containers.first(where: { $0["ContainerReference"] as? String == containerID }),
              let volumes = container["Volumes"] as? [[String: Any]]
        else { return [] }

        var results: [(String, Int64)] = []
        for volume in volumes {
            guard let roles = volume["Roles"] as? [String],
                  let role = roles.first(where: { breakdownRoles[$0] != nil }),
                  let base = breakdownRoles[role],
                  let inUse = (volume["CapacityInUse"] as? NSNumber)?.int64Value
            else { continue }
            let label = (volume["Name"] as? String).map { "\(base) (\($0))" } ?? base
            results.append((label, inUse))
        }
        return results
    }

    /// Runs a read-only `diskutil`/`tmutil`-style command and returns stdout, or nil on
    /// any failure (missing binary, non-zero exit, exceeding `timeout`). Never throws,
    /// kills the child on timeout rather than blocking indefinitely. Mirrors the same
    /// pattern in `Snapshots.run` (kept private/duplicated rather than shared, since
    /// neither file is allowed to depend on the other's internals).
    private static func run(_ launchPath: String, _ args: [String], timeout: TimeInterval) -> Data? {
        guard FileManager.default.isExecutableFile(atPath: launchPath) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe() // discarded; never read, so never blocks us

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            return nil
        }

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            guard exited.wait(timeout: .now() + 1) == .success else { return nil }
        }

        guard process.terminationStatus == 0 else { return nil }
        return outPipe.fileHandleForReading.readDataToEndOfFile()
    }
}
