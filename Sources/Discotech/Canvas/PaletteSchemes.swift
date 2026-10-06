import AppKit

/// One theme's data colours: an ordered ramp of `Palette.steps` fills, from the smallest /
/// quietest step to the biggest / strongest, written down per appearance, plus the theme's
/// fill sheen. `Palette` maps a node to a step (by size, kind or top-level folder, see
/// `ColorMode`) and resolves it here, so every canvas and the sidebar follow the theme.
///
/// The ramps were built in OKLCH (even lightness steps, chroma rising with the step, the hue
/// drifting within the theme's family) and checked numerically:
/// - WCAG luminance is monotonic along each ramp: light mode runs pale to deep, dark mode
///   dim to luminous, so in both "stands out more from the canvas" means "bigger".
/// - No step has a WCAG luminance in 0.158...0.238, the band where both white and
///   `Synthetic.ink` text fall under 4.5:1 (the crossover is at ~0.20), so a label on any
///   step gets white or ink text at 4.5:1 or better (the lowest is about 5:1). Light mode
///   jumps the band between steps 4 and 5, which is also where label ink flips from dark
///   to white.
struct ThemeRamp {
    /// Stable name (the cache key for resolved fills).
    let id: String
    /// sRGB fills, step 0 (smallest) first, for the light appearance: pale to deep.
    let light: [UInt32]
    /// The same for dark: dim, low-chroma to luminous, strong.
    let dark: [UInt32]
    /// The block / wedge fill: (location, hue shift in degrees, brightness ×) per stop. Kept
    /// within a few percent so labels stay legible across the whole fill.
    let sheen: [(location: CGFloat, hueShift: Double, briMul: Double)]

    func hex(step: Int, dark isDark: Bool) -> UInt32 {
        let list = isDark ? dark : light
        return list[max(0, min(list.count - 1, step))]
    }
}

extension Theme {
    var ramp: ThemeRamp {
        switch self {
        case .studio: return ThemeRamp.studio
        case .neon: return ThemeRamp.neon
        case .iridescent: return ThemeRamp.iridescent
        case .ocean: return ThemeRamp.ocean
        case .sunset: return ThemeRamp.sunset
        case .forest: return ThemeRamp.forest
        }
    }
}

extension ThemeRamp {
    /// Studio: blush pink to the brand's deep violet (light); dim indigo to a luminous pink
    /// lilac (dark).
    static let studio = ThemeRamp(
        id: "studio",
        light: [0xFADDE9, 0xEDC3DC, 0xDDA9D3, 0xC88FCC, 0xB076C7, 0x7D46A8, 0x602D9E, 0x450A93],
        dark: [0x312D50, 0x463A6D, 0x5E458A, 0x7850A0, 0xB278D1, 0xD48AE4, 0xF4A0F2, 0xFEC4F0],
        sheen: [(0, 0, 0.97), (1, 0, 1.05)])

    /// Neon: pale lavender to intense violet (light); dim violet up to a glowing orchid, and
    /// the very biggest step in the design system's acid green (dark).
    static let neon = ThemeRamp(
        id: "neon",
        light: [0xEDE0FE, 0xDEC4FA, 0xCFA9F3, 0xC08BEA, 0xB36CDF, 0x8A2FB9, 0x7102A8, 0x530086],
        dark: [0x382856, 0x4E3176, 0x673A97, 0x7F43B2, 0xB66CE9, 0xD482FF, 0xE4A6FF, 0x66FF58],
        sheen: [(0, 0, 0.95), (1, 0, 1.06)])

    /// Iridescent: a soap-film drift, peach through rose and orchid to deep periwinkle
    /// (light), and back from dim periwinkle to luminous peach (dark).
    static let iridescent = ThemeRamp(
        id: "iridescent",
        light: [0xFEE0C4, 0xF6C5B0, 0xE9A9A6, 0xD58FA2, 0xBC77A1, 0x824D8B, 0x583E89, 0x26317E],
        dark: [0x273056, 0x453A6C, 0x68447B, 0x874E81, 0xC4789F, 0xE58DA1, 0xFEA8A4, 0xFECCBB],
        sheen: [(0, -7, 0.96), (0.5, 3, 1.05), (1, 9, 0.99)])

    /// Ocean: pale aqua to deep cobalt (light); deep-water navy to bright cyan (dark).
    static let ocean = ThemeRamp(
        id: "ocean",
        light: [0xC1F1EF, 0x98E0E1, 0x6CCED7, 0x3CB8D1, 0x0C9ECD, 0x036BA2, 0x015095, 0x092D92],
        dark: [0x223156, 0x214474, 0x105890, 0x056E9C, 0x09A3CB, 0x0ABFDA, 0x32DBE8, 0x55F4F4],
        sheen: [(0, 4, 0.96), (1, -6, 1.05)])

    /// Sunset: pale peach to strong crimson (light); dim plum-red to glowing gold (dark).
    static let sunset = ThemeRamp(
        id: "sunset",
        light: [0xFCE3BA, 0xF8C790, 0xF6A86B, 0xED8851, 0xE06844, 0xB22C27, 0x980225, 0x730027],
        dark: [0x531E2B, 0x712631, 0x902F31, 0xA83F2C, 0xDC7143, 0xF28E45, 0xFEAF55, 0xFFD284],
        sheen: [(0, -4, 0.96), (1, 6, 1.05)])

    /// Forest: pale sage to deep pine (light); dim spruce to bright leaf (dark).
    static let forest = ThemeRamp(
        id: "forest",
        light: [0xE0ECC8, 0xC5DAA7, 0xA8C989, 0x87B673, 0x64A362, 0x25773E, 0x016034, 0x01482D],
        dark: [0x183B2B, 0x204E35, 0x2A633F, 0x387643, 0x67A661, 0x83BE67, 0xA3D570, 0xC3EA77],
        sheen: [(0, 0, 0.98), (1, 4, 1.03)])
}
