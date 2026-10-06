import AppKit
import Foundation
import Testing
@testable import Discotech

/// Everything that reads or writes the app's process-wide look (the current theme, palette
/// style and colour mode, the palette's fill cache, layout serials) lives under this one
/// serialized suite, so no test sees another's half-changed globals. Settings go to
/// isolated `UserDefaults` suites; the real ones are never touched.
@Suite(.serialized)
enum GlobalState {}

/// Runs `body` with throwaway stores, then puts every global back as it was.
@MainActor
private func withRestoredLook<T>(_ body: (ThemeStore, ColorModeStore, UserDefaults) throws -> T) async rethrows -> T {
    try await withIsolatedDefaults { defaults in
        let theme = Theme.selected, style = PaletteStyle.current, signal = SignalTheme.current, mode = ColorMode.current
        let themes = ThemeStore(defaults: defaults)
        let colour = ColorModeStore(defaults: defaults)
        defer {
            themes.theme = theme
            themes.style = style
            themes.signal = signal
            colour.mode = mode
            PaletteStyle.storage = style
            SignalTheme.storage = signal
        }
        return try body(themes, colour, defaults)
    }
}

extension GlobalState {
    @MainActor
    @Suite("Look: persistence and fallbacks")
    struct PersistenceTests {
        @Test("with nothing stored, every setting starts at its default")
        func defaults() async {
            await withIsolatedDefaults { d in
                #expect(Theme.initial(defaults: d, environment: [:]) == .studio)
                #expect(PaletteStyle.initial(defaults: d, environment: [:]) == .gradient)
                #expect(SignalTheme.initial(defaults: d, environment: [:]) == .traffic)
                #expect(ColorMode.initial(defaults: d, environment: [:]) == .size)
            }
        }

        @Test("a stored value this version does not know falls back to the default")
        func unknownStoredValues() async {
            await withIsolatedDefaults { d in
                d.set("holographic", forKey: Theme.defaultsKey)
                d.set("rainbow", forKey: PaletteStyle.defaultsKey)
                d.set("pastel", forKey: SignalTheme.defaultsKey)
                d.set("flavour", forKey: ColorMode.defaultsKey)
                #expect(Theme.initial(defaults: d, environment: [:]) == Theme.fallback)
                #expect(PaletteStyle.initial(defaults: d, environment: [:]) == .gradient)
                #expect(SignalTheme.initial(defaults: d, environment: [:]) == SignalTheme.fallback)
                #expect(ColorMode.initial(defaults: d, environment: [:]) == ColorMode.fallback)
            }
        }

        @Test("a stored value of the wrong type falls back to the default")
        func wrongTypeStoredValues() async {
            await withIsolatedDefaults { d in
                d.set(42, forKey: Theme.defaultsKey)
                d.set(true, forKey: ColorMode.defaultsKey)
                #expect(Theme.initial(defaults: d, environment: [:]) == .studio)
                #expect(ColorMode.initial(defaults: d, environment: [:]) == .size)
            }
        }

        @Test("every stored raw value of every setting is read back", arguments: Theme.allCases)
        func themeRawValuesRoundTrip(_ theme: Theme) async {
            await withIsolatedDefaults { d in
                d.set(theme.rawValue, forKey: Theme.defaultsKey)
                #expect(Theme.initial(defaults: d, environment: [:]) == theme)
            }
        }

        @Test("every Multicolour theme, palette style and colour mode is read back from its stored raw value")
        func otherRawValuesRoundTrip() async {
            await withIsolatedDefaults { d in
                for value in SignalTheme.allCases {
                    d.set(value.rawValue, forKey: SignalTheme.defaultsKey)
                    #expect(SignalTheme.initial(defaults: d, environment: [:]) == value)
                }
                for value in PaletteStyle.allCases {
                    d.set(value.rawValue, forKey: PaletteStyle.defaultsKey)
                    #expect(PaletteStyle.initial(defaults: d, environment: [:]) == value)
                }
                for value in ColorMode.allCases {
                    d.set(value.rawValue, forKey: ColorMode.defaultsKey)
                    #expect(ColorMode.initial(defaults: d, environment: [:]) == value)
                }
            }
        }

