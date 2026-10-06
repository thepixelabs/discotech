import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    /// Posted on the main thread whenever `Theme.current` changes. Canvases that cache
    /// bitmaps or resolved colours (Ball, Layers, Floor) drop those caches and redraw.
    static let discotechThemeDidChange = Notification.Name("DiscotechThemeDidChange")
}

/// The app's switchable look. A theme drives the data colours (`Palette`, from the theme's
/// `ThemeRamp`: an ordered ramp from pale/dim to strong, so a stronger colour means more),
/// the highlight language (`CanvasHighlight`), the themed shell surfaces and accent in
/// `Tokens.Colors`. Switching is live: no rescan, the tree and the focus are kept.
enum Theme: String, CaseIterable, Identifiable {
    /// Blush pink to deep brand violet on blue-black / lavender; the default.
    case studio
    /// Spacey violet from the Pixelabs design system, lavender to intense violet, with an
    /// acid-green top step in dark mode; thin gradient hairlines, a faint nebula.
    case neon
    /// Pastel opal: peach through rose and orchid to periwinkle, with a hue-shifted
    /// holographic sheen on a deep aubergine / pale lilac surface.
    case iridescent
    /// Pale aqua to deep cobalt on a navy / mist surface.
    case ocean
    /// Pale peach to strong crimson (glowing gold in dark mode) on a warm dark / cream surface.
    case sunset
    /// Pale sage to deep pine (bright leaf in dark mode) on a green-black / sage surface.
    case forest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .studio: return "Studio"
        case .neon: return "Neon"
        case .iridescent: return "Iridescent"
        case .ocean: return "Ocean"
        case .sunset: return "Sunset"
        case .forest: return "Forest"
        }
    }

    /// One line for the Settings card (short: the card is a third of the window wide).
    var blurb: String {
        switch self {
        case .studio: return "Blush to deep violet"
        case .neon: return "Lavender to vivid violet"
        case .iridescent: return "Peach to periwinkle"
        case .ocean: return "Aqua to deep cobalt"
        case .sunset: return "Peach to crimson"
        case .forest: return "Sage to deep pine"
        }
    }

    /// The canvas / chart surface (`Tokens.Colors.canvas`): Studio and Neon share the
    /// brand's blue-black #0D0E14 and lavender #F4F2F7; Iridescent is the original
    /// aubergine and lilac; the others carry a tint of their own family.
    func canvasHex(dark: Bool) -> UInt32 {
        switch self {
        case .studio, .neon: return dark ? 0x0D0E14 : 0xF4F2F7
        case .iridescent: return dark ? 0x130E18 : 0xF9F6FB
        case .ocean: return dark ? 0x0A1118 : 0xEFF4F8
        case .sunset: return dark ? 0x140D0E : 0xFAF4F0
        case .forest: return dark ? 0x0C110D : 0xF2F5EF
        }
    }

    static let defaultsKey = "theme"
    static let fallback: Theme = .studio

    /// The theme whose window look (surfaces, accent, highlight) everything draws with right
    /// now: the chosen Gradient theme, or under the Multicolour palette style the Gradient theme
    /// the chosen Multicolour theme borrows (`SignalTheme.shell`). Data colours come from
    /// `Palette.ramp`. Change it through `ThemeStore.shared` so SwiftUI and the canvases hear.
    static var current: Theme { PaletteStyle.current == .signal ? SignalTheme.current.shell : storage }

    /// The chosen Gradient theme (kept while the Multicolour style is active).
    static var selected: Theme { storage }

    fileprivate static var storage: Theme = initial()

    /// `defaults` and `environment` are injectable for tests; the app passes neither.
    static func initial(defaults: UserDefaults = .standard,
                        environment: [String: String] = ProcessInfo.processInfo.environment) -> Theme {
        #if DEBUG
        // DISCOTECH_THEME=studio|neon|iridescent|ocean|sunset|forest for screenshots; not
        // persisted. An unknown stored or env value falls back to the default (`fallback`).
        if let spec = environment["DISCOTECH_THEME"]?.lowercased(), let theme = Theme(rawValue: spec) {
            return theme
        }
        #endif
        return defaults.string(forKey: defaultsKey).flatMap(Theme.init(rawValue:)) ?? fallback
    }
}

/// The observable side of `Theme`, for SwiftUI (Settings, the View menu, the root
/// view) — the single place it is changed.
@MainActor
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()

    @Published var theme: Theme {
        didSet {
            guard theme != oldValue else { return }
            Theme.storage = theme
            #if DEBUG
            if ProcessInfo.processInfo.environment["DISCOTECH_THEME"] == nil {
                defaults.set(theme.rawValue, forKey: Theme.defaultsKey)
            }
            #else
            defaults.set(theme.rawValue, forKey: Theme.defaultsKey)
            #endif
            NotificationCenter.default.post(name: .discotechThemeDidChange, object: nil)
        }
    }

    /// Settings → Palette style.
    @Published var style: PaletteStyle {
        didSet {
            guard style != oldValue else { return }
            PaletteStyle.storage = style
            if !PaletteStyle.isOverridden { defaults.set(style.rawValue, forKey: PaletteStyle.defaultsKey) }
            NotificationCenter.default.post(name: .discotechThemeDidChange, object: nil)
        }
    }

    /// The chosen Multicolour theme (used while `style == .signal`).
    @Published var signal: SignalTheme {
        didSet {
            guard signal != oldValue else { return }
            SignalTheme.storage = signal
            if !PaletteStyle.isOverridden { defaults.set(signal.rawValue, forKey: SignalTheme.defaultsKey) }
            NotificationCenter.default.post(name: .discotechThemeDidChange, object: nil)
        }
    }

    /// Identity of everything that changes the look, for views rebuilt on a switch.
    var lookID: String { "\(style.rawValue)-\(theme.rawValue)-\(signal.rawValue)" }

    private let defaults: UserDefaults

    /// `defaults` is injectable so tests never write the real settings; the app uses `shared`.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        theme = Theme.storage
        style = PaletteStyle.storage
        signal = SignalTheme.storage
        #if DEBUG
        DebugHooks.scheduleThemeSwitches(self)
        #endif
    }
}
