import AppKit
import SwiftUI

/// Single source of truth for the UI. All views read it via `@EnvironmentObject`.
@MainActor
final class AppState: ObservableObject {
    enum Phase: Equatable {
        case start
        case scanning
        case browsing
    }

    @Published private(set) var phase: Phase = .start
    @Published private(set) var progress = ScanProgress()
    @Published private(set) var scanError: String?
    @Published private(set) var scanRoot: URL?
    /// True when the current tree came from a scan stopped early with `stopScan()`
    /// (and, while still scanning, from the moment Stop was pressed).
    @Published private(set) var isPartialScan = false
    /// Set while a running scan has measured nothing new for `stallSeconds`: usually
    /// macOS holding a folder until a privacy prompt is answered, or a slow volume.
    @Published private(set) var scanStall: ScanStall?

    struct ScanStall: Equatable {
        /// Folders the scan is waiting on, when known.
        var paths: [String]
    }

    /// Root of the scanned tree. Only scans set it; the setter is internal so tests can
    /// hand the Crate logic an in-memory tree.
    @Published var root: FileNode? {
        didSet {
            guard root !== oldValue else { return }
            findings.refresh(for: root)
            sidebarTab = SidebarView.Tab.initial(for: root)
        }
    }

    /// Cleanup suggestions for the current tree, and the sidebar tab that shows them. Kept
    /// here rather than in the sidebar: a theme or "Colour by" change rebuilds the whole
    /// window (`ThemedRoot`), which would otherwise walk the tree again and reset the tab
    /// (closing an open Findings list). Also lets a trash run keep the walk off the tree.
    let findings = FindingsModel()
    /// Defaults per scan (`SidebarView.Tab.initial`), then follows whatever the user picks.
    @Published var sidebarTab: SidebarView.Tab = .items
    /// The folder currently shown at the center of the sunburst.
    @Published private(set) var focus: FileNode?
    /// Item under the pointer, in either the sunburst or the sidebar.
    @Published var hovered: FileNode?
    /// Item last clicked (a file in the chart, a row in the sidebar). Space previews it.
    @Published var selected: FileNode?

    /// Which visualization fills the canvas. Every mode reads the same focus, hover,
    /// selection, emphasis and Crate, so switching never loses your place.
    enum CanvasMode: String, CaseIterable, Identifiable {
        /// The disco ball: the sunburst chart (`Sunburst/`). Stored as "ball"; "ring" (its
        /// old name) still decodes, see `init(storedValue:)`.
        case ball, columns, floor
        var id: String { rawValue }
        var title: String {
            switch self {
            case .ball: "Ball"
            case .columns: "Layers"
            case .floor: "Floor"
            }
        }
        var symbol: String {
            switch self {
            case .ball: "circle.circle"
            case .columns: "square.stack.3d.down.forward"
            case .floor: "square.grid.3x3.fill"
            }
        }

        /// A stored or typed mode name, case-insensitive; accepts the legacy "ring" for
        /// `.ball`. `nil` for anything else.
        init?(storedValue: String) {
            let value = storedValue.lowercased()
            if value == "ring" { self = .ball; return }
            self.init(rawValue: value)
        }
    }

    @Published var canvasMode: CanvasMode = {
        UserDefaults.standard.string(forKey: "canvasMode").flatMap(CanvasMode.init(storedValue:)) ?? .ball
    }() {
        didSet { UserDefaults.standard.set(canvasMode.rawValue, forKey: "canvasMode") }
    }

    /// Items a Findings card (or similar) wants lit up together in every canvas mode.
    /// Empty = no emphasis. Views glow these and dim the rest, like a multi-item hover.
    @Published private(set) var emphasized: Set<FileNode> = []

    func emphasize(_ nodes: [FileNode]) { emphasized = Set(nodes) }
    func clearEmphasis() { if !emphasized.isEmpty { emphasized = [] } }

    /// The Finding whose files view replaces the canvas. Nil = canvas showing. Held in
    /// memory only, and dropped whenever the tree is replaced or left.
    @Published private(set) var detailFinding: Finding?
    func openFindingDetail(_ finding: Finding) {
        // The canvas goes away, so whatever it was hovering or glowing must not linger.
        hovered = nil
        clearEmphasis()
        detailFinding = finding
    }
    func closeFindingDetail() { if detailFinding != nil { detailFinding = nil } }
    /// Items queued for deletion in the Crate.
    @Published private(set) var collected: [FileNode] = []
    /// Bumped whenever the tree is mutated in place, so views can redraw.
    @Published private(set) var treeVersion = 0

    /// Whose acceptance gates `startScan`. Nil means the app's own `TermsStore.shared`;
    /// tests pass one backed by an isolated `UserDefaults` suite.
    private let termsOverride: TermsStore?
    private var terms: TermsStore { termsOverride ?? TermsStore.shared }

    init(terms: TermsStore? = nil) {
        termsOverride = terms
    }

    private var scanTask: Task<Void, Never>?
    /// Built on first need (Crate totals, trashing) and dropped with the tree.
    private var hardLinks: HardLinkIndex?
    private var hardLinksRoot: ObjectIdentifier?

