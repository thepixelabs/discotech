import SwiftUI
import AppKit

/// Bridges `AppState` into the `NSView`-based Layers chart. Kept separate from
/// `ColumnsView` so the public SwiftUI API stays a trivial wrapper, mirroring
/// `SunburstRepresentable`/`FloorView`'s private representable.
///
/// Unlike the old Miller-columns implementation, this is a plain `NSView` with no scroll
/// view: every visible depth column is sized to fit the available width (see
/// `ColumnsGeometry.columnWidths`), so there's nothing to scroll — the P0 "columns scroll
/// the drill path into an unreadable sliver" bug the old implementation had is gone by
/// construction, not patched.
struct ColumnsRepresentable: NSViewRepresentable {
    @EnvironmentObject var state: AppState

    func makeNSView(context: Context) -> ColumnsNSView {
        let view = ColumnsNSView()
        view.appState = state
        view.prime(focus: state.focus, treeVersion: state.treeVersion)
        return view
    }

    func updateNSView(_ view: ColumnsNSView, context: Context) {
        view.appState = state
        view.sync(focus: state.focus, treeVersion: state.treeVersion, externalHover: state.hovered,
                  emphasized: state.emphasized, selected: state.selected)
    }
}
