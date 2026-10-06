import Foundation

/// The Multicolour set (`PaletteStyle.signal`): multi-hue ramps of `Palette.steps` steps,
/// smallest first, whose hue order reads as "more" (green → red, cool → hot, sea →
/// summit). Tuned in OKLCH: neighbouring
/// steps differ in hue *and* lightness (so, e.g., Traffic's green and red also differ for
/// red-green colour-blind eyes), and every step clears 4.5:1 with white or ink labels
/// (lowest about 4.8:1), in light and dark. Dark mode keeps the same hue order with brighter,
/// more luminous steps. Each theme borrows the window surfaces and accent of a Gradient
/// theme (`shell`).
enum SignalTheme: String, CaseIterable, Identifiable {  // user-facing name: Multicolour theme
    case traffic, heat, terrain, spectrum, aurora, clear

    var id: String { rawValue }

    var title: String {
        switch self {
        case .traffic: return "Traffic"
        case .heat: return "Heat"
        case .terrain: return "Terrain"
        case .spectrum: return "Spectrum"
        case .aurora: return "Aurora"
        case .clear: return "Clear"
        }
    }

    /// One line for the Settings card.
    var blurb: String {
        switch self {
        case .traffic: return "Green to red"
        case .heat: return "Cold blue to hot red"
        case .terrain: return "Sea to summit"
        case .spectrum: return "Violet to red"
        case .aurora: return "Indigo to magenta"
        case .clear: return "Colour-blind safe"
        }
    }

    /// How Size mode reads in this theme, for the help centre and Settings.
    var sizeReading: String {
        switch self {
        case .traffic: return "green is small, yellow and orange are in between, red is big"
        case .heat: return "blue is small, green and yellow are in between, red is big"
        case .terrain: return "sea blue is small, green and sand are in between, brown and rock are big"
        case .spectrum: return "violet and blue are small, green and yellow are in between, red is big"
        case .aurora: return "indigo is small, teal and green are in between, magenta is big"
        case .clear: return "blue is small, pale tones are in between, orange is big"
        }
    }

    /// The Gradient theme whose canvas, surfaces and accent this theme uses.
    var shell: Theme {
        switch self {
        case .traffic: return .studio
        case .heat: return .sunset
        case .terrain: return .forest
        case .spectrum: return .neon
        case .aurora: return .iridescent
        case .clear: return .ocean
        }
    }

    var ramp: ThemeRamp {
        switch self {
        case .traffic: return Self.trafficRamp
        case .heat: return Self.heatRamp
        case .terrain: return Self.terrainRamp
        case .spectrum: return Self.spectrumRamp
        case .aurora: return Self.auroraRamp
        case .clear: return Self.clearRamp
        }
    }

    static let defaultsKey = "signalTheme"
    static let fallback: SignalTheme = .traffic

    static var current: SignalTheme { storage }
    static var storage: SignalTheme = initial()

    /// `defaults` and `environment` are injectable for tests; the app passes neither.
    static func initial(defaults: UserDefaults = .standard,
                        environment: [String: String] = ProcessInfo.processInfo.environment) -> SignalTheme {
        #if DEBUG
        // DISCOTECH_THEME also accepts a Multicolour theme name (traffic, heat, …).
        if let spec = environment["DISCOTECH_THEME"]?.lowercased(), let theme = SignalTheme(rawValue: spec) {
            return theme
        }
        #endif
        return defaults.string(forKey: defaultsKey).flatMap(SignalTheme.init(rawValue:)) ?? fallback
    }

    /// A flat fill with a faint lift: the hues carry the meaning, so no hue drift.
    private static let sheen: [(location: CGFloat, hueShift: Double, briMul: Double)] = [(0, 0, 0.97), (1, 0, 1.04)]

    /// Green, lime, yellow, amber, orange, red-orange, red, deep red.
    static let trafficRamp = ThemeRamp(
        id: "traffic",
        light: [0x65DB7C, 0xA7EC66, 0xF1ED41, 0xFFBE2E, 0xF99003, 0xEB6202, 0xC40F01, 0x93021E],
        dark: [0x41BA5D, 0x91D54E, 0xE7E232, 0xFAB707, 0xF99003, 0xF46601, 0xF64C39, 0xBA2936],
        sheen: sheen)

    /// Deep blue, blue, cyan, green, yellow, orange, red, crimson: a thermal map.
    static let heatRamp = ThemeRamp(
        id: "heat",
        light: [0x2E49B2, 0x0470A5, 0x0EC7DE, 0x3FC168, 0xF4E736, 0xFAA106, 0xF54F23, 0xAB0130],
        dark: [0x3552BC, 0x069CE4, 0x2FD4EC, 0x4FCE74, 0xF7EA3C, 0xFFA92B, 0xFB5429, 0xBD1F3D],
        sheen: sheen)

    /// Sea, shallows, grass, olive, sand, earth, rust, summit rock.
    static let terrainRamp = ThemeRamp(
        id: "terrain",
        light: [0x1A609E, 0x41B0BC, 0x55C483, 0xB3CA65, 0xF0D49B, 0xBF8350, 0x9E441D, 0x5E362F],
        dark: [0x2266A4, 0x41B0BC, 0x55C483, 0xB6CD68, 0xF3D79E, 0xCC8F5C, 0xA54A24, 0x734841],
        sheen: sheen)

    /// Violet, blue, cyan, green, yellow, orange, red-orange, red.
    static let spectrumRamp = ThemeRamp(
        id: "spectrum",
        light: [0x6F3BB2, 0x285CC2, 0x1EBDE3, 0x03C773, 0xE9EB41, 0xFFA914, 0xF3680F, 0xC50516],
        dark: [0x8451C9, 0x5991FC, 0x40D1F7, 0x30D882, 0xEDEE45, 0xFFB348, 0xFE7222, 0xF64A43],
        sheen: sheen)

    /// Indigo, blue, teal, green, yellow-green, pink, orchid, magenta.
    static let auroraRamp = ThemeRamp(
        id: "aurora",
        light: [0x483A9A, 0x1F68BC, 0x36BABA, 0x4ED589, 0xB5ED60, 0xFB9DC2, 0xD260BD, 0x8C23A1],
        dark: [0x5D52B4, 0x468DE5, 0x47C7C7, 0x5EE295, 0xBBF467, 0xFFA5C8, 0xE773D1, 0xC45FDB],
        sheen: sheen)

    /// Deep blue, blue, sky, pale blue, pale sand, amber, orange, rust: blue against
    /// orange, the pair that stays apart for every common kind of colour blindness.
    static let clearRamp = ThemeRamp(
        id: "clear",
        light: [0x144097, 0x2769B7, 0x52A9D9, 0xA9DEF0, 0xF9E596, 0xFFB348, 0xE1791B, 0xA14206],
        dark: [0x305EB7, 0x4C8EDF, 0x5FB5E7, 0xA5DBEC, 0xF9E596, 0xFFBC64, 0xEF852E, 0xD06D3D],
        sheen: sheen)
}
