import Darwin
import Foundation
import Testing
@testable import Discotech

/// What `Safety.protectionReason(forPath:)` must say for a path. Paths here do not exist
/// (the lstat flag check finds nothing), so only the path rules decide.
struct ProtectionCase: Sendable, CustomTestStringConvertible {
    let path: String
    /// nil: allowed. Otherwise a fragment the refusal reason must contain.
    let reason: String?
    var testDescription: String { "\(path) -> \(reason ?? "allowed")" }
}

private let home = NSHomeDirectory()
private let systemReason = "Part of macOS"

private let protectionCases: [ProtectionCase] = [
    // Disk roots
    .init(path: "/", reason: "startup disk"),
    .init(path: "/Volumes/External", reason: "top level of a disk"),
    .init(path: "/Volumes/External/", reason: "top level of a disk"),
    // macOS-owned trees, and the boundary of each prefix
    .init(path: "/System", reason: systemReason),
    .init(path: "/System/Library/CoreServices/Finder.app", reason: systemReason),
    .init(path: "/usr", reason: systemReason),
    .init(path: "/usr/bin/ls", reason: systemReason),
    .init(path: "/bin/zsh", reason: systemReason),
    .init(path: "/sbin", reason: systemReason),
    .init(path: "/private/var/db/anything", reason: systemReason),
    .init(path: "/private/var/vm/sleepimage", reason: systemReason),
    .init(path: "/var/db/anything", reason: systemReason),
    .init(path: "/Library/Apple/System", reason: systemReason),
    .init(path: "/cores", reason: systemReason),
    .init(path: "/usr/local/bin/tool", reason: nil),
    .init(path: "/usr/local/lib/python3/x", reason: nil),
    .init(path: "/Systemic", reason: nil),
    .init(path: "/usr2/thing", reason: nil),
    .init(path: "/Library/Appleton/x", reason: nil),
    .init(path: "/private/var/folders/zz/abc/T/file", reason: nil),
    // Folders that stay themselves while their contents are fair game
    .init(path: "/Applications", reason: "Applications folder itself stays"),
    .init(path: "/Applications/Utilities", reason: "Utilities folder itself stays"),
    .init(path: "/Users", reason: "every user"),
    .init(path: "/Users/Shared", reason: "Shared folder itself stays"),
    .init(path: "/Library", reason: "system Library folder itself stays"),
    .init(path: "/Volumes", reason: "mounts disks"),
    .init(path: "/private", reason: systemReason),
    .init(path: "/private/var", reason: systemReason),
    .init(path: "/private/etc", reason: systemReason),
    .init(path: "/private/tmp", reason: systemReason),
    .init(path: "/etc", reason: systemReason),
    .init(path: "/var", reason: systemReason),
    .init(path: "/tmp", reason: systemReason),
    .init(path: "/Applications/Example.app", reason: nil),
    .init(path: "/Applications/Utilities/Example.app", reason: nil),
    .init(path: "/Users/Shared/shared-file.txt", reason: nil),
    .init(path: "/Library/Caches/com.example.nonexistent", reason: nil),
    .init(path: "/Volumes/External/Movies/film.mov", reason: nil),
    // Home and its standard folders
    .init(path: home, reason: "your home folder"),
    .init(path: "/Users/another-user-that-does-not-exist", reason: "user’s home folder"),
    .init(path: home + "/Library", reason: "Your Library folder itself stays"),
    .init(path: home + "/Documents", reason: "Your Documents folder itself stays"),
    .init(path: home + "/Desktop", reason: "Your Desktop folder itself stays"),
    .init(path: home + "/Downloads", reason: "Your Downloads folder itself stays"),
    .init(path: home + "/Pictures", reason: "Your Pictures folder itself stays"),
    .init(path: home + "/Music", reason: "Your Music folder itself stays"),
    .init(path: home + "/Movies", reason: "Your Movies folder itself stays"),
    .init(path: home + "/Public", reason: "Your Public folder itself stays"),
    .init(path: home + "/Documents/report-that-does-not-exist.pdf", reason: nil),
    .init(path: home + "/Library/Caches/com.example.nonexistent", reason: nil),
    .init(path: home + "/Downloads/installer-that-does-not-exist.dmg", reason: nil),
    .init(path: home + "/Documentsx", reason: nil),
    .init(path: home + "/some-project-that-does-not-exist", reason: nil),
    // The data volume's own mount point is the same place as the firmlinked path
    .init(path: "/System/Volumes/Data", reason: "startup disk"),
    .init(path: "/System/Volumes/Data/Users", reason: "every user"),
    .init(path: "/System/Volumes/Data/Library", reason: "system Library folder itself stays"),
    .init(path: "/System/Volumes/Data/Applications", reason: "Applications folder itself stays"),
    .init(path: "/System/Volumes/Data/usr/bin/x", reason: systemReason),
    .init(path: "/System/Volumes/Data" + home, reason: "your home folder"),
    .init(path: "/System/Volumes/Data" + home + "/Documents", reason: "Your Documents folder itself stays"),
    .init(path: "/System/Volumes/Data/Applications/Example.app", reason: nil),
    // A Trash, and what is already in one
    .init(path: home + "/.Trash", reason: "This is a Trash folder"),
    .init(path: "/Volumes/External/.Trashes", reason: "This is a Trash folder"),
    .init(path: home + "/.Trash/old.dmg", reason: "Already in the Trash"),
    .init(path: "/Volumes/External/.Trashes/501/old.dmg", reason: "Already in the Trash"),
]

