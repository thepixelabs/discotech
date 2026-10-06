import AppKit
import Combine
import Quartz
import SwiftUI

/// Space-bar Quick Look for the browsing screen.
///
/// A real `NSResponder` spliced into the main window's responder chain (right after the
/// window), so `QLPreviewPanel` finds it via `acceptsPreviewPanelControl` no matter which
/// view has focus — sidebar or chart. It is the panel's data source and delegate.
///
/// What gets previewed: `state.selected ?? state.hovered`, never a synthetic node. While
/// the panel is open the preview follows `state.selected` (arrow keys in the sidebar,
/// clicks in the chart); hovering alone doesn't change it, so the preview doesn't flicker
/// as the pointer crosses the chart.
@MainActor
final class QuickLookController: NSResponder, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookController()

    private weak var state: AppState?
    private weak var window: NSWindow?
    private var keyMonitor: Any?
    private var selectionSubscription: AnyCancellable?
    private var previewURL: URL?
    private var controllingPanel = false

    // MARK: Install / remove (browsing screen lifetime)

    func install(in window: NSWindow, state: AppState) {
        guard self.window !== window || self.state !== state else { return }
        uninstall()
        self.state = state
        self.window = window
        nextResponder = window.nextResponder
        window.nextResponder = self

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKeyDown(event) ? nil : event
        }
        selectionSubscription = state.$selected
            .receive(on: RunLoop.main)
            .sink { [weak self] node in self?.selectionChanged(to: node) }
    }

    func uninstall() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        selectionSubscription = nil
        if let window, window.nextResponder === self { window.nextResponder = nextResponder }
        nextResponder = nil
        if isPanelOpen { QLPreviewPanel.shared()?.orderOut(nil) }
        window = nil
        state = nil
    }

    // MARK: Public actions

    var isPanelOpen: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }

    /// Space: open for the current item, or close if already open.
    func toggle() {
        if isPanelOpen {
            QLPreviewPanel.shared().orderOut(nil)
            return
        }
        guard let node = previewCandidate else { NSSound.beep(); return }
        show(node)
    }

    /// Context-menu "Quick Look": select `node` and preview it.
    func preview(_ node: FileNode) {
        guard !node.isSynthetic else { return }
        state?.selected = node
        show(node)
    }

    // MARK: Internals

    private var previewCandidate: FileNode? {
        guard let node = state?.selected ?? state?.hovered, !node.isSynthetic else { return nil }
        return node
    }

    private func show(_ node: FileNode) {
        previewURL = node.url
        window?.makeKey()  // the panel asks the key window's responder chain for a controller
        let panel = QLPreviewPanel.shared()!
        panel.updateController()
        if controllingPanel { panel.reloadData() }
        panel.orderFront(nil)
    }

    private func selectionChanged(to node: FileNode?) {
        guard controllingPanel, isPanelOpen, let node, !node.isSynthetic else { return }
        previewURL = node.url
        QLPreviewPanel.shared().reloadData()
        debugLog("now previewing \(node.path)")
    }

    /// Space toggles; ↑/↓ move the selection while the panel is up. Returns true if handled.
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let window, state?.phase == .browsing else { return false }
        let panelIsKey = isPanelOpen && NSApp.keyWindow === QLPreviewPanel.shared()
        guard NSApp.keyWindow === window || panelIsKey else { return false }
        // Never steal keys from text editing (search fields, rename, …).
        if window.firstResponder is NSText { return false }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        guard mods.isEmpty else { return false }

        switch event.keyCode {
        case 49:  // Space
            if !event.isARepeat { toggle() }  // holding Space must not flicker the panel
            return true
        case 125, 126:  // ↓ ↑
            // Only while previewing: arrows step through the sidebar's rows (whether the
            // item came from a row or a chart click), and the preview follows. With the
            // panel closed they fall through to the sidebar's own key handling.
            guard isPanelOpen else { return false }
            moveSelection(by: event.keyCode == 125 ? 1 : -1)
            return true
        default:
            return false
        }
    }

    /// Steps `state.selected` through the rows the sidebar lists (children of the focus),
    /// skipping synthetic rows, which can't be previewed. The sidebar follows the
    /// selection (focus ring + scroll) on its own.
    private func moveSelection(by delta: Int) {
        guard let state, let focus = state.focus else { return }
        let rows = focus.children.prefix(Tokens.sidebarRowLimit).filter { !$0.isSynthetic }
        guard !rows.isEmpty else { return }
        let current = state.selected.flatMap { selected in rows.firstIndex { $0 === selected } }
            ?? (delta > 0 ? -1 : rows.count)
        let next = rows[max(0, min(rows.count - 1, current + delta))]
        guard next !== state.selected else { return }
        state.selected = next
        state.hovered = next
    }

    // MARK: QLPreviewPanelController (informal protocol on NSResponder)

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        controllingPanel = true
        panel.dataSource = self
        panel.delegate = self
        debugLog("begin control, previewing \(previewURL?.path ?? "nothing")")
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        controllingPanel = false
        panel.dataSource = nil
        panel.delegate = nil
        debugLog("end control")
    }

    /// DEBUG builds with DISCOTECH_QL_LOG set: trace panel control to stderr.
    func debugLog(_ message: @autoclosure () -> String) {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["DISCOTECH_QL_LOG"] != nil else { return }
        FileHandle.standardError.write(Data("quicklook: \(message()) (panel open: \(isPanelOpen))\n".utf8))
        #endif
    }

    // MARK: QLPreviewPanelDataSource

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { previewURL == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { previewURL.map { $0 as NSURL } }
    }

    // MARK: QLPreviewPanelDelegate

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        return MainActor.assumeIsolated { handleKeyDown(event) }
    }
}

/// Hands the hosting `NSWindow` to a callback once the view is in a window.
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let window = view.window { onWindow(window) } }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { if let window = nsView.window { onWindow(window) } }
    }
}
