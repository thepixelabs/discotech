#if DEBUG
import SwiftUI

extension DebugHooks {
    /// DISCOTECH_EMPHASIZE_FINDING=<index>  once Findings has finished computing and the
    /// Findings tab is showing, emphasizes that finding's nodes (0-based) — lets a
    /// screenshot show the hover-linked glow on the chart without a real pointer.
    static var emphasizeFindingIndex: Int? {
        ProcessInfo.processInfo.environment["DISCOTECH_EMPHASIZE_FINDING"].flatMap(Int.init)
    }

    /// DISCOTECH_OPEN_FINDING=<index>  once Findings has finished computing and the
    /// Findings tab is showing, opens that finding's detail pane (0-based).
    static var openFindingIndex: Int? {
        ProcessInfo.processInfo.environment["DISCOTECH_OPEN_FINDING"].flatMap(Int.init)
    }
    /// DISCOTECH_DETAIL_CLOSE_AFTER=<seconds>  closes it again that long after opening
    /// (screenshot the canvas coming back). DISCOTECH_DETAIL_SCOPE=all  opens the detail pane on "All files" instead.
    static var detailScopeAll: Bool {
        ProcessInfo.processInfo.environment["DISCOTECH_DETAIL_SCOPE"] == "all"
    }

    /// DISCOTECH_FINDINGS_TIMING=<n>  logs how long `Findings.find` took, the tree's node
    /// count, and each finding (tier, size, count) to stderr; n > 1 re-runs it n more
    /// times and also logs the fastest run (the first one competes with chart layout).
    nonisolated static var logFindingsTiming: Bool {
        ProcessInfo.processInfo.environment["DISCOTECH_FINDINGS_TIMING"] != nil
    }

    nonisolated static func logFindings(_ findings: [Finding], in root: FileNode, took elapsed: Duration) {
        func ms(_ d: Duration) -> Double {
            Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        }
        var nodes = 0
        var stack = [root]
        while let node = stack.popLast() { nodes += 1; stack.append(contentsOf: node.children) }
        var fastest = elapsed
        let repeats = ProcessInfo.processInfo.environment["DISCOTECH_FINDINGS_TIMING"].flatMap(Int.init) ?? 1
        for _ in 1..<max(repeats, 1) {
            let started = ContinuousClock.now
            _ = Findings.find(in: root)
            fastest = min(fastest, ContinuousClock.now - started)
        }
        var lines = [String(format: "[findings] %.1f ms (fastest of %d: %.1f ms) for %d nodes, %d findings",
                            ms(elapsed), max(repeats, 1), ms(fastest), nodes, findings.count)]
        for f in findings {
            lines.append("[findings]   \(f.tier) \(f.id): \(ByteFormat.string(f.totalSize)), \(f.countLabel)")
        }
        FileHandle.standardError.write((lines.joined(separator: "\n") + "\n").data(using: .utf8)!)
    }

    // MARK: Walk counts (DISCOTECH_FINDINGS_TIMING also logs each walk's start and end)

    private nonisolated static let walkLock = NSLock()
    private nonisolated(unsafe) static var walkCounts = (started: 0, running: 0)

    nonisolated static var findingsWalks: (started: Int, running: Int) {
        walkLock.lock(); defer { walkLock.unlock() }
        return walkCounts
    }

    nonisolated static func findingsWalkStarted() {
        walkLock.lock()
        walkCounts.started += 1; walkCounts.running += 1
        let counts = walkCounts
        walkLock.unlock()
        if logFindingsTiming {
            FileHandle.standardError.write(Data("[findings] walk \(counts.started) started (\(counts.running) running)\n".utf8))
        }
    }

    nonisolated static func findingsWalkEnded() {
        walkLock.lock()
        walkCounts.running -= 1
        let counts = walkCounts
        walkLock.unlock()
        if logFindingsTiming {
            FileHandle.standardError.write(Data("[findings] walk ended (\(counts.running) running)\n".utf8))
        }
    }

