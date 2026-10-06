import Darwin
import Foundation

/// Safety stoppers: what must never be put in the Crate (and so never moved to the Trash).
///
/// Every rule lives in `Rules` below — one place to read, one place to change. A check
/// costs at most one `lstat` (for the file-flag rules), and results are cached per path,
/// so the sidebar can ask for every visible row on every redraw.
enum Safety {
    /// Short, user-facing reason `node` must not go to the Trash, or nil if it's fine.
    /// Synthetic accounting nodes are handled by `AppState.collectBlockReason`.
    static func protectionReason(for node: FileNode) -> String? {
        guard !node.isSynthetic else { return nil }
        return protectionReason(forPath: node.path)
    }

    /// Path-based variant (also used for paths dropped from outside the tree).
    static func protectionReason(forPath rawPath: String) -> String? {
        if let cached = cache.value(for: rawPath) { return cached.reason }
        let reason = evaluate(rawPath)
        cache.set(Cached(reason: reason), for: rawPath)
        return reason
    }

    /// Same rules, bypassing the per-path cache: file flags can change after a lookup,
    /// so the final check right before moving something to the Trash re-reads them.
    static func protectionReasonUncached(forPath rawPath: String) -> String? {
        evaluate(rawPath)
    }

    // MARK: - Sensitive locations

    /// Where an item that is allowed in the Crate still deserves a second look: a short
    /// phrase completing "X is …" ("in your Library folder, where apps keep …"), or nil
    /// when it sits somewhere ordinary. These are warnings, never refusals; hard stops
    /// live in `Rules`. Always evaluated on the live path, right before the move.
    static func sensitivityReason(forPath rawPath: String) -> String? {
        let path = canonical(rawPath)
        let home = Rules.home
        func inside(_ folder: String) -> Bool { path == folder || path.hasPrefix(folder + "/") }

        let userLibrary = home + "/Library"
        if inside(userLibrary) {
            let named: [(String, String)] = [
                ("Application Support", "in Application Support, where apps keep their data and settings"),
                ("Preferences", "in Preferences, where apps keep their settings"),
                ("Keychains", "in Keychains, where passwords and certificates are stored"),
                ("Containers", "in an app’s sandbox container, where it keeps its data"),
                ("Group Containers", "in an app’s shared container, where it keeps its data"),
                ("Mail", "in Mail’s data folder"),
                ("Messages", "in Messages’ data folder"),
                ("Safari", "in Safari’s data folder"),
            ]
            if let hit = named.first(where: { inside(userLibrary + "/" + $0.0) }) { return hit.1 }
            return "in your Library folder, where macOS and apps keep their data"
        }
        if inside("/Library") { return "in the system-wide Library folder, shared by every user of this Mac" }
        if inside("/Applications") || inside(home + "/Applications") { return "in an Applications folder" }
        if path.lowercased().hasSuffix(".app") { return "an app" }
        if inside("/usr/local") || inside("/opt") {
            return "in a folder for command-line tools and developer software"
        }
        if inside("/private/var") || inside("/private/etc") || inside("/var") || inside("/etc") {
            return "in a system folder that macOS and its services rely on"
        }
        // Hidden folders straight under home hold credentials and tool configuration
        // (.ssh, .config, .gnupg, …).
        if path.hasPrefix(home + "/.") {
            return "in a hidden configuration folder in your home folder, which may hold keys or settings"
        }
        return nil
    }

    // MARK: - Rules

    private enum Rules {
        /// These folders and everything inside them belong to macOS.
        static let systemTrees = [
            "/System",            // sealed system volume; also firmlinked data-volume paths
            "/bin", "/sbin",
            "/usr",               // except /usr/local, see `systemTreeExceptions`
            "/private/var/db",    // system databases (TCC, launchd, …)
            "/private/var/vm",    // swap and sleep image
            "/var/db", "/var/vm", // same, via the /var symlink
            "/Library/Apple",     // Apple-installed system components
            "/cores",             // kernel core dumps area
        ]
        static let systemTreeExceptions = ["/usr/local"]