    private func hardLinkIndex() -> HardLinkIndex? {
        guard let root else { return nil }
        if hardLinks == nil || hardLinksRoot != ObjectIdentifier(root) {
            hardLinks = HardLinkIndex(root: root)
            hardLinksRoot = ObjectIdentifier(root)
        }
        return hardLinks
    }
    private var scanner: Scanner?
    /// Bumped whenever a scan is abandoned, so anything a superseded scan still sends
    /// (progress, its result) is ignored: its workers can outlive it in the kernel.
    private var scanGeneration = 0
    private var lastProgressAt: TimeInterval = 0
    private var stallWatch: Task<Void, Never>?
    #if DEBUG
    private var stopRequestedAt: TimeInterval?
    #endif

    /// No progress for this long while scanning counts as a stall.
    static let stallSeconds: TimeInterval = 4

    // MARK: Scanning

    func startScan(_ url: URL) {
        // Nothing scans before the terms are accepted (the agreement screen hides every
        // way in; this holds even if one is added later).
        guard terms.isAccepted else { ScanLog.line("scan refused: terms not accepted"); return }
        cancelScan()
        let generation = scanGeneration
        scanRoot = url
        scanError = nil
        progress = ScanProgress()
        collected = []
        hovered = nil
        detailFinding = nil
        isPartialScan = false
        phase = .scanning
        let scanner = Scanner(root: url)
        self.scanner = scanner
        ScanLog.line("scan #\(generation) started: \(url.path)")
        watchForStalls(generation)
        scanTask = Task { [weak self] in
            do {
                let tree = try await scanner.scan { [weak self] p in
                    Task { @MainActor in self?.receive(p, generation: generation) }
                }
                guard let self, !Task.isCancelled, self.scanGeneration == generation else { return }
                self.scanner = nil
                // Blocking I/O (diskutil, tmutil) — off the main actor, before the tree is published.
                await Task.detached { SpaceAccounting.annotate(root: tree, scannedURL: url) }.value
                guard !Task.isCancelled, self.scanGeneration == generation else { return }
                self.endStallWatch()
                self.root = tree
                self.focus = tree
                self.phase = .browsing
                #if DEBUG
                let sinceStop = self.stopRequestedAt.map { " \(Int((ProcessInfo.processInfo.systemUptime - $0) * 1000)) ms after Stop" }
                ScanLog.line("scan #\(generation): browsing\(sinceStop ?? " (complete)")")
                #endif
            } catch is CancellationError {
                // Cancel already left the scanning screen. A Stop pressed before the
                // scanned folder itself had opened has nothing to show: back to start.
                guard let self, self.scanGeneration == generation, self.phase == .scanning else { return }
                self.cancelScan()
            } catch {
                guard let self, self.scanGeneration == generation else { return }
                self.cancelScan()
                self.scanError = error.localizedDescription
            }
        }
    }

    private func receive(_ p: ScanProgress, generation: Int) {
        guard scanGeneration == generation, phase == .scanning, p != progress else { return }
        progress = p
        lastProgressAt = ProcessInfo.processInfo.systemUptime
        if scanStall != nil {
            scanStall = nil
            ScanLog.line("stall cleared: progress moved")
        }
    }

