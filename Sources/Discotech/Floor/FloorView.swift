import SwiftUI

/// The Floor canvas mode: the focused folder as a map of calm rounded blocks, largest
/// first. Block areas are damped so smaller items stay readable; every label carries the
/// true size and share.
struct FloorView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var themes = ThemeStore.shared

    var body: some View {
        Group {
            if let focus = state.focus {
                FloorRepresentable(theme: themes.theme)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("Disk usage floor"))
                    .accessibilityValue(Text("\(focus.name), \(ByteFormat.string(focus.size))"))
                    .accessibilityAddTraits(.updatesFrequently)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.Colors.chartSurface)
    }
}

/// Bridges `AppState` into `FloorNSView`.
private struct FloorRepresentable: NSViewRepresentable {
    @EnvironmentObject var state: AppState
    /// Passed by value so SwiftUI calls `updateNSView` when it changes.
    let theme: Theme

    func makeNSView(context: Context) -> FloorNSView {
        let view = FloorNSView()
        view.appState = state
        return view
    }

    func updateNSView(_ view: FloorNSView, context: Context) {
        view.appState = state
        view.sync(focus: state.focus, treeVersion: state.treeVersion, hovered: state.hovered,
                  emphasized: state.emphasized, collected: state.collected, selected: state.selected)
    }
}
