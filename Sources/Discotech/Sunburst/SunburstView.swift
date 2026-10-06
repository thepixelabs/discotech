import SwiftUI

/// Public entry point for the sunburst work stream: the Ball canvas mode. Placed in the
/// main window's detail area by another work stream; this view only renders the chart for
/// `state.focus` and reacts to `state.hovered`/`state.treeVersion`.
struct SunburstView: View {
    @EnvironmentObject var state: AppState

    /// One line teaching the Ball's scroll navigation (the idle hover hint shows it).
    static let scrollHint = "Scroll up to go in, down to go out"

    var body: some View {
        Group {
            if let focus = state.focus {
                SunburstRepresentable()
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("Ball: disk usage chart"))
                    .accessibilityValue(Text("\(focus.name), \(ByteFormat.string(focus.size))"))
                    .accessibilityAddTraits(.updatesFrequently)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
