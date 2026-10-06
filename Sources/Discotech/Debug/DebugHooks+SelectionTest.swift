#if DEBUG
import AppKit
import SwiftUI

extension DebugHooks {
    /// DISCOTECH_TEST_SELECT=1|/shot.png  once the files view is up, drives its table with
    /// synthetic mouse and key events (steps below), logging the table's selected rows,
    /// the pane's selection count and the Crate's size to stderr after each one. Writes
    /// the window to the PNG (if a path is given) at the end or at a `p` step, then quits.
    /// Only selects rows and adds/takes out of the Crate (memory only); never trashes.
    static var selectionTestSpec: String? { ProcessInfo.processInfo.environment["DISCOTECH_TEST_SELECT"] }
    /// The pane's `picked.count`, mirrored for the log.
    static var pickedCount = 0

    private static func selectLog(_ message: String) {
        FileHandle.standardError.write(Data("selecttest: \(message)\n".utf8))
    }

    /// A test run usually starts behind whatever app the person is using, and macOS won't
    /// let it take the foreground. AppKit then treats each synthetic click as a click in
    /// a background window: plain clicks only try to activate the app, ⌘-clicks lose
    /// their ⌘, and ⌘A finds no key window. DISCOTECH_TEST_SELECT_ACTIVE=1 makes this
    /// process report itself active, its main window key, and the modifier keys of the
    /// event being handled as the ones held down, as a real click would. Letters pick
    /// the parts: `a` active + key, `m` modifier flags ("1" = both). `NSApp.keyWindow` is
    /// only faked around ⌘A (`withKeyWindow`): faked for good, it upsets mouse routing
    /// and plain clicks stop reaching the table.
    private static func pretendFrontmost(_ parts: String) {
        let all = parts == "1"
        func replace(_ method: Method?, _ block: Any) {
            if let method { method_setImplementation(method, imp_implementationWithBlock(block)) }
        }
        if all || parts.contains("a") {
            let yes: @convention(block) (AnyObject) -> Bool = { _ in true }
            replace(class_getInstanceMethod(NSApplication.self, #selector(getter: NSApplication.isActive)), yes)
            replace(class_getInstanceMethod(NSWindow.self, #selector(getter: NSWindow.isKeyWindow)), yes)
        }
        if all || parts.contains("m") {
            let flags: @convention(block) (AnyObject) -> UInt = { _ in
                NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue ?? 0
            }
            replace(class_getClassMethod(NSEvent.self, #selector(getter: NSEvent.modifierFlags)), flags)
        }
    }

    /// Runs `body` with `NSApp.keyWindow` reporting `window`, then puts it back.
    private static func withKeyWindow(_ window: NSWindow, _ body: () -> Void) {
        guard let method = class_getInstanceMethod(NSApplication.self, #selector(getter: NSApplication.keyWindow)) else {
            body(); return
        }
        let key: @convention(block) (NSApplication) -> NSWindow? = { [weak window] _ in window }
        let original = method_setImplementation(method, imp_implementationWithBlock(key))
        body()
        method_setImplementation(method, original)
    }

    private static func tables(in view: NSView) -> [NSTableView] {
        (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap { tables(in: $0) }
    }

    /// Where each `testTarget(name)` control is. SwiftUI builds no accessibility tree
    /// in-process until an assistive app asks, so buttons are found through these.
    private static var targets: [String: [WeakView]] = [:]
    struct WeakView { weak var view: NSView? }

    /// An empty view behind a control that records its place and lets every click through.
    struct TargetMarker: NSViewRepresentable {
        let name: String
        final class Marker: NSView {
            override func hitTest(_ point: NSPoint) -> NSView? { nil }
        }
        func makeNSView(context: Context) -> NSView {
            let view = Marker()
            DebugHooks.targets[name, default: []].append(WeakView(view: view))
            return view
        }
        func updateNSView(_ nsView: NSView, context: Context) {}
    }

    /// The on-screen marker for `name` (a `ViewThatFits` can build a copy it never shows).
    private static func target(_ name: String) -> NSView? {
        targets[name]?.compactMap(\.view).last { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor && $0.bounds.width > 0 }
    }

    /// DISCOTECH_TEST_SELECT_STEPS: comma-separated steps, run 0.8 s apart. `c3` click row 3,
    /// `C3` ⌘-click, `S3` ⇧-click, `X3` ⌘⇧-click, `t3` click row 3's Crate button (last
    /// column), `A` ⌘A (key event), `b=add` click that `testTarget` button (add, takeOut,
    /// addAll, takeAllOut), `h` hover/emphasis churn, `s` scroll to the end and back,
    /// `o=Size` click that column's header (sort), `k` log key-window/menu state, `p` or
    /// `p=name` snapshot now.
    static func runSelectionTest(_ state: AppState, finding: Finding) {
        let spec = selectionTestSpec ?? ""
        let steps = (ProcessInfo.processInfo.environment["DISCOTECH_TEST_SELECT_STEPS"]
                     ?? "c0,C2,C4,S7,C5,X9,h,s,o=Size,A,c1,C3,C6")
            .split(separator: ",").map(String.init)
        func window() -> NSWindow? { NSApp.windows.first { $0.isVisible && !($0 is NSPanel) && $0.contentView != nil } }
        func table() -> NSTableView? {
            guard let content = window()?.contentView else { return nil }
            return tables(in: content).max { $0.numberOfRows < $1.numberOfRows }
        }
        func post(_ event: NSEvent?) { if let event { NSApp.postEvent(event, atStart: false) } }
        func mouse(at p: NSPoint, mods: NSEvent.ModifierFlags, in window: NSWindow) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                post(NSEvent.mouseEvent(with: type, location: p, modifierFlags: mods,
                                        timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                        clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            }
        }
        func describe(_ view: NSView?) -> String {
            var chain: [String] = []
            var v = view
            while let cur = v, chain.count < 4 { chain.append(String(describing: type(of: cur))); v = cur.superview }
            return chain.joined(separator: " < ")
        }
        func menuItems(_ menu: NSMenu?) -> [NSMenuItem] {
            (menu?.items ?? []).flatMap { [$0] + menuItems($0.submenu) }
        }
        func perform(_ step: String) {
            guard let window = window(), let table = table() else { selectLog("no window/table"); return }
            let op = step.first ?? " "
            let arg = step.dropFirst()
            let named = arg.hasPrefix("=") ? String(arg.dropFirst()) : String(arg)
            switch op {
            case "c", "C", "S", "X", "t":
                guard let row = Int(arg), row < table.numberOfRows else { selectLog("  bad row \(arg)"); return }
                let mods: NSEvent.ModifierFlags = ["C": .command, "S": .shift, "X": [.command, .shift]][op] ?? []
                table.scrollRowToVisible(row)
                let cell = table.frameOfCell(atColumn: op == "t" ? table.numberOfColumns - 1 : 0, row: row)
                let p = table.convert(NSPoint(x: cell.midX, y: cell.midY), to: nil)
                selectLog("  hit: \(describe(window.contentView?.superview?.hitTest(p)))")
                mouse(at: p, mods: mods, in: window)
            case "A":
                // Sent, not posted, so the faked key window covers the whole key-equivalent pass
                // (window, then Edit ▸ Select All, then the first responder).
                withKeyWindow(window) {
                    for type in [NSEvent.EventType.keyDown, .keyUp] {
                        if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: .command,
                                                        timestamp: ProcessInfo.processInfo.systemUptime,
                                                        windowNumber: window.windowNumber, context: nil,
                                                        characters: "a", charactersIgnoringModifiers: "a",
                                                        isARepeat: false, keyCode: 0) {
                            NSApp.sendEvent(event)
                        }
                    }
                }
            case "b":
                guard let marker = target(named) else { selectLog("  no on-screen button \(named)"); return }
                let p = marker.convert(NSPoint(x: marker.bounds.midX, y: marker.bounds.midY), to: nil)
                selectLog("  button \(named) at \(Int(p.x)),\(Int(p.y)) hit: \(describe(window.contentView?.superview?.hitTest(p)))")
                mouse(at: p, mods: [], in: window)
            case "k":
                let selectAll = menuItems(NSApp.mainMenu).filter { $0.keyEquivalent == "a" }
                    .map { "\($0.title) action=\($0.action.map(NSStringFromSelector) ?? "nil")" }
                selectLog("  keyWindow=\(NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "nil") ⌘A items=\(selectAll) firstResponder=\(window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")")
            case "h":
                state.hovered = finding.nodes.first
                state.emphasize(finding.nodes)
                DispatchQueue.main.async {
                    state.clearEmphasis()
                    state.hovered = nil
                }
            case "s":
                table.scrollRowToVisible(table.numberOfRows - 1)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { table.scrollRowToVisible(0) }
            case "o":
                guard let header = table.headerView,
                      let column = table.tableColumns.firstIndex(where: { $0.title == named }) else {
                    selectLog("  no header column \(named)"); return
                }
                let r = header.headerRect(ofColumn: column)
                mouse(at: header.convert(NSPoint(x: r.midX, y: r.midY), to: nil), mods: [], in: window)
            case "p":  // `p` writes the given PNG, `p=x` writes it with "-x" before ".png"
                guard spec.hasSuffix(".png") else { return }
                snapshot(to: named.isEmpty ? spec : String(spec.dropLast(4)) + "-\(named).png")
            default:
                selectLog("  unknown step \(step)")
            }
        }
        let start = 2.0, gap = 0.8
        if let parts = ProcessInfo.processInfo.environment["DISCOTECH_TEST_SELECT_ACTIVE"] { pretendFrontmost(parts) }
        DispatchQueue.main.asyncAfter(deadline: .now() + start - 0.5) {
            let w = window()
            selectLog("window key=\(w?.isKeyWindow ?? false) appActive=\(NSApp.isActive) tables=\(w?.contentView.map { tables(in: $0).map { "\(type(of: $0)) rows=\($0.numberOfRows) multi=\($0.allowsMultipleSelection)" } } ?? [])")
            w?.makeKeyAndOrderFront(nil)
        }
        for (i, step) in steps.enumerated() {
            let t = start + Double(i) * gap
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                selectLog("step \(i): \(step)")
                perform(step)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + t + gap * 0.6) {
                guard let table = table() else { return }
                let rows = Array(table.selectedRowIndexes)
                selectLog("  -> table#\(UInt(bitPattern: ObjectIdentifier(table).hashValue) % 100_000) rows=\(table.numberOfRows) selectedRows=\(rows) count=\(rows.count) picked=\(pickedCount) crate=\(state.collected.count)")
            }
        }
        let end = start + Double(steps.count) * gap
        DispatchQueue.main.asyncAfter(deadline: .now() + end) {
            if spec.hasSuffix(".png"), !steps.contains(where: { $0.hasPrefix("p") }) { snapshot(to: spec) }
            selectLog("done")
            NSApp.terminate(nil)
        }
    }
}
#endif
