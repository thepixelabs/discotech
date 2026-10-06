#if DEBUG
import AppKit
import SwiftUI

// Debug/: everything that exists only in DEBUG builds (each file is wrapped in `#if DEBUG`):
// launch-time screenshot and QA hooks, the canvas self-tests, the window snapshot hooks. A
// production file holds only the one-line call sites into these. Release builds contain none
// of it (`strings` on the release binary finds no "DISCOTECH_"). No hook persists a setting,
// writes scan data, or moves anything to the Trash.
//
// Registry of every DISCOTECH_* environment key (keep it complete: grep '"DISCOTECH_').
// Key                          Read in                          What it does
// Launch, window, snapshots
//   DISCOTECH_APPEARANCE=light|dark|light-hc|dark-hc   DebugHooks       force the app appearance
//   DISCOTECH_WINDOW=900x650        DebugHooks                   on-screen, centered, key window of that content size
//   DISCOTECH_SNAPSHOTS=2:/a.png,8:/b.png  DebugHooks            write the main window to PNG at t s, quit after the last
//   DISCOTECH_SNAPSHOT_MODE=view    DebugHooks, *SnapshotHook, Visuals (SnapshotSupport)
//                                                                render the view hierarchy instead of the window server image
//   DISCOTECH_OPEN_SETTINGS=t       DebugHooks+Launch            open Settings t s after launch
//   DISCOTECH_SETTINGS_SNAPSHOT=/a.png  SettingsSnapshotHook     write the Settings window to PNG once it is up
//   DISCOTECH_OPEN_HELP=t           DebugHooks+Launch            open Help → Discotech Help t s after launch
//   DISCOTECH_HELP_SNAPSHOT=/a.png  HelpSnapshotHook             write the Help window to PNG once it is up
//   DISCOTECH_OPEN_TERMS=t          DebugHooks+Launch            open Help → Terms of Use t s after launch
//   DISCOTECH_LOG_FRAMES=1          DebugHooks (debugFrame, logPlacement)  print tagged view frames / hover-card placement
// Terms of use (Legal/, stays there)
//   DISCOTECH_ACCEPT_TERMS=1        TermsStore                   treat the terms as accepted for this run (in memory only);
//                                                                needed by every hook that scans or screenshots app screens
//   DISCOTECH_RESET_TERMS=1         TermsStore                   show the terms gate as on first launch (stored value untouched)
//   DISCOTECH_TERMS_TICK=t, DISCOTECH_TERMS_AGREE=t   TermsDebugHooks   tick the box / press Agree t s after launch
//   DISCOTECH_TERMS_SNAPSHOT=/a.png TermsDocumentView            write the terms window to PNG
// Look (read where the value is chosen; never persisted)
//   DISCOTECH_THEME=<theme>         Theme, MulticolourThemes     studio|neon|iridescent|ocean|sunset|forest, or a
//                                                                Multicolour theme name (traffic, heat, …) which implies it
//   DISCOTECH_PALETTE_STYLE=gradient|signal  PaletteStyle        palette style ("signal" is Multicolour)
//   DISCOTECH_COLOR_BY=size|kind|folder      ColorMode           "Colour by" for this run
//   DISCOTECH_THEME_SWITCH=neon@8[,iridescent@12]  DebugHooks+Launch  switch the theme live at t s
//   DISCOTECH_INCREASE_CONTRAST=1, DISCOTECH_REDUCE_MOTION=1  CanvasHighlight  force those accessibility settings
// Scan
//   DISCOTECH_AUTOSCAN=/some/path   DebugHooks                   scan that folder at launch
//   DISCOTECH_AUTOSTOP=3            DebugHooks                   "Stop and Show Results" t s into the scan
//   DISCOTECH_AUTORESCAN=9          DebugHooks                   Rescan t s after launch
//   DISCOTECH_SCAN_LOG=1            ScanLog (ScanSupport)        trace scan start/stop/stall/hand-over
//   DISCOTECH_TEST_BLOCK_OPEN=/Contents/Resources@20  Scanner+Debug  first scan: opening a matching folder holds the
//                                                                worker that long (default an hour), like a privacy prompt
//   DISCOTECH_TEST_TREE_RECHECK=15  DebugHooks                   log a tree fingerprint at hand-over and t s later
// Browsing
//   DISCOTECH_CANVAS=ball|columns|floor  DebugHooks              start in that canvas ("ring" still means ball; columns is Layers)
//   DISCOTECH_AUTOZOOM=N            DebugHooks                   open the largest folder N levels down
//   DISCOTECH_AUTOCOLLECT=N         DebugHooks                   put the N largest children in the Crate (memory only)
//   DISCOTECH_AUTOHOVER=1           DebugHooks                   hover the 2nd child
//   DISCOTECH_AUTOHOVER_DEEP=3[:12] DebugHooks                   hover an item 3 rings out, from row 12 on
//   DISCOTECH_AUTOQUICKLOOK=1       DebugHooks                   select row 1, press Space, ↓, ↓, Space
//   DISCOTECH_QL_LOG=1              QuickLookController          trace Quick Look panel control
//   DISCOTECH_RENDER_SIDEBAR=/a.png DebugHooks                   render sidebar rows + Crate offscreen
//   DISCOTECH_PREVIEW_DROP=1        DebugHooks                   show the drop-target glow without dragging
//   DISCOTECH_PREVIEW_REFUSAL=1     DebugHooks                   show the "can't go in the Crate" notice
//   DISCOTECH_SIDEBAR_TAB=findings|items  DebugHooks+Sidebar     override the sidebar's default tab
//   DISCOTECH_TEST_THEME_KEEPS=t    DebugHooks+Sidebar           theme switch with Findings open; logs what survives
//   DISCOTECH_TEST_TRASH_ABANDON=close|rescan|drives|theme|quit|closewindow  DebugHooks+TrashAbandon
//                                                                Crate review run with a stand-in that touches nothing on disk
// Findings
//   DISCOTECH_FINDINGS_TIMING=n     DebugHooks+Findings          log Findings.find time, each finding, walk start/end
//   DISCOTECH_FINDINGS_SCROLL=review  DebugHooks+Findings        scroll the list to that group
//   DISCOTECH_EMPHASIZE_FINDING=i   DebugHooks+Findings/+Sidebar emphasize finding i's nodes
//   DISCOTECH_OPEN_FINDING=i        DebugHooks+Findings          open finding i's files view
//   DISCOTECH_DETAIL_SCOPE=all      DebugHooks+Findings          open the files view on "All files"
//   DISCOTECH_DETAIL_CLOSE_AFTER=s  DebugHooks+Findings          close the files view s s after opening
//   DISCOTECH_TEST_FINDINGS_GATE=1  DebugHooks+Findings          tree-change gate self-test (in-memory removal only)
//   DISCOTECH_TEST_SELECT=1|/a.png  DebugHooks+SelectionTest     drive the files table with synthetic events
//   DISCOTECH_TEST_SELECT_STEPS=…, DISCOTECH_TEST_SELECT_ACTIVE=1|am  DebugHooks+SelectionTest  its steps / fake frontmost
// Ball (Sunburst/)
//   DISCOTECH_LOG_RING_GEOMETRY=1   SunburstNSView+Debug         log ring geometry on hover changes and repaint ms
//   DISCOTECH_TEST_BALL_LEAK=zoom|hover-canvas|theme|none@t  SunburstNSView+Debug  animation-timer leak test
//   DISCOTECH_SCROLL_TEST=t         SunburstNSView+Debug, FloorNSView+Debug  scroll-navigation self-test (Ball or Floor)
// Layers (Columns/)
//   DISCOTECH_LAYERS_HOVER=1, DISCOTECH_LAYERS_CLICK=1, DISCOTECH_LAYERS_EMPHASIZE=name, DISCOTECH_LAYERS_SELECT=1
//                                   ColumnsNSView+Debug          hover / click / emphasize / select a band
// Floor
//   DISCOTECH_FLOOR_HOVER=deep|top|header, DISCOTECH_FLOOR_CLICK=1|@t, DISCOTECH_FLOOR_CLICK_BACK=1,
//   DISCOTECH_FLOOR_EMPHASIZE=name, DISCOTECH_FLOOR_SELECT=deep|top, DISCOTECH_FLOOR_RESIZE=WxH@t
//                                   FloorNSView+Debug            pointer / click / emphasis / selection / resize hooks
//   DISCOTECH_FLOOR_FIT=1           FloorNSView+Debug            log where the floor sits in the view, once per size
//   DISCOTECH_FLOOR_TIMING=1        FloorNSView+Debug, FloorPlacement  layout, render, transition and fade stats

