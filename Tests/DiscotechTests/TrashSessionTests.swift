import Combine
import Foundation
import Testing
@testable import Discotech

/// `TrashSession` drives a trashing run and pauses it on a sensitive-item prompt. These tests
/// inject a stand-in for `AppState.trashCollected` through the session's `runner` seam, so
/// the run asks its question exactly as the real one does but nothing is checked, opened or
/// moved: the stand-in only records what it was told.
@MainActor
@Suite("TrashSession")
struct TrashSessionTests {
    /// What the stand-in saw.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _decisions: [AppState.SensitiveDecision] = []
        private var _moved = 0
        private var _runs = 0
        var decisions: [AppState.SensitiveDecision] { lock.withLock { _decisions } }
        var moved: Int { lock.withLock { _moved } }
        var runs: Int { lock.withLock { _runs } }
        func ran() { lock.withLock { _runs += 1 } }
        func decided(_ d: AppState.SensitiveDecision) { lock.withLock { _decisions.append(d) } }
        func movedOne() { lock.withLock { _moved += 1 } }
    }

    /// A stand-in run: asks about the first item, then "moves" (counts) the rest unless told
    /// to stop or skip. It never touches the disk.
    private func session(recording r: Recorder) -> TrashSession {
        TrashSession(runner: { state, progress, confirm in
            r.ran()
            var outcome = AppState.TrashOutcome()
            for (position, node) in state.collected.enumerated() {
                if !outcome.stopped, Task.isCancelled { outcome.stopped = true }
                if outcome.stopped { continue }
                progress(node, position)
                if position == 0 {
                    let decision = await confirm(node, "a test item")
                    r.decided(decision)
                    switch decision {
                    case .moveIt: break
                    case .skip: outcome.skipped += 1; continue
                    case .stop: outcome.stopped = true; continue
                    }
                }
                r.movedOne()
                outcome.moved += 1
            }
            return outcome
        })
    }

    private func browsingState(_ tree: TempTree, defaults: UserDefaults) async throws -> (AppState, [FileNode]) {
        try tree.file("one.txt", bytes: 5_000)
        try tree.file("two.txt", bytes: 5_000)
        let state = try await scannedState(tree.root, defaults: defaults)
        let nodes = [find("one.txt", in: state.root!)!, find("two.txt", in: state.root!)!]
        nodes.forEach(state.collect)
        return (state, nodes)
    }

    private func awaitPrompt(_ s: TrashSession) async throws {
        try await awaitValue(s.$warning.map { $0 != nil }, "the sensitive-item prompt") { $0 }
    }

    private func awaitFinished(_ s: TrashSession) async throws {
        try await awaitValue(s.$phase, "the run to finish") { $0 == .finished }
    }

    @Test("a prompt left pending when the sheet goes away resolves to Stop, the run ends, and nothing is moved")
    func abandonedPromptStops() async throws {
        try await withTempTree { tree in
            try await withIsolatedDefaults { defaults in
                let (state, nodes) = try await browsingState(tree, defaults: defaults)
                let recorder = Recorder()
                let session = session(recording: recorder)
                session.start(state)
                try await awaitPrompt(session)

                session.abandon()
                try await awaitFinished(session)

                #expect(recorder.decisions == [.stop])
                #expect(recorder.moved == 0)
                #expect(session.warning == nil)
                #expect(session.outcome.stopped)
                #expect(state.collected == nodes)
                #expect(nodes.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
            }
        }
    }

    @Test("answering after the prompt was abandoned changes nothing, and abandoning twice is safe")
    func continuationResumesOnce() async throws {
        try await withTempTree { tree in
            try await withIsolatedDefaults { defaults in
                let (state, _) = try await browsingState(tree, defaults: defaults)
                let recorder = Recorder()
                let session = session(recording: recorder)
                session.start(state)
                try await awaitPrompt(session)

                session.abandon()
                session.answer(.moveIt)
                session.abandon()
                try await awaitFinished(session)

                #expect(recorder.decisions == [.stop])
                #expect(recorder.moved == 0)
                #expect(recorder.runs == 1)
            }
        }
    }

    @Test("Skip resumes the run past that item")
    func skipContinues() async throws {
        try await withTempTree { tree in
            try await withIsolatedDefaults { defaults in
                let (state, _) = try await browsingState(tree, defaults: defaults)
                let recorder = Recorder()
                let session = session(recording: recorder)
                session.start(state)
                try await awaitPrompt(session)
                session.answer(.skip)
                try await awaitFinished(session)
                #expect(recorder.decisions == [.skip])
                #expect(session.outcome.skipped == 1)
                #expect(session.outcome.moved == 1)
                #expect(!session.outcome.stopped)
            }
        }
    }

    @Test("Move it lets the run carry on through every item")
    func moveItContinues() async throws {
        try await withTempTree { tree in
            try await withIsolatedDefaults { defaults in
                let (state, _) = try await browsingState(tree, defaults: defaults)
                let recorder = Recorder()
                let session = session(recording: recorder)
                session.start(state)
                try await awaitPrompt(session)
                session.answer(.moveIt)
                try await awaitFinished(session)
                #expect(session.outcome.moved == 2)
                #expect(session.total == 2)
            }
        }
    }

    @Test("a run is started once: a second start does not run it again")
    func startIsIdempotent() async throws {
        try await withTempTree { tree in
            try await withIsolatedDefaults { defaults in
                let (state, _) = try await browsingState(tree, defaults: defaults)
                let recorder = Recorder()
                let session = session(recording: recorder)
                session.start(state)
                session.start(state)
                try await awaitPrompt(session)
                session.answer(.stop)
                try await awaitFinished(session)
                #expect(recorder.runs == 1)
            }
        }
    }

    @Test("leaving the scan (All Drives) while the prompt is up resolves it to Stop and keeps the Crate")
    func leavingTheScanAbandonsTheRun() async throws {
        try await withTempTree { tree in
            try await withIsolatedDefaults { defaults in
                let (state, _) = try await browsingState(tree, defaults: defaults)
                let recorder = Recorder()
                let session = session(recording: recorder)
                session.start(state)
                try await awaitPrompt(session)

                state.backToStart()
                try await awaitFinished(session)

                #expect(recorder.decisions == [.stop])
                #expect(recorder.moved == 0)
                #expect(state.collected.isEmpty) // backToStart empties the Crate; the run must not refill it
            }
        }
    }

    @Test("a session that was never started can be abandoned without effect")
    func abandonBeforeStart() {
        let session = TrashSession()
        session.abandon()
        #expect(session.phase == .review)
        #expect(session.warning == nil)
    }
}

@Suite("Wording that must not regress")
struct WordingTests {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    @Test("both Move to Trash alerts append the terms' delete reminder")
    func crateAlertsCarryTheReminder() throws {
        let source = try String(contentsOf: repoRoot.appendingPathComponent("Sources/Discotech/UI/CrateView.swift"), encoding: .utf8)
        #expect(source.components(separatedBy: "Terms.deleteReminder").count - 1 >= 2)
        #expect(source.contains("\"Move \\(Count.items(state.collected.count)) to the Trash?\""))
        #expect(source.contains(".alert(\"Are you sure?\""))
    }

    @Test("the reminder says who is responsible, to keep a backup, and that the app has no warranty")
    func reminderContent() {
        let text = Terms.deleteReminder
        #expect(text.contains("responsible"))
        #expect(text.contains("backup"))
        #expect(text.contains("without warranty"))
    }
}
