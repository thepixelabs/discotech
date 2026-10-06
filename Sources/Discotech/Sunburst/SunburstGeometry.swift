import CoreGraphics

/// Maps a ring depth to a fractional (0...1) inner/outer radius. Fractions are
/// resolution-independent so the layout never needs to be recomputed on resize
/// — only the draw/hit-test code multiplies by the view's current radius.
enum SunburstGeometry {
    /// (inner, outer) fraction for each ring depth, 0 = innermost ring around the center disc.
    static let ringFractions: [(inner: CGFloat, outer: CGFloat)] = {
        let n = SunburstConstants.maxRings
        let weights: [Double] = (0..<n).map { 1.0 - Double($0) * SunburstConstants.ringWeightDecay }
        let weightSum = weights.reduce(0, +)
        let remaining = 1.0 - Double(SunburstConstants.centerFraction)
        var boundaries: [CGFloat] = [SunburstConstants.centerFraction]
        var acc = Double(SunburstConstants.centerFraction)
        for w in weights {
            acc += remaining * w / weightSum
            boundaries.append(CGFloat(acc))
        }
        var result: [(CGFloat, CGFloat)] = []
        for i in 0..<n { result.append((boundaries[i], boundaries[i + 1])) }
        return result
    }()

    static func fracRange(depth: Int) -> (inner: CGFloat, outer: CGFloat) {
        let idx = max(0, min(depth, ringFractions.count - 1))
        return ringFractions[idx]
    }
}
