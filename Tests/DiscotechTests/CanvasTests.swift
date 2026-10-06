import AppKit
import Foundation
import Testing
@testable import Discotech

// MARK: - SizeRamp

@Suite("SizeRamp")
struct SizeRampTests {
    private let shares: [Double] = [0, 1e-9, 1e-6, 1e-5, 3e-4, 1e-3, 3e-3, 0.01, 0.03, 0.1, 0.25, 0.5, 0.9, 1]

    @Test("position stays within 0...1 for any share, including nonsense")
    func positionIsBounded() {
        for share in shares + [-1, -0.0, 2, 1e9, .infinity] {
            let p = SizeRamp.position(share: share)
            #expect((0...1).contains(p), "share \(share) -> \(p)")
        }
    }

    @Test("a bigger share never maps to a lower position or step")
    func monotonic() {
        let positions = shares.map { SizeRamp.position(share: $0) }
        let steps = shares.map { SizeRamp.step(share: $0) }
        #expect(positions == positions.sorted())
        #expect(steps == steps.sorted())
    }

    @Test("the whole folder takes the top step and anything at or under 10^-3.5 the lowest")
    func endpoints() {
        #expect(SizeRamp.step(share: 1) == Palette.steps - 1)
        #expect(SizeRamp.step(share: 0) == 0)
        #expect(SizeRamp.step(share: pow(10, -SizeRamp.decades)) == 0)
        #expect(SizeRamp.step(share: 1e-12) == 0)
        #expect(SizeRamp.position(share: 1) == 1)
    }

    @Test("the documented examples hold: 90% is the top step, 10% two steps down, 1% mid-ramp")
    func documentedExamples() {
        #expect(SizeRamp.step(share: 0.9) == 7)
        #expect(SizeRamp.step(share: 0.1) == 5)
        #expect(SizeRamp.step(share: 0.01) == 3)
    }

    @Test("every step is a valid ramp index")
    func stepsInRange() {
        for share in shares { #expect((0..<Palette.steps).contains(SizeRamp.step(share: share))) }
    }

    @Test("lowerShare is where each step begins: just above it is that step, just below is the one before",
          arguments: 1..<8)
    func stepBoundaries(_ step: Int) {
        let boundary = SizeRamp.lowerShare(step: step)
        #expect(SizeRamp.step(share: boundary * 1.0001) == step)
        #expect(SizeRamp.step(share: boundary * 0.9999) == step - 1)
    }

    @Test("lowerShare of the first step is zero and the boundaries rise with the step")
    func lowerShareOrder() {
        #expect(SizeRamp.lowerShare(step: 0) == 0)
        let all = (0..<Palette.steps).map { SizeRamp.lowerShare(step: $0) }
        #expect(all == all.sorted())
        #expect(Set(all).count == all.count)
    }

    @Test("the same share always gives the same step")
    func deterministic() {
        #expect((0..<100).map { _ in SizeRamp.step(share: 0.037) }.allSatisfy { $0 == SizeRamp.step(share: 0.037) })
    }
}

// MARK: - Palette helpers

@Suite("Palette helpers")
struct PaletteHelperTests {
    @Test("spreadStep gives a lone category the strongest step")
    func singleCategory() {
        #expect(Palette.spreadStep(index: 0, count: 1) == 7)
        #expect(Palette.spreadStep(index: 0, count: 0) == 7)
    }

    @Test("spreadStep spreads two and three categories wide apart, strongest first")
    func fewCategories() {
        #expect((0..<2).map { Palette.spreadStep(index: $0, count: 2) } == [7, 1])
        #expect((0..<3).map { Palette.spreadStep(index: $0, count: 3) } == [7, 4, 1])
    }

    @Test("spreadStep gives seven categories seven distinct steps, 7 down to 1")
    func sevenCategories() {
        #expect((0..<7).map { Palette.spreadStep(index: $0, count: 7) } == [7, 6, 5, 4, 3, 2, 1])
    }

