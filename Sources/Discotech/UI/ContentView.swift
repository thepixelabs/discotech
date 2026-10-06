import SwiftUI

/// Root view: one screen per scan phase.
struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Group {
            switch state.phase {
            case .start: StartView()
            case .scanning: ScanningView()
            case .browsing: BrowserView()
            }
        }
        // Brand violet everywhere the system would use its accent (segmented pickers,
        // toggles, focus rings, prominent buttons).
        .tint(Tokens.Colors.accent)
        #if DEBUG
        .task { DebugHooks.apply(to: state) }
        .onChange(of: state.phase) { _, phase in DebugHooks.phaseChanged(phase, state) }
        #endif
    }
}
