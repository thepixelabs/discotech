#if DEBUG
import AppKit

/// The Ball's DEBUG-only state (one stored property on `SunburstNSView`).
struct SunburstDebugState {
    var lastLoggedHoverKey: SunburstSegmentKey??
    var lastLoggedEmphasizedCount = -1
}

extension SunburstNSView {
    /// DISCOTECH_LOG_RING_GEOMETRY=1 also times every repaint (`draw`).
    func debugRepaintStart() -> CFAbsoluteTime? {
        ProcessInfo.processInfo.environment["DISCOTECH_LOG_RING_GEOMETRY"] != nil ? CFAbsoluteTimeGetCurrent() : nil
    }

    func debugRepaintEnd(_ profileStart: CFAbsoluteTime?) {
        if let profileStart {
            let ms = (CFAbsoluteTimeGetCurrent() - profileStart) * 1000
            FileHandle.standardError.write(Data("ring-repaint-ms \(String(format: "%.3f", ms))\n".utf8))
        }
    }

    func logGeometryIfNeeded(hk: SunburstSegmentKey?, layout: SunburstLayout, maxR: CGFloat) {
        guard ProcessInfo.processInfo.environment["DISCOTECH_LOG_RING_GEOMETRY"] != nil else { return }
        let hkChanged = debug.lastLoggedHoverKey == nil || debug.lastLoggedHoverKey! != hk
        let emphChanged = emphasized.count != debug.lastLoggedEmphasizedCount
        guard hkChanged || emphChanged else { return }
        debug.lastLoggedHoverKey = hk
        debug.lastLoggedEmphasizedCount = emphasized.count
        let hoveredMatches = layout.segments.filter { $0.key == hk }
        let liftedByEmphasis = layout.segments.filter { !emphasized.isEmpty && isNodeEmphasized($0.node) }
        var out = "ring-geometry hk=\(describeKey(hk)) maxR=\(maxR) totalSegments=\(layout.segments.count) hoveredMatchCount=\(hoveredMatches.count) emphasizedCount=\(emphasized.count) liftedByEmphasisCount=\(liftedByEmphasis.count)\n"
        for m in hoveredMatches {
            out += "  HOVER-MATCH seg=\(m.displayName) depth=\(m.depth) inner=\(m.innerFrac) outer=\(m.outerFrac)\n"
        }
        for m in liftedByEmphasis {
            out += "  EMPHASIS-LIFTED seg=\(m.displayName) depth=\(m.depth) inner=\(m.innerFrac) outer=\(m.outerFrac) (would draw at inner+\(SunburstConstants.hoverLiftPoints), outer+\(SunburstConstants.hoverLiftPoints))\n"
        }
        for seg in layout.segments where seg.depth <= 1 {
            let isHovered = seg.key == hk
            let isEmph = !emphasized.isEmpty && isNodeEmphasized(seg.node)
            out += "  seg=\(describeKey(seg.key)) depth=\(seg.depth) inner=\(seg.innerFrac) outer=\(seg.outerFrac) start=\(seg.startAngle) end=\(seg.endAngle) isHovered=\(isHovered) isEmph=\(isEmph)\n"
        }
        FileHandle.standardError.write(Data(out.utf8))
    }
    func describeKey(_ key: SunburstSegmentKey?) -> String {
        guard let key else { return "nil" }
        switch key {
        case .node(let id): return currentLayout?.segments.first { $0.key == key }?.displayName ?? "node(\(id))"
        case .other(_, let depth): return "other@\(depth)"
        }
    }
}

/// DISCOTECH_TEST_BALL_LEAK=<what>-<how>@t, what = zoom|hover, how = canvas|theme|none: t s
/// after the Ball first appears, start a zoom (0.35 s) or a hover cross-fade (0.12 s) and,
/// 50 ms later, switch the canvas to Floor or the theme (which rebuilds the window). Then
/// logs the Ball's animation-timer fires per second for 4 s; once the Ball is gone they
/// must be 0. Navigation and drawing only — nothing on disk is touched.
extension SunburstNSView {
    nonisolated(unsafe) static var debugTimerFires = 0
    nonisolated(unsafe) static var debugLiveViews = 0
    private static var leakTestScheduled = false

    private static func leakLog(_ text: String) { FileHandle.standardError.write(Data("ball leak test: \(text)\n".utf8)) }

