import SwiftUI

// MARK: - Backdrop

/// Full-bleed window backdrop: the flat `canvas` surface. Optionally a faint, static
/// violet wash centered on the screen's subject (the start screen's disk card) —
/// drawn once, never animated, and dropped under Reduce Transparency.
struct Backdrop: View {
    var wash: UnitPoint?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Tokens.Colors.canvas
                if let wash, !reduceTransparency {
                    let side = max(geo.size.width, geo.size.height)
                    RadialGradient(colors: [Tokens.Colors.accent.opacity(Tokens.Effect.heroWash), .clear],
                                   center: .center, startRadius: 0, endRadius: side * 0.42)
                        .frame(width: side, height: side)
                        .position(x: geo.size.width * wash.x, y: geo.size.height * wash.y)
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

// MARK: - Surfaces

extension View {
    /// Glass, for things that float over content only (path bar, hover card, notices).
    /// Liquid Glass on macOS 26+, a material with a hairline elsewhere, and a solid card
    /// with a strong edge under Reduce Transparency.
    func glassSurface<S: InsettableShape>(_ shape: S, interactive: Bool = false) -> some View {
        modifier(GlassSurface(shape: shape, interactive: interactive))
    }

    /// Solid tonal surface for content (cards, the Crate, the start disk card): `card`
    /// fill, a 1 pt inner hairline, no outer border; a soft two-layer shadow in light
    /// mode only.
    func cardSurface<S: InsettableShape>(_ shape: S, fill: Color = Tokens.Colors.card) -> some View {
        modifier(CardSurface(shape: shape, fill: fill))
    }

    /// The brand signature: pink left / acid right, under the one primary action on a
    /// screen. Increase Contrast swaps it for a solid accent stroke.
    func splitGlow<S: InsettableShape>(_ shape: S, hovering: Bool = false) -> some View {
        modifier(SplitGlowModifier(shape: shape, hovering: hovering))
    }
}

private struct GlassSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    let interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if SnapshotSupport.flatSurfaces || reduceTransparency {
            content
                .background(Tokens.Colors.card, in: shape)
                .overlay(shape.strokeBorder(Tokens.Colors.hairlineStrong, lineWidth: 1))
        } else if #available(macOS 26.0, *) {
            // The hairline keeps the edge readable where glass sits on the pale canvas.
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
                .overlay(shape.strokeBorder(Tokens.Colors.hairline, lineWidth: 1))
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Tokens.Colors.hairlineStrong, lineWidth: 1))
        }
    }
}

private struct CardSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    let fill: Color
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let near = Tokens.Effect.cardShadowNear, far = Tokens.Effect.cardShadowFar
        // Increase Contrast: a clearly visible edge (the dynamic colors also step up).
        let edge = contrast == .increased ? Tokens.Colors.hairlineStrong : Tokens.Colors.hairline
        let light = scheme == .light
        content
            .background {
                shape.fill(fill)
                    .shadow(color: light ? near.color : .clear, radius: near.radius, y: near.y)
                    .shadow(color: light ? far.color : .clear, radius: far.radius, y: far.y)
            }
            .overlay(shape.strokeBorder(edge, lineWidth: 1))
    }
}

private struct SplitGlowModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let hovering: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if contrast == .increased {
            content.overlay(shape.strokeBorder(Tokens.Colors.accent, lineWidth: 1))
        } else {
            let g = scheme == .dark ? Tokens.Effect.splitGlowDark : Tokens.Effect.splitGlowLight
            let gain = hovering ? Tokens.Effect.splitGlowHoverGain : 1
            content
                .background {
                    ZStack {
                        shape.fill(Tokens.Colors.brandPink.opacity(g.pink * gain))
                            .blur(radius: g.radius).offset(x: -g.x)
                        shape.fill(Tokens.Colors.brandAcid.opacity(g.acid * gain))
                            .blur(radius: g.radius).offset(x: g.x)
                    }
                    .allowsHitTesting(false)
                }
        }
    }
}

// MARK: - Buttons

/// The app's three button weights. Exactly one `.primary` per screen (it carries the
/// split glow); `.secondary` is a quiet filled capsule; `.text` is an accent-colored
/// text button for actions inside cards.
struct StudioButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, text }
    var kind: Kind = .secondary
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        StudioButton(configuration: configuration, kind: kind, large: large)
    }

    private struct StudioButton: View {
        let configuration: ButtonStyle.Configuration
        let kind: Kind
        let large: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            label
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { hovering = $0 }
                .contentShape(Capsule())
        }

        @ViewBuilder private var label: some View {
            let font: Font = large ? .system(size: 14, weight: .semibold) : .system(size: 12.5, weight: .medium)
            switch kind {
            case .primary:
                configuration.label
                    .font(font)
                    .foregroundStyle(.white)
                    .padding(.horizontal, large ? Tokens.Space.l + Tokens.Space.xxs : Tokens.Space.m)
                    .padding(.vertical, large ? Tokens.Space.s + Tokens.Space.xxs : Tokens.Space.xs + 1)
                    .background(configuration.isPressed ? Tokens.Colors.accentFillPressed : Tokens.Colors.accentFill,
                                in: Capsule())
                    .splitGlow(Capsule(), hovering: hovering && isEnabled)
            case .secondary:
                configuration.label
                    .font(font)
                    .foregroundStyle(Tokens.Colors.textPrimary)
                    .padding(.horizontal, large ? Tokens.Space.l : Tokens.Space.m)
                    .padding(.vertical, large ? Tokens.Space.s + Tokens.Space.xxs : Tokens.Space.xs + 1)
                    .background(configuration.isPressed || hovering ? Tokens.Colors.hoverFill : Tokens.Colors.track,
                                in: Capsule())
            case .text:
                configuration.label
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Tokens.Colors.accentText)
                    .opacity(configuration.isPressed ? 0.7 : 1)
                    .underline(hovering && isEnabled)
            }
        }
    }
}

