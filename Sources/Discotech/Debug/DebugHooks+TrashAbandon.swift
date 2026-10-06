#if DEBUG
import AppKit

/// DISCOTECH_TEST_TRASH_ABANDON=close|rescan|drives|theme (with DISCOTECH_AUTOCOLLECT=2):
/// opens the Crate review and starts a run whose `trashCollected` is replaced by a stand-in
/// that never touches the disk (nothing is moved, checked or opened; a "move" only counts).
/// Its first item raises the sensitive-item prompt; while the prompt is up the sheet goes
/// away: closed, by a rescan, by All Drives, or by a theme switch (which rebuilds the
/// window). Then logs whether and how the run ended.
extension DebugHooks {
    static var trashAbandonTest: String? { ProcessInfo.processInfo.environment["DISCOTECH_TEST_TRASH_ABANDON"] }
    static var trashAbandonOpened = false
    private static var trashAbandonStarted = false
    private static var trashRunEnded = false
    private static var stubMoves = 0

    private static func trashLog(_ text: String) {
        FileHandle.standardError.write(Data("trash abandon test: \(text)\n".utf8))
    }

    static func trashAbandonLog(_ text: String) {
        if trashAbandonTest != nil { trashLog(text) }
    }

    private static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && !($0 is NSPanel) && $0.contentView != nil && $0.sheetParent == nil }
    }

    static func startTrashAbandonTest(_ session: TrashSession, _ state: AppState) {
        guard trashAbandonTest != nil, !trashAbandonStarted else { return }
        trashAbandonStarted = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            trashLog("starting a run of \(state.collected.count) item(s) with the stand-in (nothing on disk is touched)")
            session.start(state)  // the call the "Move to Trash" confirmation makes
        }
    }

    static func trashPromptShown(_ state: AppState, close: @escaping () -> Void) {
        guard let mode = trashAbandonTest else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            trashLog("prompt is up; making the sheet go away: \(mode)")
            switch mode {
            case "rescan": state.rescan()
            case "drives": state.backToStart()
            case "theme": ThemeStore.shared.theme = ThemeStore.shared.theme == .neon ? .studio : .neon
            case "quit": NSApp.terminate(nil)
            case "closewindow": mainWindow?.performClose(nil)
            default: close()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                trashLog("sheet still attached: \(mainWindow?.attachedSheet != nil), its own sheet (the prompt): \(mainWindow?.attachedSheet?.attachedSheet != nil)")
                trashLog(trashRunEnded ? "run ended" : "FAIL the run is still waiting on the prompt 3 s after the sheet went away")
                let fromCurrentTree = state.root.map { root in state.collected.allSatisfy { $0.isDescendant(of: root) } } ?? state.collected.isEmpty
                trashLog("Crate holds \(state.collected.count) item(s), all from the current tree: \(fromCurrentTree); stand-in moves: \(stubMoves)")
                guard mainWindow?.attachedSheet != nil else { return }
                close()  // what its Done button does
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    trashLog("after Done: sheet still attached: \(mainWindow?.attachedSheet != nil)")
                }
            }
        }
    }

    /// Stands in for `AppState.trashCollected`: the same loop shape (stop at an item
    /// boundary, ask about a sensitive item first), but a "move" only counts.
    static func stubTrashRun(_ state: AppState, _ progress: (FileNode, Int) -> Void,
                             _ confirmSensitive: (FileNode, String) async -> AppState.SensitiveDecision)
        async -> AppState.TrashOutcome {
        var outcome = AppState.TrashOutcome()
        for (position, node) in state.collected.enumerated() {
            if !outcome.stopped, Task.isCancelled { outcome.stopped = true }
            if outcome.stopped { continue }
            progress(node, position)
            if position == 0 {
                trashLog("asking about \(node.name)")
                let decision = await confirmSensitive(node, "a test item (nothing will be moved)")
                trashLog("the prompt returned \(decision)")
                switch decision {
                case .moveIt: break
                case .skip: outcome.skipped += 1; continue
                case .stop: outcome.stopped = true; continue
                }
            }
            stubMoves += 1  // the stand-in's "move": nothing on disk is touched
            outcome.moved += 1
        }
        trashRunEnded = true
        trashLog("run ended: moved=\(outcome.moved) stopped=\(outcome.stopped) skipped=\(outcome.skipped)")
        return outcome
    }
}
#endif
