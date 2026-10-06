import AppKit
import Foundation
import Testing
@testable import Discotech

@MainActor
@Suite("AppState: navigation and emphasis")
struct AppStateNavigationTests {
    private func state() -> (AppState, root: FileNode, docs: FileNode, deep: FileNode, file: FileNode, package: FileNode) {
        let deep = dirNode("deep", [fileNode("x", 5)])
        let docs = dirNode("docs", [deep, fileNode("a", 9)])
        let file = fileNode("top.txt", 3)
        let package = dirNode("Empty.app", package: true)
        let root = treeNode(root: "/discotech-test-root", [docs, file, package])
        let state = AppState()
        state.root = root
        return (state, root, docs, deep, file, package)
    }

    @Test("zooming into a folder focuses it and clears hover and selection")
    func zoomInto() {
        let (state, _, docs, deep, _, _) = state()
        state.hovered = deep
        state.selected = deep
        state.zoom(into: docs)
        #expect(state.focus === docs)
        #expect(state.hovered == nil && state.selected == nil)
    }

    @Test("a file and an empty package cannot be zoomed into")
    func zoomRefusals() {
        let (state, _, docs, _, file, package) = state()
        state.zoom(into: docs)
        state.zoom(into: file)
        state.zoom(into: package)
        #expect(state.focus === docs)
    }

    @Test("zooming out goes to the parent and stops at the root")
    func zoomOut() {
        let (state, root, docs, deep, _, _) = state()
        state.zoom(into: deep)
        state.zoomOut()
        #expect(state.focus === docs)
        state.zoomOut()
        #expect(state.focus === root)
        state.zoomOut()
        #expect(state.focus === root)
    }

    @Test("emphasis holds exactly the nodes given and clears")
    func emphasis() {
        let (state, _, docs, _, file, _) = state()
        state.emphasize([docs, file, docs])
        #expect(state.emphasized == [docs, file])
        state.clearEmphasis()
        #expect(state.emphasized.isEmpty)
    }

    @Test("opening a finding's files clears hover and emphasis, closing it drops the finding")
    func findingDetail() {
        let (state, _, docs, _, _, _) = state()
        let finding = Finding(id: "f", title: "", reason: "", icon: "", unitLabel: "x", tier: .safe, isCollectible: true, nodes: [docs])
        state.hovered = docs
        state.emphasize([docs])
        state.openFindingDetail(finding)
        #expect(state.hovered == nil)
        #expect(state.emphasized.isEmpty)
        #expect(state.detailFinding?.id == "f")
        state.closeFindingDetail()
        #expect(state.detailFinding == nil)
    }

    @Test("canvas modes read stored names in any case, and the legacy 'ring' means the Ball",
          arguments: [("ball", AppState.CanvasMode.ball), ("RING", .ball), ("ring", .ball), ("Layers", nil), ("columns", .columns),
                      ("FLOOR", .floor), ("", nil), ("sunburst", nil)])
    func canvasModeNames(_ stored: String, _ expected: AppState.CanvasMode?) {
        #expect(AppState.CanvasMode(storedValue: stored) == expected)
    }

    @Test("every canvas mode is named with the product words")
    func canvasModeTitles() {
        #expect(AppState.CanvasMode.allCases.map(\.title) == ["Ball", "Layers", "Floor"])
    }

    @Test("a state with no scan has nothing to stop and nothing to rescan")
    func idleState() {
        let state = AppState()
        state.stopScan()
        state.rescan()
        #expect(state.phase == .start)
        #expect(!state.isPartialScan)
    }
}

@Suite("Volumes and space accounting")
struct VolumeTests {
    @Test("every volume listed has a capacity, a name, and used space between 0 and the total")
    func mountedVolumes() {
        for volume in Volume.mounted() {
            #expect(volume.totalCapacity > 0)
            #expect(!volume.name.isEmpty)
            #expect((0...volume.totalCapacity).contains(volume.usedCapacity), "\(volume.name)")
        }
    }

    @Test("scanning an ordinary folder adds no Free, Purgeable or Unseen nodes")
    func ordinaryFolderIsUntouched() async throws {
        try await withTempTree { tree in
            try tree.file("a.bin", bytes: 4_096)
            let root = try await tree.scan()
            let before = (root.size, root.children.count)
            SpaceAccounting.annotate(root: root, scannedURL: tree.root)
            #expect(root.size == before.0)
            #expect(root.children.count == before.1)
            #expect(root.children.allSatisfy { !$0.isSynthetic })
        }
    }
}

@Suite("Scan plumbing")
struct ScanPlumbingTests {
    @Test("a cancel flag starts clear and stays set")
    func cancelFlag() {
        let flag = CancelFlag()
        #expect(!flag.isCancelled)
        flag.cancel()
        flag.cancel()
        #expect(flag.isCancelled)
    }