extension ButtonStyle where Self == StudioButtonStyle {
    static var studioSecondary: StudioButtonStyle { StudioButtonStyle(kind: .secondary) }
    static var studioText: StudioButtonStyle { StudioButtonStyle(kind: .text) }
    static func studio(_ kind: StudioButtonStyle.Kind, large: Bool = false) -> StudioButtonStyle {
        StudioButtonStyle(kind: kind, large: large)
    }
}

// MARK: - Icon badge

/// A tinted rounded square with a white glyph — the "fun" in the sidebar, used by
/// Findings cards and the Crate.
struct IconBadge: View {
    let systemImage: String
    let hue: Tokens.Spectrum.Hue
    var size: CGFloat = Tokens.Size.badge

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.47, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Tokens.Spectrum.badge(hue), in: RoundedRectangle(cornerRadius: Tokens.Radius.badge, style: .continuous))
            .accessibilityHidden(true)
    }
}

// MARK: - Ring gauge

/// Used-vs-free ring. The used arc is painted with the six-swatch sweep, starting at
/// twelve o'clock. `fraction == nil` draws an indeterminate arc turning once every
/// `Tokens.Motion.indeterminateTurn` (a still full track under Reduce Motion).
struct RingGauge: View {
    let fraction: Double?
    var lineWidth: CGFloat = Tokens.Size.gaugeLine
    /// Neutral ring for volumes where "full" means nothing (read-only disk images).
    var muted = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().stroke(Tokens.Colors.track, lineWidth: lineWidth)
            if let fraction {
                let f = max(0.004, min(1, fraction))
                if muted {
                    Circle().trim(from: 0, to: f)
                        .stroke(Tokens.Colors.textTertiary.opacity(0.5), style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                } else {
                    arc(from: 0, to: f)
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.1), value: f)
                }
            } else if !reduceMotion {
                TimelineView(.animation) { ctx in
                    let turn = ctx.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: Tokens.Motion.indeterminateTurn) / Tokens.Motion.indeterminateTurn
                    arc(from: 0, to: 0.22)
                        .rotationEffect(.degrees(-90 + turn * 360))
                }
            }
        }
        .padding(lineWidth / 2)
        .accessibilityHidden(true)
    }

    private func arc(from: Double, to: Double) -> some View {
        Circle()
            .trim(from: from, to: to)
            .stroke(AngularGradient(colors: Tokens.Spectrum.stops(scheme), center: .center,
                                    startAngle: .zero, endAngle: .degrees(360)),
                    // Round caps overlap the start once the ring is nearly closed.
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: to - from > 0.96 ? .butt : .round))
    }
}

// MARK: - Drop target rim

/// Static drop-target rim: a solid 2 pt six-swatch stroke with a soft bloom. It only
/// appears while something is dragged over the target, so the change itself is the signal.
struct SpectrumRim<S: InsettableShape>: View {
    let shape: S
    var lineWidth: CGFloat = 2
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let gradient = Tokens.Spectrum.conic(scheme)
        ZStack {
            shape.strokeBorder(gradient, lineWidth: lineWidth * 3).blur(radius: 10).opacity(0.5)
            shape.strokeBorder(gradient, lineWidth: lineWidth)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Brand mark

/// Small spectrum ring + product name. The name comes from `Brand.name` only.
struct BrandMark: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: Tokens.Space.s) {
            Circle()
                .strokeBorder(Tokens.Spectrum.conic(scheme), lineWidth: 3.5)
                .frame(width: 16, height: 16)
            Text(Brand.name)
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(Tokens.Colors.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Bars & banners

/// A thin rounded bar filled to `fraction`.
struct FillBar: View {
    let fraction: Double
    let tint: Color
    var height: CGFloat = Tokens.Size.shareBar

    var body: some View {
        Capsule()
            .fill(Tokens.Colors.track)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(tint)
                    .scaleEffect(x: max(0.012, min(1, fraction)), y: 1, anchor: .leading)
            }
            .frame(height: height)
            .accessibilityHidden(true)
    }
}

/// Notice card used for scan errors and inline warnings (content, so a solid card).
struct Banner<Actions: View>: View {
    let systemImage: String
    let tint: Color
    let title: String
    let message: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .center, spacing: Tokens.Space.m) {
            Image(systemName: systemImage)
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
                Text(title).font(.headline).foregroundStyle(Tokens.Colors.textPrimary)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(Tokens.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Tokens.Space.m)
            HStack(spacing: Tokens.Space.s) { actions() }
        }
        .padding(.horizontal, Tokens.Space.l)
        .padding(.vertical, Tokens.Space.m)
        .cardSurface(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Measuring

extension View {
    /// Reports this view's size whenever it changes (macOS 14-compatible).
    func readSize(_ onChange: @escaping (CGSize) -> Void) -> some View {
        background(GeometryReader { geo in
            Color.clear
                .onAppear { onChange(geo.size) }
                .onChange(of: geo.size) { _, size in onChange(size) }
        })
    }
}

/// Glass and vibrancy can't be rendered by `NSView.cacheDisplay`, which the DEBUG
/// snapshot tool falls back to when the window server can't capture (screen locked).
/// In that mode surfaces render flat so layout can still be verified. Always false
/// in release builds.
enum SnapshotSupport {
    static let flatSurfaces: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.environment["DISCOTECH_SNAPSHOT_MODE"] == "view"
        #else
        return false
        #endif
    }()
}