        @Test("the palette style's stored raw value for Multicolour stays 'signal' (existing installs persist it)")
        func signalRawValueIsStable() {
            #expect(PaletteStyle.signal.rawValue == "signal")
            #expect(PaletteStyle.signal.title == "Multicolour")
        }

        @Test("changing the theme, style, Multicolour theme and colour mode stores each one, and a restart reads them back")
        func storesRoundTrip() async {
            await withRestoredLook { themes, colour, d in
                themes.theme = .forest
                themes.style = .signal
                themes.signal = .aurora
                colour.mode = .kind
                #expect(d.string(forKey: Theme.defaultsKey) == "forest")
                #expect(d.string(forKey: PaletteStyle.defaultsKey) == "signal")
                #expect(d.string(forKey: SignalTheme.defaultsKey) == "aurora")
                #expect(d.string(forKey: ColorMode.defaultsKey) == "kind")
                #expect(Theme.initial(defaults: d, environment: [:]) == .forest)
                #expect(PaletteStyle.initial(defaults: d, environment: [:]) == .signal)
                #expect(SignalTheme.initial(defaults: d, environment: [:]) == .aurora)
                #expect(ColorMode.initial(defaults: d, environment: [:]) == .kind)
            }
        }

        @Test("a store changes what the whole app draws with, and tells the canvases")
        func storesUpdateGlobalsAndNotify() async {
            await withRestoredLook { themes, colour, _ in
                let posted = Locked(0)
                let token = NotificationCenter.default.addObserver(forName: .discotechThemeDidChange, object: nil, queue: nil) { _ in
                    posted.withValue { $0 += 1 }
                }
                defer { NotificationCenter.default.removeObserver(token) }
                let other: Theme = Theme.selected == .ocean ? .sunset : .ocean
                themes.theme = other
                #expect(Theme.selected == other)
                colour.mode = colour.mode == .folder ? .size : .folder
                #expect(ColorMode.current == colour.mode)
                #expect(posted.withValue { $0 } >= 2)
            }
        }

        @Test("setting a store to the value it already has posts nothing and writes nothing")
        func unchangedValueIsQuiet() async {
            await withRestoredLook { themes, _, d in
                let posted = Locked(0)
                let token = NotificationCenter.default.addObserver(forName: .discotechThemeDidChange, object: nil, queue: nil) { _ in
                    posted.withValue { $0 += 1 }
                }
                defer { NotificationCenter.default.removeObserver(token) }
                themes.theme = themes.theme
                #expect(posted.withValue { $0 } == 0)
                #expect(d.string(forKey: Theme.defaultsKey) == nil)
            }
        }

        @Test("a store never writes the app's real settings")
        func realSettingsUntouched() async {
            let before = [Theme.defaultsKey, PaletteStyle.defaultsKey, SignalTheme.defaultsKey, ColorMode.defaultsKey]
                .map { UserDefaults.standard.object(forKey: $0).map { "\($0)" } }
            await withRestoredLook { themes, colour, _ in
                themes.theme = themes.theme == .neon ? .studio : .neon
                themes.style = themes.style == .signal ? .gradient : .signal
                colour.mode = colour.mode == .kind ? .size : .kind
            }
            let after = [Theme.defaultsKey, PaletteStyle.defaultsKey, SignalTheme.defaultsKey, ColorMode.defaultsKey]
                .map { UserDefaults.standard.object(forKey: $0).map { "\($0)" } }
            #expect(before == after)
        }

        @Test("with Multicolour on, the palette and the window follow the chosen Multicolour theme")
        func styleSelectsRamp() async {
            await withRestoredLook { themes, _, _ in
                themes.style = .gradient
                themes.theme = .ocean
                #expect(Palette.ramp.id == "ocean")
                #expect(Theme.current == .ocean)
                themes.style = .signal
                themes.signal = .heat
                #expect(Palette.ramp.id == "heat")
                #expect(Theme.current == SignalTheme.heat.shell)
                #expect(Theme.selected == .ocean) // the Gradient choice is kept meanwhile
            }
        }