    @Test("spreadStep cycles through the ramp for categories past the seventh and stays on the ramp")
    func manyCategories() {
        let steps = (0..<50).map { Palette.spreadStep(index: $0, count: 50) }
        #expect(steps.allSatisfy { (0..<Palette.steps).contains($0) })
        #expect(Array(steps[7..<14]) == [6, 4, 2, 5, 3, 1, 7])
        #expect(steps[14] == steps[7])
    }

    @Test("desaturating by 0 changes nothing and by 1 gives a grey of the same luminance")
    func desaturateEnds() throws {
        let colour = NSColor.hex(0xB076C7)
        let same = Palette.desaturate(colour, by: 0).usingColorSpace(.sRGB)!
        #expect(abs(same.redComponent - colour.usingColorSpace(.sRGB)!.redComponent) < 0.002)
        let grey = Palette.desaturate(colour, by: 1).usingColorSpace(.sRGB)!
        #expect(abs(grey.redComponent - grey.greenComponent) < 0.002 && abs(grey.greenComponent - grey.blueComponent) < 0.002)
        #expect(abs(Palette.relativeLuminance(grey) - Palette.relativeLuminance(colour)) < 0.005)
    }

    @Test("softening keeps luminance, so a label's ink never changes with depth",
          arguments: [0.13, 0.26, 0.39, 0.52])
    func softenKeepsLuminance(_ fraction: Double) {
        for ramp in allRamps {
            for step in 0..<Palette.steps {
                let base = Palette.stepColor(step, dark: false, ramp: ramp.ramp)
                let soft = Palette.desaturate(base, by: fraction)
                #expect(abs(Palette.relativeLuminance(soft) - Palette.relativeLuminance(base)) < 0.01, "\(ramp.name) \(step)")
                #expect(Palette.inkColor(onLuminance: Palette.relativeLuminance(soft)) == Palette.inkColor(onLuminance: Palette.relativeLuminance(base)))
            }
        }
    }

    @Test("relativeLuminance is 0 for black, 1 for white and follows the WCAG weights for pure channels")
    func luminanceReferenceValues() {
        #expect(Palette.relativeLuminance(.black) == 0)
        #expect(abs(Palette.relativeLuminance(.white) - 1) < 1e-9)
        #expect(abs(Palette.relativeLuminance(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)) - 0.2126) < 1e-6)
        #expect(abs(Palette.relativeLuminance(NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)) - 0.7152) < 1e-6)
        #expect(abs(Palette.relativeLuminance(NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)) - 0.0722) < 1e-6)
    }

    @Test("label ink is white on dark fills and the dark ink on light fills")
    func inkChoice() {
        #expect(Palette.inkColor(onLuminance: 0.02) == NSColor.white)
        #expect(Palette.inkColor(onLuminance: 0.9) == Palette.Synthetic.ink)
    }

    @Test("normalizeDegrees wraps into 0..<360")
    func degrees() {
        #expect(Palette.normalizeDegrees(-10) == 350)
        #expect(Palette.normalizeDegrees(370) == 10)
        #expect(Palette.normalizeDegrees(360) == 0)
    }
}

// MARK: - Theme ramps

struct NamedRamp {
    let name: String
    let ramp: ThemeRamp
    let isGradient: Bool
}

let allRamps: [NamedRamp] =
    Theme.allCases.map { NamedRamp(name: $0.rawValue, ramp: $0.ramp, isGradient: true) }
    + SignalTheme.allCases.map { NamedRamp(name: $0.rawValue, ramp: $0.ramp, isGradient: false) }

struct RampCase: Sendable, CustomTestStringConvertible {
    let name: String
    let dark: Bool
    var testDescription: String { "\(name) \(dark ? "dark" : "light")" }
    var ramp: NamedRamp { allRamps.first { $0.name == name }! }
}

private let rampCases: [RampCase] = allRamps.flatMap { [RampCase(name: $0.name, dark: false), RampCase(name: $0.name, dark: true)] }

/// WCAG contrast ratio of two relative luminances.
private func contrast(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }

/// OKLab coordinates of an sRGB hex colour; Euclidean distance there approximates how
/// different two colours look.
private func oklab(_ hex: UInt32) -> (Double, Double, Double) {
    func lin(_ v: UInt32) -> Double {
        let x = Double(v) / 255
        return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
    }
    let r = lin((hex >> 16) & 255), g = lin((hex >> 8) & 255), b = lin(hex & 255)
    let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
    let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
    let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
    return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
}

private func distance(_ a: UInt32, _ b: UInt32) -> Double {
    let p = oklab(a), q = oklab(b)
    return ((p.0 - q.0) * (p.0 - q.0) + (p.1 - q.1) * (p.1 - q.1) + (p.2 - q.2) * (p.2 - q.2)).squareRoot()
}

@Suite("Theme ramps")
struct ThemeRampTests {
    private func hexes(_ c: RampCase) -> [UInt32] { c.dark ? c.ramp.ramp.dark : c.ramp.ramp.light }
    private func luminances(_ c: RampCase) -> [Double] {
        (0..<Palette.steps).map { Palette.relativeLuminance(Palette.stepColor($0, dark: c.dark, ramp: c.ramp.ramp)) }
    }

