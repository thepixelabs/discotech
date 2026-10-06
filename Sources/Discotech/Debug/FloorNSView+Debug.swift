#if DEBUG
import AppKit
import QuartzCore

/// The Floor's DEBUG-only state (one stored property on `FloorNSView`).
struct FloorDebugState {
    var hoverDone = false
    var clickDone = false
    var emphasisDone = false
    var resizeDone = false
    var selectDone = false
    var fadeFrames = 0
    var transitionFrames = 0
    var fitLogged: Set<String> = []
}

extension FloorNSView {
    // MARK: - DISCOTECH_FLOOR_TIMING

    func debugLogLayout(_ built: FloorLayout, started: CFTimeInterval) {
        if ProcessInfo.processInfo.environment["DISCOTECH_FLOOR_TIMING"] != nil {
            let ms = (CACurrentMediaTime() - started) * 1000
            FileHandle.standardError.write(Data(String(format: "floor layout: %.1f ms, %d tiles, %dx%d grid, edge %.1f, %d regions, %d leaves\n",
                                                       ms, built.tileCount, built.columns, built.rows, built.edge,
                                                       built.regions.count, built.leaves.count).utf8))
        }
    }

    func debugLogRender(started: CFTimeInterval, scale: CGFloat) {
        if ProcessInfo.processInfo.environment["DISCOTECH_FLOOR_TIMING"] != nil {
            FileHandle.standardError.write(Data(String(format: "floor render: %.1f ms at %.0fx\n",
                                                       (CACurrentMediaTime() - started) * 1000, scale).utf8))
        }
    }

    func debugTransitionEnded(_ t: Transition) {
        if ProcessInfo.processInfo.environment["DISCOTECH_FLOOR_TIMING"] != nil {
            FileHandle.standardError.write(Data("floor transition \(t.kind): \(debug.transitionFrames) frames, anchor \(t.anchor.map { "\($0.integral)" } ?? "none")\n".utf8))
        }
        debug.transitionFrames = 0
    }

    /// One frame of the highlight fade (`advanceBlend`).
    func debugFadeFrame() {
        debug.fadeFrames += 1
        if blendProgress >= 1, ProcessInfo.processInfo.environment["DISCOTECH_FLOOR_TIMING"] != nil {
            FileHandle.standardError.write(Data("floor highlight fade: \(debug.fadeFrames) frames (reduce motion \(reduceMotion))\n".utf8))
            debug.fadeFrames = 0
        }
    }

    // MARK: - Screenshot hooks