    func scheduleLeakTest() {
        guard !Self.leakTestScheduled, let spec = ProcessInfo.processInfo.environment["DISCOTECH_TEST_BALL_LEAK"] else { return }
        let parts = spec.split(separator: "@")
        let kinds = parts.first?.split(separator: "-").map(String.init) ?? []
        guard parts.count == 2, kinds.count == 2, let t = Double(parts[1]) else { Self.leakLog("FAIL bad spec \(spec)"); return }
        Self.leakTestScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.runLeakTest(what: kinds[0], how: kinds[1]) }
    }

    private func runLeakTest(what: String, how: String) {
        guard let appState, let focus = appState.focus,
              let target = focus.children.first(where: { $0.isDirectory && !$0.isSynthetic && !$0.children.isEmpty })
        else { Self.leakLog("FAIL nothing to zoom into"); return }
        if what == "zoom" {
            appState.zoom(into: target)
            sync(focus: appState.focus, treeVersion: appState.treeVersion, externalHover: nil, emphasized: [], selected: nil)
        } else {
            sync(focus: focus, treeVersion: appState.treeVersion, externalHover: target, emphasized: [], selected: nil)
            display()  // draws now, which starts the hover cross-fade
        }
        Self.leakLog("\(what) started: zoom timer \(displayTimer != nil ? "running" : "idle"), hover timer \(hoverBlendTimer != nil ? "running" : "idle")")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if how == "none" {
                Self.leakLog("no switch (control: the animation runs to its end and stops)")
            } else if how == "theme" {
                let themes = ThemeStore.shared
                themes.theme = themes.theme == .neon ? .studio : .neon
                Self.leakLog("switched theme to \(themes.theme.rawValue) 50 ms later")
            } else {
                appState.canvasMode = .floor
                Self.leakLog("switched canvas to floor 50 ms later")
            }
            Self.reportFires(round: 1, since: Self.debugTimerFires)
        }
    }

    private static func reportFires(round: Int, since: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let now = debugTimerFires
            leakLog("second \(round): \(now - since) Ball timer fires, \(debugLiveViews) Ball view(s) alive")
            if round < 4 { reportFires(round: round + 1, since: now) } else { leakLog("done") }
        }
    }
}

/// DISCOTECH_SCROLL_TEST=t: t s after the Ball appears, feed it synthetic scroll events
/// through the real handler and log PASS/FAIL per step to stderr: one trackpad swipe up
/// (plus its momentum) opens exactly one level; three fast wheel notches down go out
/// exactly one level; a wheel notch up opens the folder under the pointer again; a
/// trackpad swipe down goes back out. Navigation only — nothing on disk is touched.
extension SunburstNSView {
    private static var scrollTestScheduled = false

    func scheduleScrollSelfTest() {
        guard !Self.scrollTestScheduled,
              let t = ProcessInfo.processInfo.environment["DISCOTECH_SCROLL_TEST"].flatMap(Double.init) else { return }
        Self.scrollTestScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.runScrollSelfTest() }
    }

    private func log(_ text: String) { FileHandle.standardError.write(Data("scroll test: \(text)\n".utf8)) }

    private func scrollEvent(dy: Int32, precise: Bool, phase: Int64 = 0, momentum: Int64 = 0) -> NSEvent? {
        ScrollTestEvents.make(dy: dy, precise: precise, phase: phase, momentum: momentum)
    }

    private func runScrollSelfTest() {
        guard let appState, let root = appState.focus, let layout = currentLayout,
              let target = layout.segmentsByDepth.first?
                .filter({ $0.node?.isDirectory == true && !($0.node?.children.isEmpty ?? true) })
                .max(by: { ($0.endAngle - $0.startAngle) < ($1.endAngle - $1.startAngle) }),
              let folder = target.node else { log("FAIL no folder to aim at"); return }
        let maxR = min(bounds.width, bounds.height) / 2 - SunburstConstants.outerPadding
        let offset = sunburstPolarPoint(angle: (target.startAngle + target.endAngle) / 2,
                                        radius: (target.innerFrac + target.outerFrac) / 2 * maxR)
        let point = CGPoint(x: bounds.midX + offset.x, y: bounds.midY + offset.y)
        func send(_ events: [NSEvent?]) { for e in events { if let e { _ = navigate(byScroll: e, at: point) } } }
        func check(_ label: String, _ expected: FileNode, then next: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                let ok = appState.focus === expected
                self?.log("\(ok ? "PASS" : "FAIL") \(label): focus=\(appState.focus?.name ?? "nil") expected=\(expected.name)")
                next()
            }
        }
        log("aiming at \(folder.name) under \(root.name)")
        // 1. Trackpad swipe up: began, 8 × 6 pt, ended, then momentum → one level in.
        // Built step by step: one long `+` chain is too much for older compilers to type-check.
        var swipeUp: [NSEvent?] = [scrollEvent(dy: 0, precise: true, phase: 1)]
        for _ in 0..<8 { swipeUp.append(scrollEvent(dy: 6, precise: true, phase: 2)) }
        swipeUp.append(scrollEvent(dy: 0, precise: true, phase: 4))
        for i in 0..<6 { swipeUp.append(scrollEvent(dy: 12, precise: true, momentum: i == 0 ? 1 : 2)) }
        send(swipeUp)
        check("swipe up = one level in", folder) { [weak self] in
            guard let self else { return }
            // 2. Three fast wheel notches down → one level out (cooldown).
            send((0..<3).map { _ in self.scrollEvent(dy: -1, precise: false) })
            check("3 fast notches down = one level out", root) { [weak self] in
                guard let self else { return }
                // 3. One wheel notch up over the same spot → in again.
                send([self.scrollEvent(dy: 1, precise: false)])
                check("notch up = in to the folder under the pointer", folder) { [weak self] in
                    guard let self else { return }
                    // 4. Trackpad swipe down → out.
                    var swipeDown: [NSEvent?] = [self.scrollEvent(dy: 0, precise: true, phase: 1)]
                    for _ in 0..<6 { swipeDown.append(self.scrollEvent(dy: -7, precise: true, phase: 2)) }
                    swipeDown.append(self.scrollEvent(dy: 0, precise: true, phase: 4))
                    send(swipeDown)
                    check("swipe down = one level out", root) { [weak self] in self?.log("done") }
                }
            }
        }
    }
}
#endif