@Suite("Safety: protection rules")
struct SafetyProtectionTests {
    @Test("protectionReason(forPath:) follows the rule table", arguments: protectionCases)
    func followsRuleTable(_ c: ProtectionCase) {
        let reason = Safety.protectionReason(forPath: c.path)
        if let expected = c.reason {
            #expect(reason?.contains(expected) == true, "got \(reason ?? "nil")")
        } else {
            #expect(reason == nil, "got \(reason ?? "nil")")
        }
    }

    @Test("the uncached variant gives the same answer as the cached one for every table path",
          arguments: protectionCases)
    func uncachedAgrees(_ c: ProtectionCase) {
        #expect(Safety.protectionReasonUncached(forPath: c.path) == Safety.protectionReason(forPath: c.path))
    }

    @Test("a synthetic node is never refused by path (AppState owns that refusal)")
    func syntheticNodeIsNotPathChecked() {
        let free = FileNode(name: "/System", isDirectory: false, kind: .freeSpace)
        #expect(Safety.protectionReason(for: free) == nil)
    }

    @Test("a real node is checked by its rebuilt path")
    func realNodeUsesItsPath() {
        let root = treeNode(root: "/", [dirNode("System", [fileNode("Library", 10)])])
        #expect(Safety.protectionReason(for: find("System/Library", in: root)!) == "Part of macOS; removing it would break your Mac.")
    }

    @Test("a file the user locked (uchg) is refused as locked, and allowed again once unlocked")
    func lockedFileIsRefused() async throws {
        try await withTempTree { tree in
            try tree.file("keep.txt", bytes: 10)
            let path = tree.url("keep.txt").path
            #expect(Safety.protectionReasonUncached(forPath: path) == nil)
            tree.lock("keep.txt")
            #expect(Safety.protectionReasonUncached(forPath: path) == "This item is locked, so it can’t be moved to the Trash.")
            tree.unlock("keep.txt")
            #expect(Safety.protectionReasonUncached(forPath: path) == nil)
        }
    }

    @Test("a locked folder is refused as locked")
    func lockedFolderIsRefused() async throws {
        try await withTempTree { tree in
            try tree.dir("projects")
            tree.lock("projects")
            #expect(Safety.protectionReasonUncached(forPath: tree.url("projects").path)?.contains("locked") == true)
        }
    }

    @Test("a symlink is judged as the link itself, not its target")
    func symlinkIsNotFollowed() async throws {
        try await withTempTree { tree in
            try tree.file("target.txt", bytes: 10)
            tree.lock("target.txt")
            try tree.symlink("link", to: tree.url("target.txt").path)
            #expect(Safety.protectionReasonUncached(forPath: tree.url("link").path) == nil)
        }
    }

