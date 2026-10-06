import AppKit
import SwiftUI

// MARK: - Node lookup (drag payloads are path strings)

extension AppState {
    /// Resolves an absolute path to a node in the current tree by walking path
    /// components down from `root`. Used for drag payloads (sidebar rows, chart).
    func node(atPath path: String) -> FileNode? {
        guard let root else { return nil }
        let rootPath = root.path
        if path == rootPath { return root }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(prefix) else { return nil }
        var node = root
        for component in path.dropFirst(prefix.count).split(separator: "/") {
            guard let next = node.children.first(where: { $0.name == component }) else { return nil }
            node = next
        }
        return node
    }

    /// Adds every resolvable path to the Crate. Returns how many were accepted.
    @discardableResult
    func collect(paths: [String]) -> Int {
        var n = 0
        for path in paths {
            for line in path.split(whereSeparator: \.isNewline) {
                if let node = node(atPath: String(line)) { collect(node); n += 1 }
            }
        }
        return n
    }

    /// Crate drops: adds everything that may go in and reports what was refused and why
    /// (protected by `Safety`, synthetic, or the scanned folder itself).
    func collectDropped(paths: [String]) -> (added: Int, refused: [CrateRefusal]) {
        var added = 0
        var refused: [CrateRefusal] = []
        for path in paths {
            for line in path.split(whereSeparator: \.isNewline) {
                guard let node = node(atPath: String(line)) else { continue }
                if let reason = collectBlockReason(node) {
                    let name = node.parent == nil ? FileManager.default.displayName(atPath: node.path) : node.name
                    refused.append(CrateRefusal(name: name, reason: reason))
                } else {
                    collect(node)
                    added += 1
                }
            }
        }
        return (added, refused)
    }
}

/// An item the Crate turned away, for the transient notice under the drop.
struct CrateRefusal: Equatable {
    let name: String
    let reason: String
}

// MARK: - Formatting

enum Count {
    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()
    static func string(_ n: Int) -> String { formatter.string(from: NSNumber(value: n)) ?? "\(n)" }
    static func items(_ n: Int) -> String { n == 1 ? "1 item" : "\(string(n)) items" }
    static func files(_ n: Int) -> String { n == 1 ? "1 file" : "\(string(n)) files" }
}

// MARK: - Full Disk Access

enum FullDiskAccess {
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    /// Heuristic: TCC-protected locations are only readable with Full Disk Access.
    /// `access()`/`isReadableFile` ignore TCC, so actually try to open them.
    static func isGranted() -> Bool {
        let safari = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari").path
        if (try? FileManager.default.contentsOfDirectory(atPath: safari)) != nil { return true }
        if let handle = FileHandle(forReadingAtPath: "/Library/Application Support/com.apple.TCC/TCC.db") {
            try? handle.close()
            return true
        }
        return false
    }

    static func openSettings() { NSWorkspace.shared.open(settingsURL) }
}

// MARK: - Folder picker

enum FolderPicker {
    @MainActor
    static func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder to scan."
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}

extension View {
    /// Start and scanning screens: no window title (the content carries the branding)
    /// and no toolbar backdrop, so the gradient runs edge to edge.
    @ViewBuilder func hidingWindowTitle() -> some View {
        if #available(macOS 15.0, *) {
            toolbar(removing: .title)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            toolbarBackground(.hidden, for: .windowToolbar)
        }
    }
}

extension View {
    /// Let content run under the toolbar with no toolbar backdrop.
    @ViewBuilder func hidingToolbarBackground() -> some View {
        if #available(macOS 15.0, *) {
            toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            toolbarBackground(.hidden, for: .windowToolbar)
        }
    }
}

enum Bytes {
    /// `ByteFormat` with "Zero KB" spelled as a number.
    static func string(_ bytes: Int64) -> String { bytes <= 0 ? "0 KB" : ByteFormat.string(bytes) }
}