    // MARK: Gate self-test

    private static var findingsGateTestRan = false

    /// DISCOTECH_TEST_FINDINGS_GATE=1 (with DISCOTECH_FINDINGS_TIMING=20000 so the walk is
    /// still running): once browsing, does what a trash run does around its changes, but
    /// trashes nothing: `beginTreeChange`, removes a `node_modules` folder from the
    /// in-memory tree only (nothing on disk is touched), opens and closes a second,
    /// overlapping change (another window's run), then the last `endTreeChange`. Logs that
    /// the walk had finished before the change, none ran during it, and the next walk no
    /// longer lists the removed folder.
    static func runFindingsGateTest(_ state: AppState) {
        guard ProcessInfo.processInfo.environment["DISCOTECH_TEST_FINDINGS_GATE"] != nil, !findingsGateTestRan else { return }
        findingsGateTestRan = true
        let model = state.findings
        func log(_ text: String) { FileHandle.standardError.write(Data("findings gate test: \(text)\n".utf8)) }
        func summary(_ findings: [Finding]) -> String { findings.map { "\($0.id) ×\($0.nodes.count)" }.joined(separator: ", ") }
        func folder(named name: String, in root: FileNode) -> FileNode? {
            var stack = [root]
            while let node = stack.popLast() {
                if node.isDirectory, node.name == name { return node }
                stack.append(contentsOf: node.children)
            }
            return nil
        }
        Task { @MainActor in
            var counts = findingsWalks
            log("asking for the tree: \(counts.running) walk(s) running, \(counts.started) started")
            let asked = ContinuousClock.now
            await model.beginTreeChange()
            counts = findingsWalks
            log("got it after \(asked.duration(to: .now)): \(counts.running) walk(s) running")
            try? await Task.sleep(for: .milliseconds(50))  // that walk's result lands on main
            log("findings before: \(summary(model.findings))")
            guard let root = state.root, let target = folder(named: "node_modules", in: root) else {
                log("FAIL no node_modules folder to remove"); return
            }
            let path = target.path
            target.removeFromParent()
            log("removed \(path) from the in-memory tree")
            await model.beginTreeChange()  // a second, overlapping run…
            model.endTreeChange()          // …that ends first
            try? await Task.sleep(for: .milliseconds(300))
            counts = findingsWalks
            log("one run still holds the tree: \(counts.running) walk(s) running, \(counts.started) started")
            model.endTreeChange()
            for _ in 0..<600 where findingsWalks.started < 2 || findingsWalks.running > 0 {
                try? await Task.sleep(for: .milliseconds(50))
            }
            try? await Task.sleep(for: .milliseconds(50))
            counts = findingsWalks
            let listed = model.findings.contains { $0.nodes.contains { $0 === target } }
            log("after the last run ended: \(counts.started) walk(s) started, \(counts.running) running")
            log("findings after: \(summary(model.findings)); removed folder still listed: \(listed)")
        }
    }
}

/// The Findings list's screenshot hooks (called once Findings has finished computing).
extension FindingsListView {
    /// DISCOTECH_FINDINGS_SCROLL=review  scrolls the list to that group's header.
    func debugScroll(_ proxy: ScrollViewProxy) {
        guard let raw = ProcessInfo.processInfo.environment["DISCOTECH_FINDINGS_SCROLL"],
              let tier = Finding.Tier.allCases.first(where: { "\($0)" == raw }) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { proxy.scrollTo(tier, anchor: .top) }
    }

    func debugOpenFinding() {
        guard let index = DebugHooks.openFindingIndex, model.findings.indices.contains(index) else { return }
        state.openFindingDetail(model.findings[index])
        if let secs = ProcessInfo.processInfo.environment["DISCOTECH_DETAIL_CLOSE_AFTER"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) { state.closeFindingDetail() }
        }
    }
}
#endif