    @Test("every ramp has one fill per step in both appearances")
    func stepCount() {
        for r in allRamps {
            #expect(r.ramp.light.count == Palette.steps, "\(r.name) light")
            #expect(r.ramp.dark.count == Palette.steps, "\(r.name) dark")
        }
    }

    @Test("hex(step:) clamps a step outside the ramp to its ends")
    func clamping() {
        let r = Theme.studio.ramp
        #expect(r.hex(step: -5, dark: false) == r.light[0])
        #expect(r.hex(step: 99, dark: true) == r.dark[Palette.steps - 1])
    }

    @Test("ramp ids are unique and match the theme's name (the fill cache is keyed by them)")
    func ids() {
        #expect(Set(allRamps.map { $0.ramp.id }).count == allRamps.count)
        #expect(allRamps.allSatisfy { $0.ramp.id == $0.name })
    }

    @Test("label ink on every step reaches 4.5:1 and is the better of white and the dark ink", arguments: rampCases)
    func labelContrast(_ c: RampCase) {
        let inkLuminance = Palette.relativeLuminance(Palette.Synthetic.ink)
        for (step, fill) in luminances(c).enumerated() {
            let best = max(contrast(fill, 1), contrast(fill, inkLuminance))
            #expect(best >= 4.5, "\(c.testDescription) step \(step): \(best)")
            let chosen = Palette.inkColor(onLuminance: fill)
            let chosenContrast = contrast(fill, Palette.relativeLuminance(chosen))
            #expect(abs(chosenContrast - best) < 1e-9, "\(c.testDescription) step \(step) picked the worse ink")
        }
    }

    @Test("no two steps of a ramp look alike", arguments: rampCases)
    func stepsAreDistinguishable(_ c: RampCase) {
        let list = hexes(c)
        for i in list.indices {
            for j in list.indices where j > i {
                #expect(distance(list[i], list[j]) >= 0.05, "\(c.testDescription): steps \(i) and \(j)")
            }
        }
    }

    @Test("a Gradient ramp gets steadily darker in light mode and steadily brighter in dark mode",
          arguments: rampCases.filter { $0.ramp.isGradient })
    func gradientIsMonotonic(_ c: RampCase) {
        let l = luminances(c)
        let pairs = Array(zip(l, l.dropFirst()))
        if c.dark {
            #expect(pairs.allSatisfy { $0 < $1 }, "\(c.testDescription): \(l)")
        } else {
            #expect(pairs.allSatisfy { $0 > $1 }, "\(c.testDescription): \(l)")
        }
    }

    @Test("a Multicolour theme borrows a different Gradient theme's window for each of the six")
    func shellsAreDistinct() {
        #expect(Set(SignalTheme.allCases.map(\.shell)).count == SignalTheme.allCases.count)
    }

    @Test("every theme has a title, a blurb and a canvas colour that is darker in dark mode", arguments: Theme.allCases)
    func themeMetadata(_ theme: Theme) {
        #expect(!theme.title.isEmpty && !theme.blurb.isEmpty)
        let light = Palette.relativeLuminance(NSColor.hex(theme.canvasHex(dark: false)))
        let dark = Palette.relativeLuminance(NSColor.hex(theme.canvasHex(dark: true)))
        #expect(dark < light)
    }