        @Test("lookID changes with every part of the look")
        func lookID() async {
            await withRestoredLook { themes, _, _ in
                let before = themes.lookID
                themes.style = themes.style == .signal ? .gradient : .signal
                #expect(themes.lookID != before)
            }
        }

        #if DEBUG
        @Test("a DEBUG environment override wins over the stored value")
        func debugEnvironmentOverrides() async {
            await withIsolatedDefaults { d in
                d.set("studio", forKey: Theme.defaultsKey)
                #expect(Theme.initial(defaults: d, environment: ["DISCOTECH_THEME": "OCEAN"]) == .ocean)
                #expect(SignalTheme.initial(defaults: d, environment: ["DISCOTECH_THEME": "heat"]) == .heat)
                #expect(PaletteStyle.initial(defaults: d, environment: ["DISCOTECH_PALETTE_STYLE": "signal"]) == .signal)
                #expect(PaletteStyle.initial(defaults: d, environment: ["DISCOTECH_THEME": "heat"]) == .signal)
                #expect(ColorMode.initial(defaults: d, environment: ["DISCOTECH_COLOR_BY": "folder"]) == .folder)
            }
        }

        @Test("an unknown DEBUG override is ignored in favour of the stored value")
        func debugEnvironmentUnknownValue() async {
            await withIsolatedDefaults { d in
                d.set("sunset", forKey: Theme.defaultsKey)
                #expect(Theme.initial(defaults: d, environment: ["DISCOTECH_THEME": "nonsense"]) == .sunset)
            }
        }
        #else
        @Test("release builds ignore the DEBUG environment overrides")
        func releaseIgnoresEnvironment() async {
            await withIsolatedDefaults { d in
                #expect(Theme.initial(defaults: d, environment: ["DISCOTECH_THEME": "ocean"]) == .studio)
                #expect(ColorMode.initial(defaults: d, environment: ["DISCOTECH_COLOR_BY": "folder"]) == .size)
                #expect(PaletteStyle.initial(defaults: d, environment: ["DISCOTECH_PALETTE_STYLE": "signal"]) == .gradient)
                #expect(!PaletteStyle.isOverridden)
            }
        }
        #endif
    }

    @MainActor
    @Suite("Look: colour mapping")
    struct MappingTests {
        private func ramp(_ name: String) -> ThemeRamp { allRamps.first { $0.name == name }!.ramp }

        @Test("each content kind has its own step, in both palette styles")
        func kindStepsAreABijection() async {
            await withRestoredLook { _, _, _ in
                for style in PaletteStyle.allCases {
                    PaletteStyle.storage = style
                    let steps = ContentKind.allCases.map(\.step)
                    #expect(Set(steps) == Set(0..<Palette.steps), "\(style)")
                }
            }
        }

        @Test("in Gradient the heaviest kinds take the strongest steps and Other the quietest; Multicolour spreads the big ones apart")
        func kindStepOrder() async {
            await withRestoredLook { _, _, _ in
                PaletteStyle.storage = .gradient
                #expect(ContentKind.media.step == 7 && ContentKind.other.step == 0)
                PaletteStyle.storage = .signal
                let big = [ContentKind.system, .apps, .media, .code].map(\.step).sorted()
                #expect(zip(big, big.dropFirst()).allSatisfy { $1 - $0 >= 2 }, "\(big)")
            }
        }

        @Test("Size mode paints by share of the folder in view and the folder itself with the top step")
        func sizeModePaints() async {
            await withRestoredLook { _, colour, _ in
                colour.mode = .size
                let big = fileNode("big", 900), small = fileNode("small", 1)
                let root = treeNode(root: "/r", [big, small])
                #expect(Palette.paint(for: big, in: root) == Palette.Paint(step: SizeRamp.step(share: 0.9)))
                #expect(Palette.paint(for: small, in: root)!.step < Palette.paint(for: big, in: root)!.step)
                #expect(Palette.paint(for: root, in: root) == Palette.Paint(step: Palette.steps - 1))
            }
        }

