import SwiftUI

/// Bridges `AppState` into the `NSView`-based chart. Kept separate from
/// `SunburstView` so the public SwiftUI API stays a trivial wrapper.
struct SunburstRepresentable: NSViewRepresentable {
    @EnvironmentObject var state: AppState

    func makeNSView(context: Context) -> SunburstNSView {
        let view = SunburstNSView()
        view.appState = state
        view.prime(focus: state.focus, treeVersion: state.treeVersion)
        return view
    }

    func updateNSView(_ view: SunburstNSView, context: Context) {
        view.appState = state
        view.sync(focus: state.focus, treeVersion: state.treeVersion, externalHover: state.hovered,
                  emphasized: state.emphasized, selected: state.selected)
    }
}