    static func secondsSinceLaunch() -> Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return 0 }
        let start = info.kp_proc.p_starttime
        let started = Double(start.tv_sec) + Double(start.tv_usec) / 1e6
        return Date().timeIntervalSince1970 - started
    }

    /// Screenshot-only hooks, driven through the same pointer/click paths as the mouse:
    ///   DISCOTECH_FLOOR_HOVER=deep|top|header  point at the largest child inside a region, the
    ///                                          largest flat region, or the largest region's header
    ///   DISCOTECH_FLOOR_CLICK=1|@t             click the largest folder once (drill in), 1 s after the
    ///                                          first frame or t s after launch
    ///   DISCOTECH_FLOOR_CLICK_BACK=1           …and 1.5 s later click the background (back out)
    ///   DISCOTECH_FLOOR_EMPHASIZE=name         emphasize every item with that name (as a Findings card would)
    ///   DISCOTECH_FLOOR_SELECT=deep|top        select the 2nd-largest child in a region / flat region
    ///   DISCOTECH_FLOOR_RESIZE=WxH@t           t s after launch, resize the window to WxH in 12 steps (settle check)
    ///   DISCOTECH_FLOOR_TIMING=1               log layout and render times
    func runDebugHooks(layout: FloorLayout, geo: FloorGeometry) {
        let env = ProcessInfo.processInfo.environment
        func centre(_ r: CGRect) -> CGPoint { let v = geo.view(r); return CGPoint(x: v.midX, y: v.midY) }
        // Fit check: where the floor sits in the view, once per size.
        if env["DISCOTECH_FLOOR_FIT"] != nil {
            let key = "\(Int(bounds.width))x\(Int(bounds.height))/\(Theme.current.rawValue)"
            if !debug.fitLogged.contains(key) {
                debug.fitLogged.insert(key)
                var box = CGRect.null
                for region in layout.regions { box = box.union(geo.view(region.rect)) }
                let window = self.window?.contentLayoutRect.size ?? .zero
                FileHandle.standardError.write(Data(String(format: "floor fit: window %.0fx%.0f view %.0fx%.0f floor x %.1f…%.1f y %.1f…%.1f margins L %.1f R %.1f B %.1f T %.1f grid %dx%d cell %.2fx%.2f\n",
                    window.width, window.height, bounds.width, bounds.height, box.minX, box.maxX, box.minY, box.maxY,
                    box.minX, bounds.width - box.maxX, box.minY, bounds.height - box.maxY,
                    layout.columns, layout.rows, layout.cellWidth, layout.cellHeight).utf8))
            }
        }
        if !debug.resizeDone, let spec = env["DISCOTECH_FLOOR_RESIZE"] {
            // "WxH@t[,WxH@t…]": t s after launch, resize the window to WxH in 12 quick steps.
            debug.resizeDone = true
            var from = window?.contentLayoutRect.size ?? .zero
            for item in spec.split(separator: ",") {
                let parts = item.split(separator: "@")
                let dims = parts.first?.split(separator: "x").compactMap { Double($0) } ?? []
                let at = parts.count > 1 ? Double(parts[1]) ?? 3 : 3
                guard dims.count == 2, let window else { continue }
                let start = from
                from = NSSize(width: dims[0], height: dims[1])
                let delay = max(0, at - Self.secondsSinceLaunch())
                for k in 1...12 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay + Double(k) * 0.016) {
                        let f = CGFloat(k) / 12
                        window.setContentSize(NSSize(width: start.width + (dims[0] - start.width) * f,
                                                     height: start.height + (dims[1] - start.height) * f))
                        if k == 12 { FileHandle.standardError.write(Data("floor resized to \(Int(dims[0]))x\(Int(dims[1]))\n".utf8)) }
                    }
                }
            }
        }
        if !debug.clickDone, let spec = env["DISCOTECH_FLOOR_CLICK"] {
            debug.clickDone = true
            if let i = layout.leaves.indices.filter({ layout.leaves[$0].node?.isDirectory == true && layout.leaves[$0].kind == .item })
                .max(by: { layout.leaves[$0].size < layout.leaves[$1].size }) {
                let p = centre(layout.leaves[i].rect)
                // "@t": at t seconds after launch (to line up with DISCOTECH_SNAPSHOTS); else 1 s from now.
                var delay = 1.0
                if spec.hasPrefix("@"), let at = Double(spec.dropFirst()) { delay = max(0, at - Self.secondsSinceLaunch()) }
                FileHandle.standardError.write(Data("floor click: \(layout.leaves[i].node?.path ?? "?") in \(delay) s\n".utf8))
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    self.click(at: p)
                    // Then back out again, through the background click path.
                    if env["DISCOTECH_FLOOR_CLICK_BACK"] != nil {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.click(at: CGPoint(x: 2, y: 2)) }
                    }
                }
            }
            return
        }
        if !debug.emphasisDone, let name = env["DISCOTECH_FLOOR_EMPHASIZE"] {
            debug.emphasisDone = true
            var found: [FileNode] = []
            var stack = [layout.focus]
            while let node = stack.popLast() {
                if node.name == name { found.append(node); continue }
                stack.append(contentsOf: node.children)
            }
            FileHandle.standardError.write(Data("floor emphasize: \(found.count) × \(name)\n".utf8))
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.appState?.emphasize(found) }
        }
        if !debug.selectDone, let mode = env["DISCOTECH_FLOOR_SELECT"] {
            debug.selectDone = true
            // deep: the second-largest child inside a region; top: the second-largest flat region.
            let depth = mode == "top" ? 0 : 1
            let ranked = layout.leaves.indices.filter { layout.leaves[$0].depth == depth && layout.leaves[$0].node != nil }
                .sorted { layout.leaves[$0].size > layout.leaves[$1].size }
            if let li = ranked.dropFirst().first ?? ranked.first, let node = layout.leaves[li].node {
                FileHandle.standardError.write(Data("floor select: \(node.name)\n".utf8))
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.appState?.selected = node }
            }
        }
        if !debug.hoverDone, let mode = env["DISCOTECH_FLOOR_HOVER"] {
            debug.hoverDone = true
            var point: CGPoint?
            var label = ""
            switch mode {
            case "header":
                if let ri = layout.regions.indices.filter({ layout.regions[$0].isSubdivided }).max(by: { layout.regions[$0].count < layout.regions[$1].count }) {
                    point = centre(layout.regions[ri].headerRect); label = layout.regions[ri].displayName
                }
            case "top":
                if let li = layout.leaves.indices.filter({ layout.leaves[$0].depth == 0 }).max(by: { layout.leaves[$0].size < layout.leaves[$1].size }) {
                    point = centre(layout.leaves[li].rect); label = layout.leaves[li].displayName
                }
            default:
                if let li = layout.leaves.indices.filter({ layout.leaves[$0].depth == 1 }).max(by: { layout.leaves[$0].size < layout.leaves[$1].size }) {
                    point = centre(layout.leaves[li].rect); label = layout.leaves[li].displayName
                }
            }
            if let point {
                FileHandle.standardError.write(Data("floor hover: \(label)\n".utf8))
                // After the window has settled, so a stray exit event can't clear it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self.pointerMoved(to: point) }
            }
        }
    }
}

