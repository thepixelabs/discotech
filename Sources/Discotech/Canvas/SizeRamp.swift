import Foundation

/// "Colour by: Size": which step of the theme ramp (`ThemeRamp`) an item takes, from its
/// share of the folder in view. The one size mapping every canvas, the sidebar dots, the
/// hover card and the legend use, so the same item reads as the same strength everywhere.
///
/// Shares span many orders of magnitude (a 300 GB folder and a 40 KB file can be siblings),
/// so the ramp is laid on a log scale: `decades` decades of share map onto the eight steps,
/// about 0.44 decade (×2.7) per step. A 90% folder takes the top step without pushing
/// everything else to the bottom: 10% still lands two steps down, 1% mid-ramp, and only
/// items under `10^-decades` (≈0.03%) of the folder take the lightest step. Deterministic,
/// so hovering or redrawing never changes a colour.
enum SizeRamp {
    /// Decades of share the ramp spans (share 1 → top step, `10^-decades` → step 0).
    static let decades = 3.5

    /// 0...1 position on the ramp for `share` (clamped to 0...1).
    static func position(share: Double) -> Double {
        guard share > 0 else { return 0 }
        return max(0, min(1, 1 + log10(min(1, share)) / decades))
    }

    /// Ramp step (0 ... `Palette.steps - 1`) for an item holding `share` of the folder.
    static func step(share: Double) -> Int {
        let n = Palette.steps
        return min(n - 1, max(0, Int(position(share: share) * Double(n))))
    }

    /// The share at which `step` begins (0 for step 0): items at or above it, and below the
    /// next step's, take this step. For the legend's example sizes.
    static func lowerShare(step: Int) -> Double {
        guard step > 0 else { return 0 }
        return pow(10, -decades * (1 - Double(step) / Double(Palette.steps)))
    }
}
