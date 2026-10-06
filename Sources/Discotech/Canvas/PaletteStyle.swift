import Foundation

/// The two sets of themes in Settings → Palette style.
/// - Gradient: six single-family ramps, pale/dim to strong (`Theme`).
/// - Multicolour: six multi-hue ramps whose hue order carries the meaning, like a traffic
///   light (`SignalTheme`), so neighbouring steps are easier to tell apart.
/// Unknown or missing stored values fall back to Gradient, so a theme saved before palette
/// styles existed keeps working unchanged.
enum PaletteStyle: String, CaseIterable, Identifiable {
    case gradient
    case signal  // user-facing name: Multicolour; the raw value "signal" is persisted

    var id: String { rawValue }
    var title: String { self == .gradient ? "Gradient" : "Multicolour" }

    static let defaultsKey = "paletteStyle"

    /// The style everything draws with right now. Change it through `ThemeStore.shared.style`.
    static var current: PaletteStyle { storage }
    static var storage: PaletteStyle = initial()

    /// `defaults` and `environment` are injectable for tests; the app passes neither.
    static func initial(defaults: UserDefaults = .standard,
                        environment: [String: String] = ProcessInfo.processInfo.environment) -> PaletteStyle {
        #if DEBUG
        // DISCOTECH_PALETTE_STYLE=gradient|signal for screenshots; not persisted. A
        // Multicolour theme name in DISCOTECH_THEME implies Multicolour.
        let env = environment
        if let spec = env["DISCOTECH_PALETTE_STYLE"]?.lowercased(), let style = PaletteStyle(rawValue: spec) { return style }
        if let spec = env["DISCOTECH_THEME"]?.lowercased(), SignalTheme(rawValue: spec) != nil { return .signal }
        #endif
        return defaults.string(forKey: defaultsKey).flatMap(PaletteStyle.init(rawValue:)) ?? .gradient
    }

    /// True while a DEBUG env override is choosing the style or theme (nothing is persisted).
    static var isOverridden: Bool {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        return env["DISCOTECH_PALETTE_STYLE"] != nil || env["DISCOTECH_THEME"] != nil
        #else
        return false
        #endif
    }
}