    @Test("every Multicolour theme explains how Size reads", arguments: SignalTheme.allCases)
    func signalMetadata(_ theme: SignalTheme) {
        #expect(!theme.title.isEmpty && !theme.blurb.isEmpty && !theme.sizeReading.isEmpty)
    }
}

// MARK: - ContentKind

@Suite("ContentKind")
struct ContentKindTests {
    private func kind(_ name: String) -> ContentKind? { fileNode(name, 10).contentKind }

    @Test("a file is classified by its extension, in any case",
          arguments: [("photo.jpg", ContentKind.media), ("PHOTO.JPG", .media), ("song.flac", .media), ("clip.mov", .media),
                      ("report.pdf", .documents), ("notes.md", .documents), ("sheet.xlsx", .documents),
                      ("main.swift", .code), ("app.js", .code), ("weights.safetensors", .code), ("data.json", .code),
                      ("a.zip", .archives), ("a.dmg", .archives), ("a.7z", .archives),
                      ("debug.log", .caches), ("x.tmp", .caches),
                      ("lib.dylib", .system), ("x.plist", .system),
                      ("Thing.app", .apps), ("README", .other), (".gitignore", .other), ("name.", .other),
                      ("x.unknownext", .other), ("x.extensionwaytoolongtobe", .other),
                      ("archive.tar.gz", .archives)])
    func fileExtensions(_ name: String, _ expected: ContentKind) {
        #expect(kind(name) == expected)
    }

    @Test("a folder named for what it is takes that kind whatever it contains",
          arguments: [("node_modules", ContentKind.code), (".git", .code), ("build", .code), ("DerivedData", .code),
                      ("Caches", .caches), ("Logs", .caches), (".cache", .caches),
                      ("Library", .system), ("System", .system), ("usr", .system), ("Applications", .apps)])
    func wellKnownFolders(_ name: String, _ expected: ContentKind) {
        let folder = dirNode(name, [fileNode("movie.mp4", 5_000)])
        folder.finalize()
        #expect(folder.contentKind == expected)
    }

    @Test("a package folder is classified by its extension")
    func packages() {
        #expect(dirNode("Tool.app", package: true, [fileNode("x.mp4", 9)]).contentKind == .apps)
        #expect(dirNode("Pics.photoslibrary", package: true, [fileNode("x.swift", 9)]).contentKind == .media)
    }

    @Test("any other folder takes the kind holding most of its bytes")
    func dominantKind() {
        let folder = treeNode(root: "/r", [dirNode("Holiday", [fileNode("a.jpg", 600), fileNode("b.mov", 300), fileNode("notes.txt", 700)])])
        #expect(find("Holiday", in: folder)?.contentKind == .media)
    }

    @Test("a folder of folders takes the kind of what is inside them, through every level")
    func nestedDominantKind() {
        let root = treeNode(root: "/r", [dirNode("outer", [dirNode("inner", [fileNode("a.swift", 100)]), fileNode("b.pdf", 40)])])
        #expect(find("outer", in: root)?.contentKind == .code)
    }

    @Test("an empty folder, and one holding only empty files, is Other")
    func emptyFolder() {
        #expect(dirNode("empty").contentKind == .other)
        #expect(treeNode(root: "/r", [dirNode("d", [fileNode("a.jpg", 0)])]).children[0].contentKind == .other)
    }

    @Test("synthetic nodes have no kind")
    func syntheticHasNoKind() {
        for k in [FileNode.Kind.freeSpace, .purgeable, .hidden, .snapshot] {
            #expect(FileNode(name: "x", isDirectory: false, kind: k).contentKind == nil)
        }
    }

    @Test("the kind is remembered on the node once worked out")
    func memoised() {
        let node = fileNode("a.jpg", 10)
        #expect(node.contentKindCache == 0)
        _ = node.contentKind
        #expect(node.contentKindCache == ContentKind.media.rawValue)
    }

    @Test("every kind has titles", arguments: ContentKind.allCases)
    func titles(_ k: ContentKind) {
        #expect(!k.title.isEmpty && !k.shortTitle.isEmpty)
    }
}
