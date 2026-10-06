import AppKit
import SwiftUI

/// Settings (⌘,): the palette style, the theme and what colour means ("Colour by"). All
/// apply live — no rescan.
struct SettingsView: View {
    @ObservedObject private var themes = ThemeStore.shared
    @ObservedObject private var colors = ColorModeStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xl) {
            paletteStyleRow
            section("Theme", note: themes.style == .gradient
                    ? "Gradient themes: pick the colour family."
                    : "Multicolour themes: pick the set of colours.") {
                // Three to a row: six themes in two rows fit the 640 pt window.
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Tokens.Space.m, alignment: .top), count: 3),
                          alignment: .leading, spacing: Tokens.Space.m) {
                    switch themes.style {
                    case .gradient:
                        ForEach(Theme.allCases) { theme in
                            ThemeCard(title: theme.title, blurb: theme.blurb, ramp: theme.ramp, canvas: theme,
                                      isSelected: themes.theme == theme) { themes.theme = theme }
                        }
                    case .signal:
                        ForEach(SignalTheme.allCases) { theme in
                            ThemeCard(title: theme.title, blurb: theme.blurb, ramp: theme.ramp, canvas: theme.shell,
                                      isSelected: themes.signal == theme) { themes.signal = theme }
                        }
                    }
                }
            }
            section("Colour by", note: "What a colour tells you, in the Ball, Layers, Floor and the sidebar.") {
                Picker("Colour by", selection: $colors.mode) {
                    ForEach(ColorMode.allCases) { mode in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(mode.title).font(.system(size: 13, weight: .medium))
                            Text(mode.explanation).font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 2)
                        .tag(mode)
                        .accessibilityLabel(Text(mode.title))
                        .accessibilityHint(Text(mode.explanation))
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
            TermsSettingsRow()
        }
        .padding(Tokens.Space.xl)
        .frame(width: 640)
        .fixedSize(horizontal: false, vertical: true)
        #if DEBUG
        .background(SettingsSnapshotHook())
        #endif
    }

    /// The setting on the left, its two choices on the right, so it reads as a question with
    /// two answers rather than a stray switch.
    private var paletteStyleRow: some View {
        HStack(alignment: .top, spacing: Tokens.Space.l) {
            VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
                Text("Palette style").font(.headline)
                Text("How colours are chosen. Pick one of the two sets, then a theme below.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 170, alignment: .leading)
            HStack(alignment: .top, spacing: Tokens.Space.m) {
                ForEach(PaletteStyle.allCases) { style in
                    PaletteStyleCard(style: style,
                                     ramp: style == .gradient ? themes.theme.ramp : themes.signal.ramp,
                                     isSelected: themes.style == style) { themes.style = style }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func section<Content: View>(_ title: String, note: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s) {
            VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
                Text(title).font(.headline)
                Text(note).font(.callout).foregroundStyle(.secondary)
            }
            content()
        }
    }
}

/// One of the two palette styles: its name, a one-line description and a strip of the
/// colours it uses. The whole card is one button; the chosen one carries the accent
/// outline and a check.
private struct PaletteStyleCard: View {
    let style: PaletteStyle
    let ramp: ThemeRamp
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    private var detail: String {
        style == .gradient ? "One colour, light to strong. Calm and easy on the eye."
                           : "Many colours in a meaningful order, like green to red."
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Tokens.Space.s) {
                HStack(spacing: 0) {
                    ForEach(0..<Palette.steps, id: \.self) { step in
                        Rectangle().fill(Color(nsColor: Palette.stepColor(step, dark: scheme == .dark, ramp: ramp)))
                    }
                }
                .frame(height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.xs) {
                    Text(style.title).font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 0)
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Tokens.Colors.accent : Tokens.Colors.hairlineStrong)
                        .accessibilityHidden(true)
                }
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(Tokens.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .fill(isSelected ? Tokens.Colors.selection : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .strokeBorder(isSelected ? Tokens.Colors.accent : Tokens.Colors.hairline, lineWidth: isSelected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(style.title) palette style"))
        .accessibilityHint(Text(detail))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// One theme: a mini Ball and its ramp in its colours, on its own surface, dark and light
/// side by side, with its name. The whole card is one button; the chosen one carries the
/// accent outline and a check.
private struct ThemeCard: View {
    let title: String
    let blurb: String
    let ramp: ThemeRamp
    /// The theme whose canvas colour the preview sits on.
    let canvas: Theme
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Tokens.Space.s) {
                HStack(spacing: 0) {
                    ThemePreview(ramp: ramp, canvas: canvas, dark: true)
                    ThemePreview(ramp: ramp, canvas: canvas, dark: false)
                }
                .frame(height: 104)
                .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
                    .strokeBorder(Tokens.Colors.hairlineStrong, lineWidth: 1))
                HStack(spacing: Tokens.Space.xs) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.system(size: 13, weight: .semibold))
                        Text(blurb).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Tokens.Colors.accent)
                            .accessibilityHidden(true)
                    }
                }
            }
            .padding(Tokens.Space.s)
            .background(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .fill(isSelected ? Tokens.Colors.selection : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .strokeBorder(isSelected ? Tokens.Colors.accent : Tokens.Colors.hairline, lineWidth: isSelected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(title) theme"))
        .accessibilityHint(Text(blurb))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A theme's colours for one appearance, on its canvas: a two-ring sunburst whose wedges
/// step up the ramp with their size (as "Colour by: Size" draws them), and the ramp's steps
/// as a bar underneath, smallest on the left.
private struct ThemePreview: View {
    let ramp: ThemeRamp
    let canvas: Theme
    let dark: Bool

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(nsColor: .hex(canvas.canvasHex(dark: dark)))))
            let barHeight: CGFloat = 6, barInset: CGFloat = 10
            let ringArea = CGSize(width: size.width, height: size.height - barHeight - 8)
            let center = CGPoint(x: ringArea.width / 2, y: ringArea.height / 2 + 2)
            let r = min(ringArea.width, ringArea.height) / 2 - 4
            // Inner ring: biggest to smallest, strongest to lightest; outer ring: each
            // wedge's two children, a step or two lighter.
            let shares: [Double] = [0.3, 0.22, 0.16, 0.13, 0.11, 0.08]
            let steps = [7, 6, 5, 4, 3, 2]
            var start = -90.0
            for (i, share) in shares.enumerated() {
                let sweep = share * 360
                segment(ctx, step: steps[i], center: center, inner: r * 0.34, outer: r * 0.64, start: start, sweep: sweep)
                segment(ctx, step: max(0, steps[i] - 1), center: center, inner: r * 0.68, outer: r,
                        start: start, sweep: sweep * 0.62)
                segment(ctx, step: max(0, steps[i] - 3), center: center, inner: r * 0.68, outer: r * 0.9,
                        start: start + sweep * 0.62, sweep: sweep * 0.38)
                start += sweep
            }
            let bar = CGRect(x: barInset, y: size.height - barHeight - 7, width: size.width - barInset * 2, height: barHeight)
            let cell = bar.width / CGFloat(Palette.steps)
            ctx.clip(to: Path(roundedRect: bar, cornerRadius: barHeight / 2))
            for step in 0..<Palette.steps {
                let rect = CGRect(x: bar.minX + CGFloat(step) * cell, y: bar.minY, width: cell + 0.5, height: bar.height)
                ctx.fill(Path(rect), with: .color(Color(nsColor: Palette.stepColor(step, dark: dark, ramp: ramp))))
            }
        }
        .accessibilityHidden(true)
    }

    /// One wedge, filled the way the Ball fills it: the theme's own sheen, radial from the
    /// centre.
    private func segment(_ ctx: GraphicsContext, step: Int, center: CGPoint, inner: CGFloat, outer: CGFloat,
                         start: Double, sweep: Double) {
        let gap = min(1.6, sweep * 0.2)
        let a0 = Angle.degrees(start + gap / 2), a1 = Angle.degrees(start + sweep - gap / 2)
        var path = Path()
        path.addArc(center: center, radius: outer, startAngle: a0, endAngle: a1, clockwise: false)
        path.addArc(center: center, radius: inner, startAngle: a1, endAngle: a0, clockwise: true)
        path.closeSubpath()
        let stops = Palette.gradientStops(Palette.Paint(step: step), dark: dark, alpha: 1, ramp: ramp).map {
            Gradient.Stop(color: Color(cgColor: $0.1), location: $0.0)
        }
        ctx.fill(path, with: .radialGradient(Gradient(stops: stops), center: center, startRadius: inner, endRadius: outer))
    }
}

/// The root of the main window: rebuilt when the theme or the "Colour by" mode changes,
/// so every themed surface, accent, canvas layout and cached sidebar tint is resolved again
/// (the scan and the focus live in `AppState` and are kept).
struct ThemedRoot<Content: View>: View {
    @ObservedObject private var themes = ThemeStore.shared
    @ObservedObject private var colors = ColorModeStore.shared
    @ViewBuilder let content: () -> Content

    var body: some View {
        content().id("\(themes.lookID)-\(colors.mode.rawValue)")
    }
}