        @Test("synthetic nodes have no paint (they keep their own fixed tints)")
        func syntheticHasNoPaint() async {
            await withRestoredLook { _, colour, _ in
                for mode in ColorMode.allCases {
                    colour.mode = mode
                    let free = FileNode(name: "Free", isDirectory: false, size: 10, kind: .freeSpace)
                    let root = treeNode(root: "/r", [fileNode("x", 5)])
                    #expect(Palette.paint(for: free, in: root) == nil)
                }
            }
        }

        @Test("Kind mode paints by content kind, softening deeper and file nodes without changing the step")
        func kindModePaints() async {
            await withRestoredLook { _, colour, _ in
                colour.mode = .kind
                PaletteStyle.storage = .gradient
                let movie = fileNode("film.mp4", 500)
                let nested = dirNode("a", [dirNode("b", [movie])])
                let root = treeNode(root: "/r", [nested])
                let paint = Palette.paint(for: movie, in: root)!
                #expect(paint.step == ContentKind.media.step)
                #expect(paint.soften > 0 && paint.soften <= Palette.maxSoften)
                let direct = Palette.paint(for: nested, in: root)!
                #expect(direct.soften < paint.soften)
            }
        }

        @Test("Top-level folder mode gives every child of the root its own step, the biggest the strongest, and keeps it for everything inside")
        func folderModePaints() async {
            await withRestoredLook { _, colour, _ in
                colour.mode = .folder
                let inner = fileNode("deep.bin", 100)
                let root = treeNode(root: "/r", [dirNode("big", [inner, fileNode("pad", 800)]), dirNode("mid", [fileNode("m", 300)]), dirNode("small", [fileNode("s", 10)])])
                let big = find("big", in: root)!, mid = find("mid", in: root)!, small = find("small", in: root)!
                let steps = [big, mid, small].map { Palette.paint(for: $0, in: root)!.step }
                #expect(steps[0] == Palette.steps - 1)
                #expect(Set(steps).count == 3)
                #expect(Palette.paint(for: inner, in: root)!.step == steps[0])
                #expect(Palette.folderStep(for: root) == Palette.steps - 1)
            }
        }

        @Test("fill is opaque sRGB at the ramp's own step and softening only removes colour",
              arguments: ["studio", "traffic", "clear"])
        func fillMatchesRamp(_ name: String) async {
            await withRestoredLook { _, _, _ in
                let r = ramp(name)
                for dark in [false, true] {
                    for step in 0..<Palette.steps {
                        let plain = Palette.fill(Palette.Paint(step: step), dark: dark, ramp: r).usingColorSpace(.sRGB)!
                        #expect(plain == NSColor.hex(r.hex(step: step, dark: dark)).usingColorSpace(.sRGB)!)
                        #expect(plain.alphaComponent == 1)
                        let soft = Palette.fill(Palette.Paint(step: step, soften: 2), dark: dark, ramp: r).usingColorSpace(.sRGB)!
                        #expect(soft.saturationComponent <= plain.saturationComponent + 0.001)
                    }
                }
            }
        }

        @Test("gradient stops follow the sheen: as many as the ramp declares, alpha applied")
        func gradientStops() async {
            await withRestoredLook { _, _, _ in
                let r = ramp("iridescent")
                let stops = Palette.gradientStops(Palette.Paint(step: 3), dark: false, alpha: 0.5, ramp: r)
                #expect(stops.count == r.sheen.count)
                #expect(stops.map(\.0) == r.sheen.map(\.location))
                #expect(stops.allSatisfy { abs(NSColor(cgColor: $0.1)!.alphaComponent - 0.5) < 0.001 })
            }
        }
    }
}