    @Test("a result delivered before anyone waits is handed over when they do, and only the first delivery counts")
    func handoffEarlyDelivery() async throws {
        let handoff = ScanHandoff()
        let first = dirNode("/first"), second = dirNode("/second")
        handoff.deliver(.success(first))
        handoff.deliver(.success(second))
        let got = try await withCheckedThrowingContinuation { handoff.wait($0) }
        #expect(got === first)
    }

    @Test("a waiter is resumed by a later delivery, with an error if that is what was delivered")
    func handoffLateDelivery() async {
        let handoff = ScanHandoff()
        async let outcome: Result<FileNode, Error> = {
            do { return .success(try await withCheckedThrowingContinuation { handoff.wait($0) }) } catch { return .failure(error) }
        }()
        handoff.deliver(.failure(CancellationError()))
        if case .failure(let error) = await outcome { #expect(error is CancellationError) } else { Issue.record("expected a failure") }
    }

    @Test("the gate tells which folders are being opened, until they are opened or it is sealed")
    func gateTracksOpening() {
        let gate = TreeGate(workers: 2)
        let root = dirNode("/r"), child = dirNode("kid")
        _ = gate.adopt(root: root)
        var batch = [child]
        #expect(gate.willOpen(child, worker: 1, publishing: &batch, into: root))
        #expect(root.children.count == 1 && batch.isEmpty)
        #expect(gate.openingNodes() == [child])
        var st = stat()
        _ = stat("/", &st)
        gate.didOpen(child, worker: 1, identity: st)
        #expect(gate.openingNodes().isEmpty)
        #expect(child.fileID == UInt64(st.st_ino))
    }

    @Test("once winding down, the gate lets no further folder be opened but still publishes what was listed")
    func gateWindDown() {
        let gate = TreeGate(workers: 1)
        let root = dirNode("/r"), child = dirNode("kid")
        _ = gate.adopt(root: root)
        gate.windDown()
        var batch = [child]
        #expect(!gate.willOpen(child, worker: 0, publishing: &batch, into: root))
        #expect(root.children.count == 1)
        #expect(gate.openingNodes().isEmpty)
    }

    @Test("work run through ifUnsealed only happens before the seal")
    func gateIfUnsealed() {
        let gate = TreeGate(workers: 1)
        #expect(gate.ifUnsealed { 1 } == 1)
        _ = gate.seal()
        #expect(gate.ifUnsealed { 1 } == nil)
        #expect(gate.isSealed)
    }

    @Test("a late folder-open after the seal is refused and counted, and does not change the node")
    func gateRefusesLateDidOpen() {
        let gate = TreeGate(workers: 1)
        let child = dirNode("kid")
        child.fileID = 5
        _ = gate.seal()
        var st = stat()
        _ = stat("/", &st)
        gate.didOpen(child, worker: 0, identity: st)
        #expect(child.fileID == 5)
        #expect(gate.refusedWrites == 1)
    }
}

extension GlobalState {
    @MainActor
    @Suite("Synthetic tints")
    struct SyntheticTintTests {
        @Test("Free, Purgeable and Unseen are translucent tints, in both appearances, never a ramp colour")
        func tintsAreTranslucent() {
            for dark in [false, true] {
                #expect(Palette.Synthetic.freeFill(dark: dark).alphaComponent < 0.1)
                #expect(Palette.Synthetic.purgeableFill(dark: dark).alphaComponent < 0.5)
                #expect(Palette.Synthetic.unseenFill(dark: dark).alphaComponent < 0.5)
                #expect(Palette.Synthetic.otherFill(dark: dark).alphaComponent < 0.1)
            }
        }
    
        @Test("a highlighted outline is stronger than the resting one")
        func highlightedStrokeIsStronger() {
            for dark in [false, true] {
                #expect(Palette.Synthetic.freeStroke(dark: dark, highlighted: true).alphaComponent > Palette.Synthetic.freeStroke(dark: dark, highlighted: false).alphaComponent)
                #expect(Palette.Synthetic.purgeableStroke(dark: dark, highlighted: true).alphaComponent > Palette.Synthetic.purgeableStroke(dark: dark, highlighted: false).alphaComponent)
                #expect(Palette.Synthetic.unseenStroke(dark: dark, highlighted: true).alphaComponent > Palette.Synthetic.unseenStroke(dark: dark, highlighted: false).alphaComponent)
            }
        }
    
        @Test("synthetic nodes get a fixed colour and real ones get none from this lookup")
        func syntheticColorLookup() {
            for kind in [FileNode.Kind.freeSpace, .purgeable, .hidden, .snapshot] {
                #expect(Palette.syntheticColor(for: FileNode(name: "x", isDirectory: false, kind: kind)) != nil)
            }
            #expect(Palette.syntheticColor(for: fileNode("real", 1)) == nil)
        }
    }
}
