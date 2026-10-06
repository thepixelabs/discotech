import SwiftUI

/// Public entry point for "Layers" — a left-to-right partition (icicle) chart. Column 1
/// splits `state.focus`'s children by exact proportional height; each later column splits
/// its own children the same way, inside the vertical span it already owns, so 2–4 levels
/// are visible at once, all to true scale — the "macro view the Columns tab was missing"
/// fix. Clicking a folder band zooms in (`state.zoom(into:)`, same move as the Ball's center
/// orb); clicking a file selects it; clicking the spine or the empty canvas zooms out. See
/// `ColumnsNSView` for the drawing/interaction and `ColumnsLayout` for the pure layout math.
struct ColumnsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Group {
            if let focus = state.focus {
                ColumnsRepresentable()
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("Disk usage columns"))
                    .accessibilityValue(Text("\(focus.name), \(ByteFormat.string(focus.size))"))
                    .accessibilityAddTraits(.updatesFrequently)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
