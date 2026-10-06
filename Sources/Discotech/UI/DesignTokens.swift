import AppKit
import SwiftUI

/// Product naming lives here and only here — the app is expected to be renamed.
/// UI copy never spells the name out; it references `Brand.name`.
enum Brand {
    static let name = "Discotech"
    /// What the user drags things into before clearing them out.
    static let crate = "Crate"
}

/// The UI's token layer ("Studio" direction). Every size, radius, color role, type style
/// and motion value used by the app shell lives here; views never hard-code them.
/// Colors resolve per appearance (light / dark, and the Increase Contrast variants of
/// both) through dynamic `NSColor`s, so dark mode and Increase Contrast need no view code.
enum Tokens {
    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let hero: CGFloat = 44
    }

    /// Concentric radii: an inner radius is the outer one minus the padding between them.
    enum Radius {
        /// Sidebar rows (8 pt inset inside the sidebar).
        static let row: CGFloat = 8
        /// Bordered controls; pills stay `Capsule`.
        static let control: CGFloat = 8
        /// Icon badges on Findings cards and in the sidebar.
        static let badge: CGFloat = 8
        /// Findings cards, the Crate, the docked hover strip.
        static let card: CGFloat = 14
        /// The floating hover card.
        static let hoverCard: CGFloat = 16
        /// Big content cards (the start screen's startup-disk card, the scan counters).
        static let hero: CGFloat = 22
    }

    enum Size {
        static let rowIcon: CGFloat = 22
        static let crumbIcon: CGFloat = 16
        /// Start screen: the startup disk's gauge, and the volume rows' icon.
        static let gauge: CGFloat = 176
        static let gaugeLine: CGFloat = 16
        static let volumeRowIcon: CGFloat = 30
        /// Findings / Crate icon badge.
        static let badge: CGFloat = 30
        static let shareBar: CGFloat = 4
        /// Sidebar share bars are a hair thinner than the hover card's.
        static let rowShareBar: CGFloat = 3
        static let contentMaxWidth: CGFloat = 820
        static let mirrorBall: CGFloat = 300
        static let crateListMaxHeight: CGFloat = 196
        static let crateListCompactMaxHeight: CGFloat = 96
        /// Sidebar column. The minimum is what gives way first when the window narrows.
        static let sidebarMin: CGFloat = 260
        static let sidebarIdeal: CGFloat = 300
        static let sidebarMax: CGFloat = 420
        /// Smallest window content size; every screen is verified to hold at this size.
        static let windowMin = CGSize(width: 900, height: 600)
        static let windowDefault = CGSize(width: 1280, height: 800)
        /// The floating hover card.
        static let hoverCardWidth: CGFloat = 250
        static let hoverCardIcon: CGFloat = 34
        /// The hover card docked as a strip along the canvas bottom (narrow canvases).
        static let hoverStripHeight: CGFloat = 60
        static let hoverStripIcon: CGFloat = 28
        /// Longest a preview ("ghost") crumb may get before its name truncates in the middle.
        static let ghostCrumbMaxWidth: CGFloat = 170
        /// Longest a real crumb may get before its name truncates in the middle.
        static let crumbMaxWidth: CGFloat = 220
        /// Leading marker on a sidebar row that contains the hovered item, and the
        /// selected row's accent bar.
        static let containsBar: CGFloat = 3
        /// Dashed Crate outline.
        static let dashedStroke: CGFloat = 1.5
    }

    /// Width bands, keyed off the detail (canvas) column width — not the window —
    /// because the sidebar is resizable.
    enum Breakpoint {
        /// Below this the canvas-mode picker drops its text labels.
        static let pickerLabels: CGFloat = 760
        /// Below this the partial-scan status shows its icon only.
        static let statusText: CGFloat = 560
        /// Sidebar height below which the Crate and Findings cards compact.
        static let compactSidebarHeight: CGFloat = 620
        /// Start screen: below this content width the hero card stacks and other
        /// volumes go one per row.
        static let startStack: CGFloat = 720
        static let startTwoUp: CGFloat = 640
    }

    /// Opacities for hover feedback, shared by the sidebar, path bar and hover card.
    enum Emphasis {
        /// Row fill (in the row's chart color) when the row itself is hovered.
        static let directHover: Double = 0.22
        /// Softer row fill when the hovered item is somewhere inside the row.
        static let containsHover: Double = 0.10
        /// Preview crumbs in the path bar: visible, clearly not yet "where you are".
        static let ghost: Double = 0.55
        /// Rows already in the Crate.
        static let inCrate: Double = 0.55
    }

    enum Typeface {
        /// Big figures (free space, live counters): SF Rounded, tabular digits.
        static func figure(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
            .system(size: size, weight: weight, design: .rounded).monospacedDigit()
        }
        static let hero = Font.system(size: 34, weight: .bold, design: .rounded)
        /// Uppercase, tracked label ("STARTUP DISK"). Pair with `eyebrowTracking`.
        static let eyebrow = Font.system(size: 10.5, weight: .semibold, design: .rounded)
        static let eyebrowTracking: CGFloat = 0.84  // +0.08 em
        /// The hover card's number.
        static let figureHero = figure(30)
        static let cardTitle = Font.system(size: 13, weight: .semibold)
        static let cardFigure = figure(19)
    }

    enum Colors {
        // MARK: Surfaces
        // Surfaces follow `Theme.current` (Studio values first; Neon from the Pixelabs
        // design system's --bg / --bg-deep / --bg-card; Iridescent the original aubergine
        // and lilac).
        /// Window and chart background.
        static let canvas = SwiftUI.Color(nsColor: NSColor(name: nil) { appearance in
            .hex(Theme.current.canvasHex(dark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua))
        })
        /// The surface every canvas (Ball, Layers, Floor) paints behind itself. Same as
        /// `canvas`, so toolbar, path bar and chart meet without a seam.
        static let chartSurface = canvas
        /// Sidebar column when Reduce Transparency is on (vibrancy otherwise).
        static let sidebar = themed(dynamicNS(light: (0xEFEDF4, 1), dark: (0x111318, 1)),
                                    neon: dynamicNS(light: (0xEFEDF4, 1), dark: (0x0A0B10, 1)),
                                    iridescent: dynamicNS(light: (0xF3EFF7, 1), dark: (0x170F1E, 1)),
                                    ocean: dynamicNS(light: (0xECF1F6, 1), dark: (0x0D1520, 1)),
                                    sunset: dynamicNS(light: (0xF6EEE9, 1), dark: (0x18100F, 1)),
                                    forest: dynamicNS(light: (0xEEF2EA, 1), dark: (0x0F1510, 1)))
        /// Findings cards, filled Crate, start-screen disk card, docked hover strip.
        static let card = themed(dynamicNS(light: (0xFAF9FC, 1), dark: (0x171920, 1)),
                                 neon: dynamicNS(light: (0xFAF9FC, 1), dark: (0x13151F, 1)),
                                 iridescent: dynamicNS(light: (0xFDFCFE, 1), dark: (0x1D1426, 1)),
                                 ocean: dynamicNS(light: (0xF8FAFC, 1), dark: (0x121B27, 1)),
                                 sunset: dynamicNS(light: (0xFDF9F6, 1), dark: (0x1F1514, 1)),
                                 forest: dynamicNS(light: (0xF9FBF7, 1), dark: (0x151C16, 1)))
        /// Row and crumb hover fill.
        static let hoverFill = themed(dynamicNS(light: (0xE7E4EE, 1), dark: (0x242634, 1)),
                                      neon: dynamicNS(light: (0xE9E3F0, 1), dark: (0x1F2130, 1)),
                                      iridescent: dynamicNS(light: (0xECE6F2, 1), dark: (0x2A1F35, 1)),
                                      ocean: dynamicNS(light: (0xE1E9F1, 1), dark: (0x1C2938, 1)),
                                      sunset: dynamicNS(light: (0xF0E4DD, 1), dark: (0x2E201E, 1)),
                                      forest: dynamicNS(light: (0xE3EADE, 1), dark: (0x223024, 1)))

        // MARK: Lines
        /// Card inner stroke, dividers. Increase Contrast: 20 %.
        /// Neon: the design system's violet `--rule`.
        static let hairline = themed(dynamicNS(light: (0x1A1B26, 0.07), dark: (0xFFFFFF, 0.07),
                                               lightHC: (0x1A1B26, 0.20), darkHC: (0xFFFFFF, 0.20)),
                                     neon: dynamicNS(light: (0xB020D0, 0.12), dark: (0xBE48E0, 0.16),
                                                     lightHC: (0x1A1B26, 0.20), darkHC: (0xFFFFFF, 0.20)))
        /// Glass edge, dashed Crate outline. Increase Contrast: 35 %.
        static let hairlineStrong = themed(dynamicNS(light: (0x1A1B26, 0.14), dark: (0xFFFFFF, 0.14),
                                                     lightHC: (0x1A1B26, 0.35), darkHC: (0xFFFFFF, 0.35)),
                                           neon: dynamicNS(light: (0xB020D0, 0.24), dark: (0xBE48E0, 0.30),
                                                           lightHC: (0x1A1B26, 0.35), darkHC: (0xFFFFFF, 0.35)))
        /// Empty part of share bars and gauges.
        static let track = SwiftUI.Color(nsColor: dynamicNS(light: (0x1A1B26, 0.08), dark: (0xFFFFFF, 0.09),
                                                            lightHC: (0x1A1B26, 0.22), darkHC: (0xFFFFFF, 0.24)))

        // MARK: Text (AA on every surface above; tertiary never sits on `hoverFill`)
        static let textPrimary = dynamic(light: 0x1A1B26, dark: 0xE8EAF2)
        static let textSecondary = dynamic(light: 0x4A4D63, dark: 0xA9AEBF, lightHC: 0x33364A, darkHC: 0xC4C8D6)
        static let textTertiary = dynamic(light: 0x676B82, dark: 0x8A8FA3, lightHC: 0x4A4D63, darkHC: 0xA9AEBF)

        // MARK: Roles
        /// Brand violet: tint, focus ring, selection base (Studio, Neon). Iridescent uses the
        /// system accent, as the original did; Ocean azure, Sunset rose, Forest pine.
        static let accent = themed(dynamicNS(light: (0xB020D0, 1), dark: (0xBE48E0, 1), lightHC: (0x8A1CAA, 1), darkHC: (0xD17BF2, 1)),
                                   iridescent: .controlAccentColor,
                                   ocean: dynamicNS(light: (0x0A6CC0, 1), dark: (0x3FA9F5, 1), lightHC: (0x0B5FAA, 1), darkHC: (0x7CC4FF, 1)),
                                   sunset: dynamicNS(light: (0xC2185B, 1), dark: (0xFF5C8A, 1), lightHC: (0xAD1457, 1), darkHC: (0xFF8FB0, 1)),
                                   forest: dynamicNS(light: (0x2E7D32, 1), dark: (0x5DBB63, 1), lightHC: (0x2B6E2F, 1), darkHC: (0x86D38A, 1)))
        /// Prominent button fill (white label ≥ 5.8:1 in every theme: Studio 7.43 / 5.91,
        /// Ocean 6.50 / 5.84, Sunset 6.97 / 6.13, Forest 6.22 / 5.80, light / dark).
        static let accentFill = themed(dynamicNS(light: (0x8A1CAA, 1), dark: (0x8E3BC2, 1)), iridescent: .controlAccentColor,
                                       ocean: dynamicNS(light: (0x0B5FAA, 1), dark: (0x1B67AE, 1)),
                                       sunset: dynamicNS(light: (0xAD1457, 1), dark: (0xB0305C, 1)),
                                       forest: dynamicNS(light: (0x2B6E2F, 1), dark: (0x2E7334, 1)))
        static let accentFillPressed = themed(dynamicNS(light: (0x741690, 1), dark: (0x7A31A8, 1)),
                                              iridescent: NSColor.controlAccentColor.withSystemEffect(.pressed),
                                              ocean: dynamicNS(light: (0x094F8E, 1), dark: (0x165892, 1)),
                                              sunset: dynamicNS(light: (0x8E1048, 1), dark: (0x972850, 1)),
                                              forest: dynamicNS(light: (0x235A26, 1), dark: (0x26612B, 1)))
        /// Text buttons and links ("Add to Crate", "Allow…"); AA on canvas and card.
        static let accentText = themed(dynamicNS(light: (0x8A1CAA, 1), dark: (0xD17BF2, 1)), iridescent: .linkColor,
                                       ocean: dynamicNS(light: (0x0B5FAA, 1), dark: (0x7CC4FF, 1)),
                                       sunset: dynamicNS(light: (0xAD1457, 1), dark: (0xFF8FB0, 1)),
                                       forest: dynamicNS(light: (0x2B6E2F, 1), dark: (0x86D38A, 1)))
        /// Selected row fill.
        static let selection = themed(dynamicNS(light: (0xB020D0, 0.14), dark: (0xBE48E0, 0.22),
                                                lightHC: (0xB020D0, 0.24), darkHC: (0xBE48E0, 0.34)),
                                      iridescent: NSColor.controlAccentColor.withAlphaComponent(0.22),
                                      ocean: dynamicNS(light: (0x0A6CC0, 0.14), dark: (0x3FA9F5, 0.22),
                                                       lightHC: (0x0A6CC0, 0.24), darkHC: (0x3FA9F5, 0.34)),
                                      sunset: dynamicNS(light: (0xC2185B, 0.12), dark: (0xFF5C8A, 0.20),
                                                        lightHC: (0xC2185B, 0.22), darkHC: (0xFF5C8A, 0.32)),
                                      forest: dynamicNS(light: (0x2E7D32, 0.14), dark: (0x5DBB63, 0.22),
                                                        lightHC: (0x2E7D32, 0.24), darkHC: (0x5DBB63, 0.34)))
        /// Free space OK, "reclaimable", "In Crate ✓".
        static let positive = dynamic(light: 0x0B7A30, dark: 0x5BE37D)
        /// ≥ 85 % full, partial scan, Purgeable.
        static let warning = dynamic(light: 0x9A5800, dark: 0xF5B544)
        /// ≥ 95 % full, errors, destructive.
        static let critical = dynamic(light: 0xC62828, dark: 0xFF6B6B)
        /// Informational glyphs (Full Disk Access, snapshots).
        static let info = accentText
        /// Signature split glow only — never text.
        static let brandPink = dynamic(light: 0xD4107A, dark: 0xFF1493)
        static let brandAcid = dynamic(light: 0x00C020, dark: 0x39FF14)

        /// Free-space figure goes amber, then red, as a disk fills (the figure only, never bars).
        static func freeSpace(usedFraction: Double) -> SwiftUI.Color {
            switch usedFraction {
            case ..<0.85: return textPrimary
            case ..<0.95: return warning
            default: return critical
            }
        }

        // MARK: Helpers

        /// A colour that follows `Theme.current` when resolved: `studio` unless the theme
        /// supplies its own. Each argument may itself be appearance-dynamic.
        static func themed(_ studio: NSColor, neon: NSColor? = nil, iridescent: NSColor? = nil,
                           ocean: NSColor? = nil, sunset: NSColor? = nil, forest: NSColor? = nil) -> SwiftUI.Color {
            SwiftUI.Color(nsColor: NSColor(name: nil) { appearance in
                let chosen: NSColor
                switch Theme.current {
                case .studio: chosen = studio
                case .neon: chosen = neon ?? studio
                case .iridescent: chosen = iridescent ?? studio
                case .ocean: chosen = ocean ?? studio
                case .sunset: chosen = sunset ?? studio
                case .forest: chosen = forest ?? studio
                }
                var resolved = chosen
                appearance.performAsCurrentDrawingAppearance {
                    resolved = chosen.usingColorSpace(.sRGB) ?? chosen
                }
                return resolved
            })
        }

        static func dynamic(light: UInt32, dark: UInt32, lightHC: UInt32? = nil, darkHC: UInt32? = nil) -> SwiftUI.Color {
            SwiftUI.Color(nsColor: dynamicNS(light: (light, 1), dark: (dark, 1),
                                             lightHC: (lightHC ?? light, 1), darkHC: (darkHC ?? dark, 1)))
        }

        static func dynamicNS(light: (UInt32, CGFloat), dark: (UInt32, CGFloat),
                              lightHC: (UInt32, CGFloat)? = nil, darkHC: (UInt32, CGFloat)? = nil) -> NSColor {
            NSColor(name: nil) { appearance in
                let match = appearance.bestMatch(from: [.darkAqua, .aqua,
                                                        .accessibilityHighContrastDarkAqua,
                                                        .accessibilityHighContrastAqua])
                let (hex, alpha): (UInt32, CGFloat)
                switch match {
                case .accessibilityHighContrastDarkAqua: (hex, alpha) = darkHC ?? dark
                case .accessibilityHighContrastAqua: (hex, alpha) = lightHC ?? light
                case .darkAqua: (hex, alpha) = dark
                default: (hex, alpha) = light
                }
                return NSColor.hex(hex, alpha: alpha)
            }
        }
    }

    /// The six data hues' **swatch** step (dots, bars, gauges, the mirror ball's sheen), in
    /// wheel order. For Studio: pink, violet, indigo, azure, teal, lime (the `DataHue`
    /// swatch column, visual-direction §4.3); every other theme fills the same six slots
    /// with its own family, in a smooth sweep, so the slot names are just stable keys
    /// (Findings badges). Node colors in canvases still come from `Palette` only.
    enum Spectrum {
        enum Hue: Int, CaseIterable { case pink, violet, indigo, azure, teal, lime }

        /// Per theme. Neon: magenta, the design system's #BE48E0 and #7B6EF6, mint, #39FF14
        /// and chartreuse. Iridescent: pastel rose → peach. Ocean: indigo → seafoam. Sunset:
        /// gold → dusk violet. Forest: spruce → bark.
        static var darkSwatch: [UInt32] {
            switch Theme.current {
            case .studio: return [0xFD68A6, 0xD578F0, 0x9996FE, 0x14AFFE, 0x13BCB8, 0x6CBD2E]
            case .neon: return [0xE040C8, 0xBE48E0, 0x7B6EF6, 0x22E0A8, 0x39FF14, 0xB8F23A]
            case .iridescent: return [0xFF94AF, 0xFF94FF, 0xA694FF, 0x94FFF6, 0x94FFB8, 0xFFC694]
            case .ocean: return [0x7B61FF, 0x6181FF, 0x61BDFF, 0x61EAFF, 0x61FFEA, 0x61FFBD]
            case .sunset: return [0xFFDA61, 0xFFA561, 0xFF7B61, 0xFF617B, 0xFF61BD, 0xCA61FF]
            case .forest: return [0x61FFD7, 0x61FFA3, 0x66FF61, 0xCAFF61, 0xFFEA61, 0xFFA561]
            }
        }
        /// Light swatches double as light-mode badge fills: white glyph ≥ 4.5:1.
        static var lightSwatch: [UInt32] {
            switch Theme.current {
            case .studio: return [0xCE337C, 0xA948C5, 0x6F61EA, 0x0082C0, 0x008D89, 0x498F00]
            case .neon: return [0xD11F9C, 0xB020D0, 0x5B4FE0, 0x14825D, 0x2E8010, 0x547F13]
            case .iridescent: return [0xCC3D61, 0xBA38BA, 0x6549F2, 0x267F78, 0x278245, 0xA16530]
            case .ocean: return [0x4724F2, 0x244EF2, 0x1C78BA, 0x157F8F, 0x137F71, 0x148254]
            case .sunset: return [0x8C7015, 0xB05B1A, 0xD13D1F, 0xDE2141, 0xD6208A, 0xAE24F2]
            case .forest: return [0x148266, 0x148543, 0x188514, 0x5A7D13, 0x827314, 0xB05B1A]
            }
        }
        /// Depth-0 fill (dark mode badges: white glyph ≥ 4.5:1).
        static var darkBase: [UInt32] {
            switch Theme.current {
            case .studio: return [0xA13564, 0x854299, 0x5A53B4, 0x066A9C, 0x057270, 0x3B7404]
            case .neon: return [0xBF2A92, 0x8A2BB0, 0x5A4FD0, 0x1B7D5C, 0x2A7A0A, 0x547A1B]
            case .iridescent: return [0xB84965, 0xAB44AB, 0x604DBF, 0x317A74, 0x327D4B, 0x94653B]
            case .ocean: return [0x432ABF, 0x2A48BF, 0x2673AB, 0x1E7987, 0x1B7A6E, 0x1B7D54]
            case .sunset: return [0x856C1D, 0xA65C24, 0xBF432A, 0xBF2A43, 0xBF2A81, 0x8E2ABF]
            case .forest: return [0x1B7D65, 0x1C7F45, 0x1F7F1C, 0x59781A, 0x7A6E1B, 0xA65C24]
            }
        }

        static func swatch(_ hue: Hue) -> SwiftUI.Color {
            Colors.dynamic(light: lightSwatch[hue.rawValue], dark: darkSwatch[hue.rawValue])
        }

        /// Badge fill: the deep tone in dark mode, the swatch in light; glyph is white on both.
        static func badge(_ hue: Hue) -> SwiftUI.Color {
            Colors.dynamic(light: lightSwatch[hue.rawValue], dark: darkBase[hue.rawValue])
        }

        static func stops(_ scheme: ColorScheme) -> [SwiftUI.Color] {
            let hexes = scheme == .dark ? darkSwatch : lightSwatch
            return (hexes + [hexes[0]]).map { SwiftUI.Color(nsColor: .hex($0)) }  // close the loop
        }

        /// Conic gradient starting at twelve o'clock (SwiftUI's 0° is three o'clock).
        static func conic(_ scheme: ColorScheme, rotation: Angle = .zero) -> AngularGradient {
            AngularGradient(colors: stops(scheme), center: .center,
                            startAngle: .degrees(-90) + rotation, endAngle: .degrees(270) + rotation)
        }

        /// sRGB components of the swatch, for per-pixel blending (the mirror ball).
        static func rgb(_ index: Int, dark: Bool) -> (Double, Double, Double) {
            let hex = (dark ? darkSwatch : lightSwatch)[((index % 6) + 6) % 6]
            return (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
        }
    }

    /// Soft effects. There is exactly one glow in the app: the split glow under the one
    /// primary action on a screen.
    enum Effect {
        struct SplitGlow { let x: CGFloat; let radius: CGFloat; let pink: Double; let acid: Double }
        static let splitGlowDark = SplitGlow(x: 4, radius: 6, pink: 0.30, acid: 0.22)
        static let splitGlowLight = SplitGlow(x: 3, radius: 6, pink: 0.22, acid: 0.16)
        static let splitGlowHoverGain = 1.4
        /// Light-mode card shadow (two layers); dark mode cards have none.
        static let cardShadowNear = (color: SwiftUI.Color(nsColor: .hex(0x141028, alpha: 0.05)), radius: CGFloat(1), y: CGFloat(1))
        static let cardShadowFar = (color: SwiftUI.Color(nsColor: .hex(0x141028, alpha: 0.07)), radius: CGFloat(16), y: CGFloat(12))
        /// Faint static violet wash behind the start screen's hero card (off under Reduce Transparency).
        static let heroWash: Double = 0.07
    }

    enum Motion {
        static let micro: Double = 0.15
        static let panel: Double = 0.28
        static let stateChange = Animation.timingCurve(0.4, 0.0, 0.2, 1, duration: panel)
        static let microChange = Animation.timingCurve(0.4, 0.0, 0.2, 1, duration: micro)
        /// Seconds per revolution of the indeterminate scan ring.
        static let indeterminateTurn: Double = 2.4
        /// How long a transient notice (e.g. a refused Crate drop) stays up.
        static let noticeSeconds: Double = 4
        /// Hover card / preview crumbs linger this long after the pointer leaves an item,
        /// so sweeping across the gaps between segments doesn't flicker.
        static let hoverGrace: Double = 0.15
        /// The pointer must rest on a chart item this long before the sidebar scrolls
        /// to reveal its row, so sweeping over the chart doesn't jerk the list around.
        static let revealDwell: Double = 0.35

        /// nil = instant swap when the user asked for reduced motion.
        static func state(_ reduce: Bool) -> Animation? { reduce ? nil : stateChange }
        static func hover(_ reduce: Bool) -> Animation? { reduce ? nil : microChange }
    }

    /// The sidebar lists at most this many children; the rest collapse into "Everything else".
    static let sidebarRowLimit = 200
}

extension NSColor {
    /// sRGB color from a 0xRRGGBB literal.
    static func hex(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

/// Per-node color, matching the canvases. Delegates to the chart's `Palette`, the
/// single source of truth for node color.
enum NodeTint {
    /// Colors for the first `limit` children of `focus` (the rows the sidebar shows).
    static func colors(for focus: FileNode, limit: Int) -> [ObjectIdentifier: Color] {
        var result: [ObjectIdentifier: Color] = [:]
        for child in focus.children.prefix(limit) {
            result[ObjectIdentifier(child)] = Palette.color(for: child, in: focus)
        }
        return result
    }
}
