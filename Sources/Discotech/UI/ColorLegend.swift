import SwiftUI

/// What the colours mean right now, in one compact capsule at the trailing end of the path
/// bar (it goes away with the path bar when a Findings files view replaces the canvas, and
/// below `minWidth` of canvas). Follows the "Colour by" setting:
/// - Size: the theme ramp, lightest to strongest, with example sizes for the folder in view.
/// - Kind of content: a dot per kind present in the folder in view, biggest first, with its total.
/// - Top-level folder: a dot per top-level folder of the scan, biggest first.
/// Fewer entries are shown when the bar is tight; the tooltip lists them all.
struct ColorLegend: View {
    /// Narrower canvases leave the path bar to the breadcrumbs.
    static let minWidth: CGFloat = 820
    @EnvironmentObject private var state: AppState
    @ObservedObject private var colors = ColorModeStore.shared

    var body: some View {
        let _ = state.treeVersion  // totals change when items are trashed
        if let focus = state.focus {
            switch colors.mode {
            case .size: SizeLegend(focus: focus).legendCapsule()
            case .kind: entries(Self.kindEntries(in: focus))
            case .folder: entries(Self.folderEntries(root: state.root ?? focus))
            }
        }
    }

    @ViewBuilder private func entries(_ all: [LegendEntry]) -> some View {
        if !all.isEmpty {
            ViewThatFits(in: .horizontal) {
                ForEach(Array(stride(from: all.count, through: 1, by: -1)), id: \.self) { count in
                    EntryRow(entries: Array(all.prefix(count)), more: all.count - count).legendCapsule()
                }
            }
            .help(all.map { $0.detail.isEmpty ? $0.name : "\($0.name): \($0.detail)" }.joined(separator: "\n"))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Colour key")
            .accessibilityValue(all.map(\.name).joined(separator: ", "))
        }
    }

    /// Kinds present among the focus's children, biggest total first.
    static func kindEntries(in focus: FileNode) -> [LegendEntry] {
        var totals: [ContentKind: Int64] = [:]
        for child in focus.children where child.kind == .item && child.size > 0 {
            if let kind = child.contentKind { totals[kind, default: 0] += child.size }
        }
        return totals.sorted { $0.value > $1.value }.map { kind, bytes in
            LegendEntry(name: kind.shortTitle, detail: ByteFormat.string(bytes), paint: Palette.Paint(step: kind.step))
        }
    }

    /// The scan root's real children, biggest first (as `Palette.folderStep` orders them).
    static func folderEntries(root: FileNode) -> [LegendEntry] {
        root.children.filter { !$0.isSynthetic && $0.size > 0 }.prefix(8).map { child in
            LegendEntry(name: child.name, detail: ByteFormat.string(child.size),
                        paint: Palette.Paint(step: Palette.folderStep(for: child)))
        }
    }
}

struct LegendEntry: Identifiable {
    let name: String
    let detail: String
    let paint: Palette.Paint
    var id: String { name }
}

private struct EntryRow: View {
    let entries: [LegendEntry]
    let more: Int

    var body: some View {
        HStack(spacing: Tokens.Space.m) {
            ForEach(entries) { entry in
                HStack(spacing: Tokens.Space.xs) {
                    LegendDot(paint: entry.paint)
                    Text(entry.name)
                        .foregroundStyle(Tokens.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 120, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                    if !entry.detail.isEmpty {
                        Text(entry.detail).foregroundStyle(Tokens.Colors.textSecondary).monospacedDigit()
                    }
                }
            }
            if more > 0 {
                Text("+\(more)").foregroundStyle(Tokens.Colors.textTertiary)
            }
        }
        .font(.caption)
        .fixedSize()
    }
}

/// A ramp step as a small round swatch with a hairline, so pale steps still read on the bar.
struct LegendDot: View {
    let paint: Palette.Paint
    var size: CGFloat = 9

    var body: some View {
        Circle()
            .fill(Palette.color(for: paint))
            .overlay(Circle().strokeBorder(Tokens.Colors.hairlineStrong, lineWidth: 0.5))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The current theme's ramp as a row of steps, lightest (smallest) on the left.
struct RampBar: View {
    var cellWidth: CGFloat = 10
    var height: CGFloat = 7

    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<Palette.steps, id: \.self) { step in
                Rectangle().fill(Palette.color(for: Palette.Paint(step: step)))
                    .frame(width: cellWidth, height: height)
            }
        }
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Tokens.Colors.hairline, lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}

/// "Smaller → larger" over the ramp, with the sizes the first, middle and last steps stand
/// for in the folder in view (`SizeRamp`).
private struct SizeLegend: View {
    let focus: FileNode
    static let cell: CGFloat = 28

    private func size(_ step: Int) -> String {
        ByteFormat.string(Int64(SizeRamp.lowerShare(step: step) * Double(max(focus.size, 1))))
    }

    var body: some View {
        let first = "< \(size(1))"
        let middle = "≈ \(size(Palette.steps / 2))"
        let last = "> \(size(Palette.steps - 1))"
        HStack(spacing: Tokens.Space.s) {
            Text("Smaller").foregroundStyle(Tokens.Colors.textSecondary)
            VStack(spacing: 1) {
                RampBar(cellWidth: Self.cell, height: 7)
                HStack(spacing: 0) {
                    Text(first)
                    Spacer(minLength: Tokens.Space.s)
                    Text(middle)
                    Spacer(minLength: Tokens.Space.s)
                    Text(last)
                }
                .font(.system(size: 9))
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(Tokens.Colors.textTertiary)
                .frame(width: Self.cell * CGFloat(Palette.steps) + CGFloat(Palette.steps - 1))
            }
            Text("Larger").foregroundStyle(Tokens.Colors.textSecondary)
        }
        .font(.caption)
        .fixedSize()
        .help("Colour by size: \(ColorMode.sizeReading.lowercased()). Smallest step: \(first); middle: \(middle); largest step: \(last) of this folder’s \(ByteFormat.string(focus.size)).")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Colour key: \(ColorMode.sizeReading.lowercased())")
        .accessibilityValue("\(first), \(middle), \(last)")
    }
}

private extension View {
    func legendCapsule() -> some View {
        padding(.horizontal, Tokens.Space.m)
            .padding(.vertical, Tokens.Space.xs)
            .glassSurface(Capsule())
    }
}