        /// These folders themselves must stay; their contents are fair game.
        static let keepFolderItself: [String: String] = [
            "/Applications": "The Applications folder itself stays; apps inside it can go.",
            "/Applications/Utilities": "The Utilities folder itself stays.",
            "/Users": "This folder holds every user’s home folder.",
            "/Users/Shared": "The Shared folder itself stays; what’s inside it can go.",
            "/Library": "The system Library folder itself stays.",
            "/Volumes": "This is where macOS mounts disks.",
            "/private": "Part of macOS; removing it would break your Mac.",
            "/private/var": "Part of macOS; removing it would break your Mac.",
            "/private/etc": "Part of macOS; removing it would break your Mac.",
            "/private/tmp": "Part of macOS; removing it would break your Mac.",
            // Root-level links into /private (lstat sees the link itself).
            "/etc": "Part of macOS; removing it would break your Mac.",
            "/var": "Part of macOS; removing it would break your Mac.",
            "/tmp": "Part of macOS; removing it would break your Mac.",
        ]

        /// The current user's home folder, resolved once.
        static let home = Safety.canonical(NSHomeDirectory())

        /// Home-folder children that must stay themselves (contents are fine).
        static let homeFolders = ["Library", "Documents", "Desktop", "Downloads",
                                  "Pictures", "Music", "Movies", "Public"]

        static let systemReason = "Part of macOS; removing it would break your Mac."
        static let sipReason = "Protected by macOS System Integrity Protection."
        static let lockedReason = "This item is locked, so it can’t be moved to the Trash."
        static let trashFolderReason = "This is a Trash folder. Empty the Trash in Finder to free its space."
        static let inTrashReason = "Already in the Trash. Empty the Trash in Finder to free this space."
    }

    private static func evaluate(_ rawPath: String) -> String? {
        let path = canonical(rawPath)

        // Disk roots.
        if path == "/" { return "This is your startup disk." }
        if isVolumeRoot(path) { return "This is the top level of a disk." }

        // macOS-owned trees.
        let excepted = Rules.systemTreeExceptions.contains { path == $0 || path.hasPrefix($0 + "/") }
        if !excepted, Rules.systemTrees.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return Rules.systemReason
        }

        // Folders that must stay, though their contents may go.
        if let reason = Rules.keepFolderItself[path] { return reason }
        let home = Rules.home
        if path == home { return "This is your home folder." }
        if isDirectChild(path, of: "/Users") { return "This is a user’s home folder." }
        if let name = Rules.homeFolders.first(where: { path == home + "/" + $0 }) {
            return "Your \(name) folder itself stays; what’s inside it can go."
        }

        // A Trash and what's already in one: moving it "to the Trash" again would free
        // nothing. Your own Trash, and each disk's `.Trashes`.
        let trash = home + "/.Trash"
        if path == trash || path.hasSuffix("/.Trashes") { return Rules.trashFolderReason }
        if path.hasPrefix(trash + "/") || path.contains("/.Trashes/") { return Rules.inTrashReason }

        // File flags: SIP-restricted or locked (immutable / undeletable).
        var st = stat()
        if lstat(rawPath, &st) == 0 {
            let flags = UInt32(st.st_flags)
            if flags & UInt32(SF_RESTRICTED) != 0 { return Rules.sipReason }
            if flags & UInt32(SF_IMMUTABLE | UF_IMMUTABLE | SF_NOUNLINK) != 0 { return Rules.lockedReason }
        }
        return nil
    }

    /// Maps paths seen through the data volume's own mount point back to the
    /// firmlinked view (`/System/Volumes/Data/Users/x` → `/Users/x`), and drops a
    /// trailing slash, so one rule set covers both spellings.
    private static func canonical(_ path: String) -> String {
        var p = path
        if p.count > 1, p.hasSuffix("/") { p.removeLast() }
        let data = "/System/Volumes/Data"
        if p == data { return "/" }
        if p.hasPrefix(data + "/") { p = String(p.dropFirst(data.count)) }
        return p
    }

    /// `/Volumes/<name>` is a mount point for another disk.
    private static func isVolumeRoot(_ path: String) -> Bool { isDirectChild(path, of: "/Volumes") }

    private static func isDirectChild(_ path: String, of folder: String) -> Bool {
        let prefix = folder + "/"
        guard path.count > prefix.count, path.hasPrefix(prefix) else { return false }
        return !path.dropFirst(prefix.count).contains("/")
    }

    // MARK: - Cache

    private struct Cached { let reason: String? }

    private static let cache = PathCache()

    /// Small thread-safe cache; cleared wholesale when it grows large.
    private final class PathCache: @unchecked Sendable {
        private var storage: [String: Cached] = [:]
        private let lock = NSLock()
        func value(for key: String) -> Cached? { lock.lock(); defer { lock.unlock() }; return storage[key] }
        func set(_ value: Cached, for key: String) {
            lock.lock(); defer { lock.unlock() }
            if storage.count > 20_000 { storage.removeAll(keepingCapacity: true) }
            storage[key] = value
        }
    }
}
