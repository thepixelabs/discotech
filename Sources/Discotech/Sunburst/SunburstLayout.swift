import Foundation
import CoreGraphics

/// Stable identity for a drawn segment, used to match segments across layouts
/// (for the zoom transition) and to look up the currently-hovered segment.
enum SunburstSegmentKey: Hashable {
    case node(ObjectIdentifier)
    /// The merged "Everything else" bucket for a given parent, one per ring depth.
    case other(ObjectIdentifier, Int)
}

/// One drawn wedge of the sunburst. Angles are radians, 0 = twelve o'clock,
/// increasing clockwise. `innerFrac`/`outerFrac` are fractions (0...1) of the
/// view's current max radius — resolution independent, so a resize never
/// requires rebuilding the layout.
///
/// Deliberately does *not* bake a final display color: `paint` (a theme ramp step, from
/// `Palette`) is appearance-independent, but the fill depends on light-vs-dark, which can
/// change without a relayout — the draw code resolves it each frame via `Palette.fill`.
struct SunburstSegment {
    let node: FileNode?
    let parentKey: ObjectIdentifier
    /// The folder this segment (or, for `isOther`, this bucket's siblings) sits directly
    /// under. Distinct from `parentKey` (an opaque identity used only for keying) so the
    /// hover lineage highlight can walk `parentNode.parent` chains back to `focus` without
    /// a node→node reverse lookup.
    let parentNode: FileNode
    let depth: Int
    let startAngle: Double
    let endAngle: Double
    let innerFrac: CGFloat
    let outerFrac: CGFloat
    /// From `Palette.paint(for:in:)`; `nil` for "Everything else" and synthetic nodes.
    let paint: Palette.Paint?
    let isFile: Bool
    let isOther: Bool
    let otherCount: Int
    let displaySize: Int64
    let displayName: String

    var key: SunburstSegmentKey {
        if let node { return .node(ObjectIdentifier(node)) }
        return .other(parentKey, depth)
    }
}

/// A fully-built sunburst for one focus node. Immutable and cheap to keep two
/// of around (old/new) while animating a focus change.
final class SunburstLayout {
    let focus: FileNode
    let segments: [SunburstSegment]
    let byKey: [SunburstSegmentKey: SunburstSegment]
    /// Segments grouped by ring depth, each sub-array sorted ascending by `startAngle`
    /// (true by construction — see `build`), enabling binary-search hit testing.
    let segmentsByDepth: [[SunburstSegment]]
    /// Node identity -> its segment, for cross-highlighting with the sidebar's `state.hovered`.
    let byNodeID: [ObjectIdentifier: SunburstSegment]

    private init(focus: FileNode, segments: [SunburstSegment]) {
        self.focus = focus
        self.segments = segments
        var byKey: [SunburstSegmentKey: SunburstSegment] = [:]
        var byNodeID: [ObjectIdentifier: SunburstSegment] = [:]
        var byDepth: [[SunburstSegment]] = Array(repeating: [], count: SunburstConstants.maxRings)
        for seg in segments {
            byKey[seg.key] = seg
            if let node = seg.node { byNodeID[ObjectIdentifier(node)] = seg }
            if seg.depth >= 0 && seg.depth < byDepth.count { byDepth[seg.depth].append(seg) }
        }
        self.byKey = byKey
        self.byNodeID = byNodeID
        self.segmentsByDepth = byDepth
    }

    static func build(focus: FileNode) -> SunburstLayout {
        var segments: [SunburstSegment] = []
        buildChildren(of: focus, focus: focus, depth: 0, angleStart: 0, angleEnd: 2 * .pi, segments: &segments)
        return SunburstLayout(focus: focus, segments: segments)
    }

    /// Depth-first, so that for any fixed depth the resulting sub-array is
    /// produced in increasing-angle order: each parent's whole angular span is
    /// consumed (recursed into) before the next sibling begins.
    private static func buildChildren(of node: FileNode, focus: FileNode, depth: Int, angleStart: Double, angleEnd: Double,
                                       segments: inout [SunburstSegment]) {
        guard depth < SunburstConstants.maxRings, node.isDirectory, !node.children.isEmpty, node.size > 0 else { return }
        let total = Double(node.size)
        let fullSpan = angleEnd - angleStart
        guard fullSpan > 0 else { return }
        let frac = SunburstGeometry.fracRange(depth: depth)
        var angle = angleStart
        var otherSize: Int64 = 0
        var otherCount = 0

        for child in node.children {
            guard child.size > 0 else { otherCount += 1; continue }
            let fraction = Double(child.size) / total
            let span = fullSpan * fraction
            if span < SunburstConstants.minAngleRadians {
                // Children are sorted by size descending, so every remaining
                // sibling is at least as small — bucket the rest in one pass.
                otherSize += child.size
                otherCount += 1
                continue
            }
            let childStart = angle
            let childEnd = min(angleEnd, angle + span)
            let paint = Palette.paint(for: child, in: focus)

            segments.append(SunburstSegment(
                node: child, parentKey: ObjectIdentifier(node), parentNode: node, depth: depth,
                startAngle: childStart, endAngle: childEnd,
                innerFrac: frac.inner, outerFrac: frac.outer,
                paint: paint, isFile: !child.isDirectory,
                isOther: false, otherCount: 0,
                displaySize: child.size, displayName: child.name))

            angle = childEnd
            if child.isDirectory, !child.children.isEmpty {
                buildChildren(of: child, focus: focus, depth: depth + 1, angleStart: childStart, angleEnd: childEnd,
                              segments: &segments)
            }
        }

        if otherCount > 0, angleEnd - angle > 0.0001 {
            segments.append(SunburstSegment(
                node: nil, parentKey: ObjectIdentifier(node), parentNode: node, depth: depth,
                startAngle: angle, endAngle: angleEnd,
                innerFrac: frac.inner, outerFrac: frac.outer,
                paint: nil, isFile: false,
                isOther: true, otherCount: otherCount,
                displaySize: otherSize, displayName: "Everything else"))
        }
    }
}