    /// A SIP-restricted folder that is outside every path rule, so only the file flag can
    /// refuse it. Exists on stock macOS; the test is skipped where none is found.
    private static let restrictedFolder: String? = [
        "/Library/CoreAnalytics", "/Library/GPUBundles", "/Library/KernelCollections", "/Library/Updates",
        "/private/var/install",
    ].first { path in
        var st = stat()
        return lstat(path, &st) == 0 && UInt32(st.st_flags) & UInt32(SF_RESTRICTED) != 0
    }

    @Test("a SIP-restricted item outside the path rules is refused by its file flag",
          .enabled(if: SafetyProtectionTests.restrictedFolder != nil))
    func restrictedItemIsRefused() throws {
        let path = try #require(Self.restrictedFolder)
        #expect(Safety.protectionReasonUncached(forPath: path) == "Protected by macOS System Integrity Protection.")
    }
}

struct SensitivityCase: Sendable, CustomTestStringConvertible {
    let path: String
    let reason: String?
    var testDescription: String { "\(path) -> \(reason ?? "ordinary")" }
}

private let sensitivityCases: [SensitivityCase] = [
    .init(path: home + "/Library/Application Support/Some App/data.db", reason: "in Application Support, where apps keep their data and settings"),
    .init(path: home + "/Library/Preferences/com.example.plist", reason: "in Preferences, where apps keep their settings"),
    .init(path: home + "/Library/Keychains/login.keychain-db", reason: "in Keychains, where passwords and certificates are stored"),
    .init(path: home + "/Library/Containers/com.example.app", reason: "in an app’s sandbox container, where it keeps its data"),
    .init(path: home + "/Library/Group Containers/group.example", reason: "in an app’s shared container, where it keeps its data"),
    .init(path: home + "/Library/Mail/V10", reason: "in Mail’s data folder"),
    .init(path: home + "/Library/Messages/chat.db", reason: "in Messages’ data folder"),
    .init(path: home + "/Library/Safari/History.db", reason: "in Safari’s data folder"),
    .init(path: home + "/Library/Caches/com.example", reason: "in your Library folder, where macOS and apps keep their data"),
    .init(path: home + "/Library", reason: "in your Library folder, where macOS and apps keep their data"),
    .init(path: "/Library/Fonts/Example.ttf", reason: "in the system-wide Library folder, shared by every user of this Mac"),
    .init(path: "/Applications/Example.app", reason: "in an Applications folder"),
    .init(path: home + "/Applications/Example.app", reason: "in an Applications folder"),
    .init(path: home + "/Downloads/Installer.APP", reason: "an app"),
    .init(path: "/usr/local/bin/tool", reason: "in a folder for command-line tools and developer software"),
    .init(path: "/opt/example", reason: "in a folder for command-line tools and developer software"),
    .init(path: "/private/var/folders/zz/T/x", reason: "in a system folder that macOS and its services rely on"),
    .init(path: "/var/log/system.log", reason: "in a system folder that macOS and its services rely on"),
    .init(path: "/etc/hosts", reason: "in a system folder that macOS and its services rely on"),
    .init(path: "/private/etc/hosts", reason: "in a system folder that macOS and its services rely on"),
    .init(path: home + "/.ssh/id_ed25519", reason: "in a hidden configuration folder in your home folder, which may hold keys or settings"),
    .init(path: home + "/.config/tool", reason: "in a hidden configuration folder in your home folder, which may hold keys or settings"),
    .init(path: "/System/Volumes/Data/Library/Fonts/x", reason: "in the system-wide Library folder, shared by every user of this Mac"),
    .init(path: home + "/Documents/report.pdf", reason: nil),
    .init(path: home + "/Downloads/film.mov", reason: nil),
    .init(path: home, reason: nil),
    .init(path: "/Volumes/External/photos/img.jpg", reason: nil),
    .init(path: "/Volumes/External/.hidden/x", reason: nil),
    .init(path: home + "/LibraryX/x", reason: nil),
    .init(path: "/Libraryx/x", reason: nil),
    .init(path: "/usr/localx/x", reason: nil),
    .init(path: "/optical/x", reason: nil),
]

@Suite("Safety: sensitive locations")
struct SafetySensitivityTests {
    @Test("sensitivityReason(forPath:) follows the wording table", arguments: sensitivityCases)
    func followsWordingTable(_ c: SensitivityCase) {
        #expect(Safety.sensitivityReason(forPath: c.path) == c.reason)
    }
}
