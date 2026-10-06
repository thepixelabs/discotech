import CoreGraphics
import QuartzCore

/// Tunable constants for the sunburst chart. Kept in one place so the look can
/// be adjusted without hunting through layout/draw code.
enum SunburstConstants {
    /// Number of rings drawn around the center disc (depth 0 = innermost).
    static let maxRings = 6
    /// Fraction of the available radius reserved for the center orb — generous,
    /// so it reads as a real mirror-ball centerpiece, not a hub.
    static let centerFraction: CGFloat = 0.21
    /// Segments whose angular span is smaller than this are merged into the
    /// parent's "Everything else" bucket instead of being drawn individually.
    static let minAngleRadians: Double = 0.6 * .pi / 180
    /// Each ring is slightly narrower than the one inside it.
    static let ringWeightDecay: Double = 0.07
    /// Focus-change / tree-mutation transition length.
    static let animationDuration: CFTimeInterval = 0.35
    /// How far (in points) a hovered segment is nudged outward.
    static let hoverLiftPoints: CGFloat = 5
    /// Real gap between adjacent rings (radial direction) — a modern segmented
    /// donut, not a flat pie.
    static let ringGapPoints: CGFloat = 3.5
    /// Real gap between adjacent segments in the same ring (angular direction).
    static let segmentGapPoints: CGFloat = 2.0
    /// Corner rounding applied to every segment's four corners.
    static let cornerRadiusPoints: CGFloat = 2.5
    /// Alpha multiplier applied to a segment that is neither the hovered wedge, one of
    /// its ancestors on the path back to center, nor one of its descendants — dimmed
    /// so the lineage path reads unmistakably against the rest of the chart. (Increase
    /// Contrast pushes this further at draw time — see `SunburstNSView.alphaMultiplier`.)
    static let hoverDimAlpha: CGFloat = 0.35
    /// Alpha multiplier for the hovered wedge's own descendants (outer rings within its
    /// angular span) — only lightly dimmed, so what's inside the hovered folder stays legible.
    static let hoverDescendantAlpha: CGFloat = 0.92
    /// Duration of the cross-fade between hover states (dim/ancestor-rim alpha), not the
    /// hovered wedge's own lift+glow, which stays instant. Skipped under Reduce Motion.
    static let hoverBlendDuration: CFTimeInterval = 0.12
    /// Outer padding so the outermost ring (and its glow) never touches the view edge.
    static let outerPadding: CGFloat = 18
}