    /// Checks once a second whether the running scan has stopped moving.
    private func watchForStalls(_ generation: Int) {
        lastProgressAt = ProcessInfo.processInfo.systemUptime
        stallWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.scanGeneration == generation, self.phase == .scanning,
                      let scanner = self.scanner else { return }
                guard ProcessInfo.processInfo.systemUptime - self.lastProgressAt >= Self.stallSeconds else { continue }
                let stall = ScanStall(paths: scanner.waitingPaths())
                if stall != self.scanStall {
                    self.scanStall = stall
                    ScanLog.line("stall shown; waiting on \(stall.paths.count) folder(s): \(stall.paths.prefix(3).joined(separator: ", "))")
                }
            }
        }
    }

    private func endStallWatch() {
        stallWatch?.cancel()
        stallWatch = nil
        scanStall = nil
    }

    /// Stops the scan early but keeps and shows everything measured so far. Never
    /// waits for the scan's workers: ones stuck in the kernel are left behind.
    func stopScan() {
        guard phase == .scanning, let scanner, !isPartialScan else { return }
        isPartialScan = true
        #if DEBUG
        stopRequestedAt = ProcessInfo.processInfo.systemUptime
        #endif
        scanner.stopAndKeep()
    }

    /// Stops the scan and discards its results.
    func cancelScan() {
        scanGeneration += 1
        scanTask?.cancel()
        scanTask = nil
        scanner = nil
        endStallWatch()
        #if DEBUG
        stopRequestedAt = nil
        #endif
        if phase == .scanning { phase = .start }
    }

    func rescan() {
        if let scanRoot { startScan(scanRoot) }
    }

    func backToStart() {
        cancelScan()
        root = nil
        focus = nil
        hovered = nil
        detailFinding = nil
        collected = []
        isPartialScan = false
        phase = .start
    }

    // MARK: Navigation

    func zoom(into node: FileNode) {
        guard node.isDirectory, !node.isPackage || !node.children.isEmpty else { return }
        focus = node
        hovered = nil
        selected = nil
    }

    func zoomOut() {
        if let parent = focus?.parent { focus = parent; hovered = nil }
    }

    // MARK: Crate

    /// Why `node` can't go in the Crate, or nil if it can.
    func collectBlockReason(_ node: FileNode) -> String? {
        if node === root { return "The scanned folder itself can’t go in the Crate." }
        if node.isSynthetic { return "This isn’t a file, so it can’t go in the Crate." }
        return Safety.protectionReason(for: node)
    }

    func canCollect(_ node: FileNode) -> Bool { collectBlockReason(node) == nil }

    func collect(_ node: FileNode) {
        guard canCollect(node) else { return }
        // Already covered by a collected ancestor.
        if collected.contains(where: { node.isDescendant(of: $0) }) { return }
        // Collecting a folder subsumes any of its descendants already collected.
        collected.removeAll { $0.isDescendant(of: node) }
        collected.append(node)
    }

    func uncollect(_ node: FileNode) {
        collected.removeAll { $0 === node }
    }

    /// Empties the Crate without touching anything on disk.
    func uncollectAll() {
        collected = []
    }

    func isCollected(_ node: FileNode) -> Bool {
        collected.contains { node.isDescendant(of: $0) }
    }

    /// Space actually freed by emptying the Crate. Hard-linked data only counts when
    /// every name for it is in the Crate, since any other name keeps it on disk.
    var collectedSize: Int64 {
        guard !collected.isEmpty else { return 0 }
        return hardLinkIndex()?.reclaimable(collected) ?? collected.reduce(0) { $0 + $1.size }
    }

    /// What the person chose when asked about one item in a sensitive location.
    enum SensitiveDecision { case moveIt, skip, stop }

    struct TrashOutcome {
        var moved = 0
        var failures: [(FileNode, String)] = []
        var skipped = 0
        var stopped = false
    }

    /// Moves the collected items to the Trash one at a time, removing each from the tree.
    ///
    /// Before each item that sits somewhere sensitive (see `Safety.sensitivityReason`),
    /// `confirmSensitive` is asked, however far into the run that item is. Items that
    /// failed, were skipped, or weren't reached stay in the Crate. `progress` reports the
    /// item about to be handled and how many were handled before it.
    ///
    /// The run stops before its next item when its task is cancelled (the review sheet went
    /// away, see `TrashSession.abandon`) or the scan is replaced or left; it then leaves the
    /// Crate and tree alone, since they may belong to a newer scan.
    func trashCollected(
        progress: (FileNode, Int) -> Void,
        confirmSensitive: (FileNode, String) async -> SensitiveDecision
    ) async -> TrashOutcome {
        let generation = scanGeneration
        // Findings walks this tree off the main thread: none may run while nodes go.
        await findings.beginTreeChange()
        defer { findings.endTreeChange() }
        var outcome = TrashOutcome()
        var index = hardLinkIndex()
        let queue = collected
        var remaining: [FileNode] = []
        for (position, node) in queue.enumerated() {
            if !outcome.stopped, Task.isCancelled || scanGeneration != generation { outcome.stopped = true }
            if outcome.stopped { remaining.append(node); continue }
            progress(node, position)
            // Refuse unless the path still points at exactly what was scanned.
            if let reason = TrashCheck.refusal(for: node) {
                outcome.failures.append((node, reason)); remaining.append(node)
                continue
            }
            if let reason = Safety.sensitivityReason(forPath: node.path) {
                switch await confirmSensitive(node, reason) {
                case .moveIt: break
                case .skip: outcome.skipped += 1; remaining.append(node); continue
                case .stop: outcome.stopped = true; remaining.append(node); continue
                }
                // The prompt may have been up a while: the sheet or the scan can be gone.
                if Task.isCancelled || scanGeneration != generation {
                    outcome.stopped = true; remaining.append(node); continue
                }
            }
            let url = node.url
            do {
                // Off the main actor: a big folder can take a while to move.
                try await Task.detached { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }.value
                if scanGeneration == generation {
                    if let f = focus, f.isDescendant(of: node) { focus = node.parent }
                    index?.transferCredit(awayFrom: node)
                    node.removeFromParent()
                }
                outcome.moved += 1
            } catch {
                outcome.failures.append((node, error.localizedDescription)); remaining.append(node)
            }
        }
        // A rescan or All Drives during the run: the Crate and tree now belong to that.
        guard scanGeneration == generation else { return outcome }
        hardLinks = index
        collected = remaining
        hovered = nil
        treeVersion += 1
        return outcome
    }

    // MARK: Finder

    func revealInFinder(_ node: FileNode) {
        guard !node.isSynthetic else { return }
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    func open(_ node: FileNode) {
        guard !node.isSynthetic else { return }
        NSWorkspace.shared.open(node.url)
    }
}
