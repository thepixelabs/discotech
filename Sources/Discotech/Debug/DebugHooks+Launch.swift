#if DEBUG
import AppKit

extension DebugHooks {
    /// Launch-time hooks, from `AppDelegate.applicationDidFinishLaunching`.
    static func applicationLaunched() {
        // DISCOTECH_OPEN_SETTINGS=t: open the Settings window t s after launch (screenshots).
        if let t = ProcessInfo.processInfo.environment["DISCOTECH_OPEN_SETTINGS"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                // The app menu's own "Settings…" item (⌘,), as a click on it would.
                guard let menu = NSApp.mainMenu?.items.first?.submenu,
                      let index = menu.items.firstIndex(where: { $0.keyEquivalent == "," }) else { return }
                menu.performActionForItem(at: index)
            }
        }
        // DISCOTECH_OPEN_HELP=t: open Help → Discotech Help t s after launch (screenshots).
        if let t = ProcessInfo.processInfo.environment["DISCOTECH_OPEN_HELP"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                guard let menu = NSApp.helpMenu ?? NSApp.mainMenu?.items.last?.submenu,
                      let index = menu.items.firstIndex(where: { $0.title.hasSuffix(" Help") }) else { return }
                menu.performActionForItem(at: index)
            }
        }
        // DISCOTECH_OPEN_TERMS=t: open Help → Discotech Terms of Use… t s after launch (screenshots).
        if let t = ProcessInfo.processInfo.environment["DISCOTECH_OPEN_TERMS"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                guard let menu = NSApp.helpMenu ?? NSApp.mainMenu?.items.last?.submenu,
                      let index = menu.items.firstIndex(where: { $0.title == "\(Terms.windowTitle)…" }) else { return }
                menu.performActionForItem(at: index)
            }
        }
    }

    /// From `ThemeStore.init`.
    static func scheduleThemeSwitches(_ store: ThemeStore) {
        // DISCOTECH_THEME_SWITCH=neon@8[,iridescent@12]: switch live at t s after launch
        // (checks that a mid-session switch redraws everything without a rescan).
        if let spec = ProcessInfo.processInfo.environment["DISCOTECH_THEME_SWITCH"] {
            for item in spec.split(separator: ",") {
                let parts = item.split(separator: "@")
                guard parts.count == 2, let theme = Theme(rawValue: String(parts[0])), let t = Double(parts[1]) else { continue }
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak store] in
                    FileHandle.standardError.write(Data("theme switch: \(theme.rawValue)\n".utf8))
                    store?.theme = theme
                }
            }
        }
    }
}
#endif
