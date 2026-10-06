import Foundation

/// READ-ONLY: this file only ever *lists* snapshots. It must never run
/// `tmutil deletelocalsnapshots`, `tmutil thinlocalsnapshots`, `tmutil localsnapshot`
/// (which creates one), `diskutil apfs deleteSnapshot`, or anything else that changes
/// the system, and never requests admin rights.
struct LocalSnapshot: Identifiable, Hashable, Sendable {
    var id: String { name }
    /// e.g. "com.apple.TimeMachine.2026-09-24-101500.local"
    let name: String
    let date: Date?
    /// Best available estimate of the space this snapshot holds, nil if unknown.
    let estimatedSize: Int64?
}

enum Snapshots {
    /// Local APFS snapshots of the volume containing `volumeURL`. Never throws;
    /// returns [] if unavailable. May block briefly (subprocess, ~3s worst case);
    /// call off the main thread.
    ///
    /// What macOS 26 offers here without admin rights, tried empirically on this
    /// machine (no Time Machine local snapshots were present, only sealed-system
    /// `com.apple.os.update-*` ones, so this reflects command *behavior*, not a
    /// snapshot-format guess):
    ///
    /// - `tmutil listlocalsnapshotdates <mount>` — used below. It's the one command
    ///   whose output is *exactly* the argument `tmutil deletelocalsnapshots <date>`
    ///   wants, so every snapshot this returns is provably removable with
    ///   `tmutil deletelocalsnapshots <date>`. It resolves to the enclosing volume
    ///   *group*, not the literal mount passed in: `tmutil listlocalsnapshotdates /`
    ///   and `tmutil listlocalsnapshotdates /System/Volumes/Data` returned identical
    ///   results on this machine, so scanning `/` correctly reaches the Data
    ///   volume's Time Machine snapshots with no manual remapping. It also accepted
    ///   an unrelated external volume path fine (empty result, no error). An
    ///   unmounted/bogus path exits non-zero fast (~10ms) rather than hanging.
    /// - `tmutil listlocalsnapshots <mount>` — also lists non-Time-Machine local
    ///   snapshots (`com.apple.os.update-*`, made by the sealed system volume
    ///   updater, distinct from Time Machine's local snapshots). Those have no
    ///   tmutil-recognized date and aren't necessarily what
    ///   `deletelocalsnapshots <date>` targets, so they're deliberately left out
    ///   here rather than shown next to a delete command that might not remove them.
    /// - `diskutil apfs listSnapshots <volume> -plist` — corroborates names/UUIDs
    ///   but its plist has **no size field at all**: only `SnapshotName`,
    ///   `SnapshotUUID`, `SnapshotXID`, and three booleans (`Purgeable`, `RevertTo`,
    ///   `RootTo`, `LimitingContainerShrink`). `Purgeable` is a flag, not a byte
    ///   count.
    /// - `fs_snapshot_list` / `getattrlistbulk` on a snapshot namespace — no public,
    ///   Swift-callable API for either without linking a private framework; not used.
    ///
    /// Conclusion: there is no honest per-snapshot size available read-only without
    /// admin rights, so `estimatedSize` is always nil, per instructions to return
    /// nil rather than invent one.
    static func list(volumeURL: URL) -> [LocalSnapshot] {
        guard let output = run("/usr/bin/tmutil", ["listlocalsnapshotdates", volumeURL.path], timeout: 3) else {
            return []
        }

        // Each snapshot line is a bare "yyyy-MM-dd-HHmmss" token; everything else
        // (the "Snapshot dates for volume group containing disk ...:" header, blank
        // lines) is ignored by pattern rather than by position, so wording changes
        // in tmutil's header don't silently break this.
        let token = try? NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}-\d{6}$"#)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        // Not a claim about the true creation time zone (undocumented); chosen so
        // parsing a line and reformatting it back is a lossless round trip with no
        // DST-gap ambiguity, so a snapshot's name keeps the exact date tmutil gave us.
        formatter.timeZone = TimeZone(identifier: "UTC")

        var results: [(raw: String, date: Date?)] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let token, token.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil else {
                continue
            }
            results.append((raw: line, date: formatter.date(from: line)))
        }

        return results
            .sorted { $0.raw > $1.raw }  // token is zero-padded ISO-like: lexicographic == chronological
            .map { LocalSnapshot(name: "\(namePrefix)\($0.raw)\(nameSuffix)", date: $0.date, estimatedSize: nil) }
    }

    private static let namePrefix = "com.apple.TimeMachine."
    private static let nameSuffix = ".local"

    // MARK: - Subprocess with timeout

    /// Runs `launchPath args` and returns stdout as a string, or nil on any failure
    /// (missing binary, non-zero exit, or exceeding `timeout`). Never throws.
    /// Kills the child on timeout rather than blocking indefinitely.
    private static func run(_ launchPath: String, _ args: [String], timeout: TimeInterval) -> String? {
        guard FileManager.default.isExecutableFile(atPath: launchPath) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()  // discarded; never read, so never blocks us

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            return nil
        }

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            // Give it a brief grace period to actually exit before giving up; if it
            // still won't, don't block the caller waiting on a misbehaving child.
            guard exited.wait(timeout: .now() + 1) == .success else { return nil }
        }

        guard process.terminationStatus == 0 else { return nil }
        // Safe without deadlock risk here: the process has already exited, so its
        // stdout write end is closed and this drains whatever was buffered and
        // returns immediately (output is at most a few dozen short lines).
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