/// Dev-only launch hooks for screenshots / manual QA. Every DISCOTECH_* key is listed in the
/// registry at the top of this file.
@MainActor
enum DebugHooks {

    static var previewDrop: Bool { env["DISCOTECH_PREVIEW_DROP"] != nil }

    /// DISCOTECH_LOG_FRAMES=1 also logs where the hover card went (column / strip).
    static func logPlacement(_ placement: CardPlacement, size: CGSize) {
        guard env["DISCOTECH_LOG_FRAMES"] != nil else { return }
        FileHandle.standardError.write(Data("placement \(placement.style) canvas=\(Int(size.width))x\(Int(size.height)) trailing=\(Int(placement.trailing)) bottom=\(Int(placement.bottom))\n".utf8))
    }
    static var previewRefusal: Bool { env["DISCOTECH_PREVIEW_REFUSAL"] != nil }

    private static var env: [String: String] { ProcessInfo.processInfo.environment }

    static func apply(to state: AppState) {
        applyPresentation()
        if let mode = env["DISCOTECH_CANVAS"].flatMap(AppState.CanvasMode.init(storedValue:)) {
            state.canvasMode = mode
        }
        if let path = env["DISCOTECH_AUTOSCAN"], state.phase == .start {
            state.startScan(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
            if let t = env["DISCOTECH_AUTOSTOP"].flatMap(Double.init) {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { state.stopScan() }
            }
        }
        if let t = env["DISCOTECH_AUTORESCAN"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { state.rescan() }
        }
    }

    private static var presentationApplied = false

    /// Appearance, window size and snapshots: once per launch, from whichever comes first,
    /// the terms screen (which shows before `ContentView` exists) or `apply`.
    static func applyPresentation() {
        guard !presentationApplied else { return }
        presentationApplied = true
        switch env["DISCOTECH_APPEARANCE"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        // High-contrast variants: exercise the Increase Contrast token values.
        case "light-hc": NSApp.appearance = NSAppearance(named: .accessibilityHighContrastAqua)
        case "dark-hc": NSApp.appearance = NSAppearance(named: .accessibilityHighContrastDarkAqua)
        default: break
        }
        if let spec = env["DISCOTECH_WINDOW"] {
            let parts = spec.split(separator: "x").compactMap { Double($0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard parts.count == 2,
                      let window = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }) else { return }
                window.setContentSize(NSSize(width: parts[0], height: parts[1]))
                window.center()
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
        }
        if let spec = env["DISCOTECH_SNAPSHOTS"] {
            let shots = spec.split(separator: ",").compactMap { item -> (Double, String)? in
                let parts = item.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, let t = Double(parts[0]) else { return nil }
                return (t, String(parts[1]))
            }
            for (i, shot) in shots.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + shot.0) {
                    snapshot(to: shot.1)
                    if i == shots.count - 1 { NSApp.terminate(nil) }
                }
            }
        }
    }

    /// Images this app's own main window, or `window` (no Screen Recording permission needed).
    static func snapshot(to path: String, window chosen: NSWindow? = nil) {
        guard let window = chosen ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && !($0 is NSPanel) }) else {
            FileHandle.standardError.write(Data("snapshot: no window among \(NSApp.windows)\n".utf8)); return
        }
        let target = window.attachedSheet ?? window
        var image: CGImage?
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        if env["DISCOTECH_SNAPSHOT_MODE"] != "view",
           let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") {
            let create = unsafeBitCast(sym, to: CreateImage.self)
            // .optionIncludingWindow = 1<<3, .boundsIgnoreFraming = 1<<0, .bestResolution = 1<<3
            image = create(.null, 1 << 3, UInt32(target.windowNumber), (1 << 0) | (1 << 3))?.takeRetainedValue()
        }
        if image == nil, let view = target.contentView?.superview {
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                image = rep.cgImage
            }
        }
        guard let image else { FileHandle.standardError.write(Data("snapshot: no image\n".utf8)); return }
        let rep = NSBitmapImageRep(cgImage: image)
        do { try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path)) }
        catch { FileHandle.standardError.write(Data("snapshot: \(error)\n".utf8)) }
    }

    /// Offscreen render of the sidebar's rows and Crate, for review while the display is locked.
    /// Row 2 is drawn hovered (chart-linked highlight), row 3 selected, row 4 keyboard-focused,
    /// row 5 as containing the hovered item.
    static func renderSidebar(_ state: AppState, to path: String) {
        guard let focus = state.focus else { return }
        let scheme: ColorScheme = env["DISCOTECH_APPEARANCE"] == "light" ? .light : .dark
        let rows = Array(focus.children.prefix(7))
        let tints = NodeTint.colors(for: focus, limit: rows.count)
        let total = Double(max(focus.size, 1))
        let view = VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, node in
                NodeRow(node: node, fraction: Double(node.size) / total, tint: tints[node.id] ?? .gray,
                        hover: i == 1 ? .direct : (i == 4 ? .contains : .none),
                        isSelected: i == 2, isFocused: i == 3,
                        isInCrate: state.isCollected(node), protection: Safety.protectionReason(for: node),
                        state: state)
            }
            CrateView().padding(.top, Tokens.Space.s)
        }
        .padding(Tokens.Space.s + Tokens.Space.xxs)
        .frame(width: Tokens.Size.sidebarIdeal)
        .background(Color(nsColor: .underPageBackgroundColor))
        .environmentObject(state)
        .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cg = renderer.cgImage else { return }
        try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: path))
    }

    /// Node count and a checksum over every node's size and identity: any write to the
    /// tree after it was handed over changes one of them.
    private static func fingerprint(_ root: FileNode) -> String {
        var stack = [root], nodes = 0, sum: UInt64 = 0
        while let node = stack.popLast() {
            nodes += 1
            sum = sum &* 31 &+ node.fileID &+ UInt64(bitPattern: node.size) &+ UInt64(node.children.count)
            stack.append(contentsOf: node.children)
        }
        return "nodes=\(nodes) size=\(root.size) files=\(root.fileCount) sum=\(sum)"
    }

    static func phaseChanged(_ phase: AppState.Phase, _ state: AppState) {
        if let delay = env["DISCOTECH_TEST_TREE_RECHECK"].flatMap(Double.init), phase == .browsing, let root = state.root {
            let before = fingerprint(root)
            FileHandle.standardError.write(Data("tree at hand-over (partial=\(state.isPartialScan)): \(before)\n".utf8))
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let after = fingerprint(root)
                FileHandle.standardError.write(Data("tree \(Int(delay)) s later: \(after) unchanged=\(after == before)\n".utf8))
            }
        }
        guard phase == .browsing, let focus = state.focus else { return }
        if let n = env["DISCOTECH_AUTOCOLLECT"].flatMap(Int.init) {
            focus.children.prefix(n).forEach(state.collect)
        }
        if let out = env["DISCOTECH_RENDER_SIDEBAR"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { renderSidebar(state, to: out) }
        }
        if env["DISCOTECH_AUTOHOVER"] != nil, focus.children.count > 1 {
            state.hovered = focus.children[1]
        }
        if env["DISCOTECH_AUTOQUICKLOOK"] != nil { driveQuickLook(state) }
        if let levels = env["DISCOTECH_AUTOZOOM"].flatMap(Int.init) {
            var node = focus
            for _ in 0..<levels {
                guard let next = node.children.first(where: { $0.isDirectory && !$0.isSynthetic && !$0.children.isEmpty }) else { break }
                node = next
            }
            state.zoom(into: node)
        }
        if let spec = env["DISCOTECH_AUTOHOVER_DEEP"] {
            let parts = spec.split(separator: ":").compactMap { Int($0) }
            let rings = max(1, parts.first ?? 3)
            let fromRow = parts.count > 1 ? parts[1] : 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                state.hovered = deepNode(in: state.focus ?? focus, rings: rings, fromRow: fromRow)
                FileHandle.standardError.write(Data("autohover: \(state.hovered?.path ?? "nothing that deep")\n".utf8))
            }
        }
    }

    /// The largest item `rings` rings out, inside the first real top-level folder at or
    /// after `fromRow` that goes that deep.
    private static func deepNode(in focus: FileNode, rings: Int, fromRow: Int) -> FileNode? {
        func descend(_ node: FileNode, _ remaining: Int) -> FileNode? {
            if remaining == 0 { return node }
            for child in node.children.prefix(8) where !child.isSynthetic {
                if let found = descend(child, remaining - 1) { return found }
            }
            return nil
        }
        let start = min(fromRow, focus.children.count)
        let order = focus.children[start...] + focus.children[..<start]
        for top in order where !top.isSynthetic && top.isDirectory {
            if let found = descend(top, rings - 1) { return found }
        }
        return nil
    }

    /// Select the first real row, then press Space, ↓, ↓, Space as real key events
    /// (through the same monitor a person's keypresses go through). Log with DISCOTECH_QL_LOG.
    private static func driveQuickLook(_ state: AppState) {
        let ql = QuickLookController.shared
        func key(_ code: UInt16, _ chars: String, at t: Double) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                ql.debugLog("posting key \(code)")
                let window = NSApp.windows.first { $0.isVisible && !($0 is NSPanel) }
                guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                   timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: window?.windowNumber ?? 0, context: nil,
                                                   characters: chars, charactersIgnoringModifiers: chars,
                                                   isARepeat: false, keyCode: code) else { return }
                NSApp.postEvent(event, atStart: false)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            state.selected = state.focus?.children.first { !$0.isSynthetic }
            ql.debugLog("selected \(state.selected?.path ?? "nil")")
        }
        key(49, " ", at: 1.5)
        key(125, String(UnicodeScalar(NSDownArrowFunctionKey)!), at: 3.0)
        key(125, String(UnicodeScalar(NSDownArrowFunctionKey)!), at: 4.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.8) {
            ql.debugLog("selected \(state.selected?.path ?? "nil")")
        }
        key(49, " ", at: 5.5)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.5) { ql.debugLog("after closing Space") }

    }
}

extension View {
    /// DEBUG-only: logs this view's frame in window coordinates when DISCOTECH_LOG_FRAMES is set.
    func debugFrame(_ tag: String) -> some View {
        background(GeometryReader { geo in
            Color.clear.onAppear {
                guard ProcessInfo.processInfo.environment["DISCOTECH_LOG_FRAMES"] != nil else { return }
                let f = geo.frame(in: .global)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    let window = NSApp.windows.first { $0.isVisible }?.contentView?.bounds ?? .zero
                    FileHandle.standardError.write(Data("frame \(tag): minY=\(Int(f.minY)) maxY=\(Int(f.maxY)) h=\(Int(f.height)) window=\(Int(window.width))x\(Int(window.height))\n".utf8))
                }
            }
            .onChange(of: geo.size) { _, _ in
                guard ProcessInfo.processInfo.environment["DISCOTECH_LOG_FRAMES"] != nil else { return }
                let f = geo.frame(in: .global)
                FileHandle.standardError.write(Data("frame \(tag) (resized): minY=\(Int(f.minY)) maxY=\(Int(f.maxY)) h=\(Int(f.height))\n".utf8))
            }
        })
    }
}
#endif
