#if DEBUG
import Foundation

/// DISCOTECH_TEST_BLOCK_OPEN, see `Scanner.debugBlock`.
extension Scanner {
    private nonisolated(unsafe) static var debugBlockClaimed = false

    /// Main thread only (scanners are made by `AppState`).
    static func claimDebugBlock() -> (substring: String, seconds: Double)? {
        guard !debugBlockClaimed,
              let spec = ProcessInfo.processInfo.environment["DISCOTECH_TEST_BLOCK_OPEN"], !spec.isEmpty
        else { return nil }
        debugBlockClaimed = true
        let parts = spec.split(separator: "@", maxSplits: 1).map(String.init)
        return (parts[0], parts.count > 1 ? Double(parts[1]) ?? 3600 : 3600)
    }

    func debugHoldIfBlocked(_ child: FileNode) {
        guard let block = debugBlock,
              let path = gate.ifUnsealed({ child.path }), path.contains(block.substring) else { return }
        ScanLog.line("test block: holding open of \(path) for \(block.seconds)s")
        Thread.sleep(forTimeInterval: block.seconds)
        ScanLog.line("test block: woke on \(path); tree sealed=\(gate.isSealed)")
    }
}
#endif