/// DISCOTECH_SCROLL_TEST=t (with DISCOTECH_CANVAS=floor): t s after the Floor appears (it
/// waits for a laid-out floor), feed it synthetic scroll events through the real handler
/// and log PASS/FAIL per step to stderr: wheel over empty background with nothing selected
/// does nothing; one trackpad swipe up (plus its momentum) opens exactly one level; three
/// fast wheel notches down go out exactly one level; a notch up opens the folder under the
/// pointer again; a swipe down goes back out; a notch up over a child block inside a region
/// opens that child (the deepest folder under the pointer), and a swipe down goes out to
/// its enclosing folder. Navigation only: nothing on disk is touched.
extension FloorNSView {
    private static var scrollTestScheduled = false

    func scheduleScrollSelfTest() {
        guard !Self.scrollTestScheduled,
              let t = ProcessInfo.processInfo.environment["DISCOTECH_SCROLL_TEST"].flatMap(Double.init) else { return }
        Self.scrollTestScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.runScrollSelfTest(attempt: 0) }
    }

    private func log(_ text: String) { FileHandle.standardError.write(Data("scroll test: \(text)\n".utf8)) }

    private func runScrollSelfTest(attempt: Int) {
        guard let appState, let root = appState.focus else { return }
        guard let layout, layout.focus === root, !layout.isEmpty else {
            if attempt < 40 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.runScrollSelfTest(attempt: attempt + 1) } }
            else { log("FAIL no laid-out floor to aim at") }
            return
        }
        func openable(_ node: FileNode?) -> Bool { node.map { $0.isDirectory && !$0.children.isEmpty && !$0.isSynthetic } ?? false }
        func biggest(depth: Int) -> Int? {
            layout.leaves.indices.filter { layout.leaves[$0].depth == depth && openable(layout.leaves[$0].node) }
                .max { layout.leaves[$0].size < layout.leaves[$1].size }
        }
        // A folder block drawn flat at the top level; and a folder child inside a region.
        guard let topIndex = biggest(depth: 0), let top = layout.leaves[topIndex].node else { log("FAIL no folder to aim at"); return }
        let geo = geometry(for: layout)
        func centre(_ r: CGRect) -> CGPoint { let v = geo.view(r); return CGPoint(x: v.midX, y: v.midY) }
        let topPoint = centre(layout.leaves[topIndex].rect)
        let deepIndex = biggest(depth: 1)
        let deep = deepIndex.flatMap { layout.leaves[$0].node }
        let deepPoint = deepIndex.map { centre(layout.leaves[$0].rect) }
        func send(_ events: [NSEvent?], at point: CGPoint) { for e in events { if let e { _ = navigate(byScroll: e, at: point) } } }
        func check(_ label: String, _ expected: FileNode, then next: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                let ok = appState.focus === expected
                self?.log("\(ok ? "PASS" : "FAIL") \(label): focus=\(appState.focus?.name ?? "nil") expected=\(expected.name)")
                next()
            }
        }
        log("aiming at \(top.name) under \(root.name)" + (deep.map { "; child block \($0.name) in \($0.parent?.name ?? "?")" } ?? "; no child block to aim at"))
        let nowhere = CGPoint(x: 2, y: 2) // outside the grid: no block
        let scrollSelection = appState.selected
        appState.selected = nil
        // 0. Wheel up over empty background, nothing selected: no folder to open.
        send(ScrollTestEvents.notches(1, dy: 1), at: nowhere)
        check("notch up over nothing = stays", root) { [weak self] in
            guard let self else { return }
            // 1. Trackpad swipe up over the folder block → one level in.
            send(ScrollTestEvents.swipeUp(), at: topPoint)
            check("swipe up = one level in", top) { [weak self] in
                guard let self else { return }
                // 2. Three fast wheel notches down → one level out (cooldown).
                send(ScrollTestEvents.notches(3, dy: -1), at: topPoint)
                check("3 fast notches down = one level out", root) { [weak self] in
                    guard let self else { return }
                    // 3. One wheel notch up over the same spot → in again.
                    send(ScrollTestEvents.notches(1, dy: 1), at: topPoint)
                    check("notch up = in to the folder under the pointer", top) { [weak self] in
                        guard let self else { return }
                        // 4. Trackpad swipe down → out.
                        send(ScrollTestEvents.swipeDown(), at: topPoint)
                        check("swipe down = one level out", root) { [weak self] in
                            guard let self else { return }
                            guard let deep, let deepPoint, let parent = deep.parent else {
                                appState.selected = scrollSelection
                                self.log("done (no child block to test)"); return
                            }
                            // 5. Notch up over a child block inside a region → that child, not the region.
                            send(ScrollTestEvents.notches(1, dy: 1), at: deepPoint)
                            check("notch up over a child block = in to that child", deep) { [weak self] in
                                guard let self else { return }
                                // 6. Swipe down → out to the enclosing folder.
                                send(ScrollTestEvents.swipeDown(), at: deepPoint)
                                check("swipe down = out to the enclosing folder", parent) { [weak self] in
                                    appState.selected = scrollSelection
                                    self?.log("done")
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
#endif
