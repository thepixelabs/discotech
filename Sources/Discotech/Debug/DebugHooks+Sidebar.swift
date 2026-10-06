#if DEBUG
import SwiftUI

extension DebugHooks {
    /// DISCOTECH_SIDEBAR_TAB=findings|items  overrides the sidebar's default tab after a
    /// scan, so (e.g.) a folder scan — which normally defaults to Items — can still be
    /// screenshotted on Findings.
    static var forcedSidebarTab: SidebarView.Tab? {
        ProcessInfo.processInfo.environment["DISCOTECH_SIDEBAR_TAB"].flatMap(SidebarView.Tab.init(rawValue:))
    }

    /// The sidebar instance that appeared last (a theme change rebuilds it).
    private static var lastSidebar: ObjectIdentifier?
    private static var themeKeepsScheduled = false

    /// DISCOTECH_EMPHASIZE_FINDING: once Findings has finished computing with the Findings
    /// tab showing, emphasizes that finding's nodes.
    static func findingsComputed(_ computing: Bool, _ state: AppState, _ findingsModel: FindingsModel) {
        guard !computing, state.sidebarTab == .findings, let index = DebugHooks.emphasizeFindingIndex,
              findingsModel.findings.indices.contains(index) else { return }
        let nodes = findingsModel.findings[index].nodes
        // A beat after the cards finish laying out, so a card's own mount-time
        // `onHover(false)` (SwiftUI fires one on first appearance) can't race this
        // debug-only emphasis and clear it before the screenshot fires.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { state.emphasize(nodes) }
    }

    static func sidebarAppeared(_ state: AppState, instance: ObjectIdentifier) {
        lastSidebar = instance
        runFindingsGateTest(state)
        scheduleThemeKeepsTest(state)
    }

    /// DISCOTECH_TEST_THEME_KEEPS=t: t s after the sidebar first appears, picks the Findings
    /// tab (as a click would), opens the first finding's list, then switches the theme, which
    /// rebuilds the window. Logs the sidebar instance, tab, open list and Findings walks
    /// before and after: the instance changes, nothing else may.
    private static func scheduleThemeKeepsTest(_ state: AppState) {
        guard let t = ProcessInfo.processInfo.environment["DISCOTECH_TEST_THEME_KEEPS"].flatMap(Double.init),
              !themeKeepsScheduled else { return }
        themeKeepsScheduled = true
        func report(_ when: String) {
            let line = "theme keeps test: \(when): sidebar \(lastSidebar.map { "\($0)" } ?? "none"), tab \(state.sidebarTab), "
                + "list \(state.detailFinding?.id ?? "none"), \(state.findings.findings.count) findings, "
                + "\(findingsWalks.started) walk(s) so far\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + t) {
            state.sidebarTab = .findings
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                guard let first = state.findings.findings.first else { report("FAIL no findings"); return }
                state.openFindingDetail(first)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    report("before the theme switch")
                    let themes = ThemeStore.shared
                    themes.theme = themes.theme == .neon ? .studio : .neon
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { report("after the switch to \(themes.theme.rawValue)") }
                }
            }
        }
    }
}
#endif
