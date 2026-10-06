import SwiftUI

/// Phase `.scanning`: live progress and a way out.
///
/// The ring around the mirror ball is real progress when a whole volume is scanned
/// (bytes measured against the volume's used space, held under 99 % until the scan
/// finishes). A folder's total isn't known up front, so there it's a slow
/// indeterminate sweep — or, under Reduce Motion, just the track and the counters.
///
/// When nothing has been measured for a few seconds (`AppState.scanStall`), the path
/// line says what the scan is waiting on, with a hint about macOS privacy prompts.
struct ScanningView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Used bytes of the volume being scanned; nil for a folder scan.
    @State private var volumeUsed: Int64?

    private var targetName: String {
        guard let url = state.scanRoot else { return "" }
        if url.path == "/" {
            return (try? url.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? "/"
        }
        return FileManager.default.displayName(atPath: url.path)
    }

    private var fraction: Double? {
        guard let volumeUsed, volumeUsed > 0 else { return nil }
        return min(0.99, Double(state.progress.bytesScanned) / Double(volumeUsed))
    }

    var body: some View {
        let p = state.progress
        // Dashes until the first progress tick, rather than "0 / Zero KB".
        let started = p.filesScanned > 0 || p.directoriesScanned > 0
        ZStack {
            Backdrop()

            VStack(spacing: Tokens.Space.xl) {
                ZStack {
                    RingGauge(fraction: fraction, lineWidth: 10)
                        .frame(width: Self.ringSide, height: Self.ringSide)
                    MirrorBall()
                        .frame(width: Tokens.Size.mirrorBall, height: Tokens.Size.mirrorBall)
                }
                .frame(width: Self.ringSide, height: Self.ringSide)
                .accessibilityElement()
                .accessibilityLabel("Scanning")
                .accessibilityValue(fraction.map { "About \(Percent.string($0)) of the used space measured" } ?? "In progress")
                .accessibilityAddTraits(.updatesFrequently)

                VStack(spacing: Tokens.Space.s) {
                    Text("Scanning \(targetName)")
                        .font(.system(.title, design: .rounded).weight(.semibold))
                        .foregroundStyle(Tokens.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let stall = state.scanStall {
                        VStack(spacing: Tokens.Space.xxs) {
                            Text("Waiting for macOS or a slow folder…")
                                .font(.callout)
                                .foregroundStyle(Tokens.Colors.textSecondary)
                            if let waiting = Self.describe(stall.paths) {
                                pathLine(waiting)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    } else {
                        pathLine(p.currentPath)
                            .accessibilityLabel("Current folder")
                            .accessibilityValue(p.currentPath)
                    }
                }

                HStack(spacing: 0) {
                    Stat(value: started ? Count.string(p.filesScanned) : "–", label: "files")
                    divider
                    Stat(value: started ? Count.string(p.directoriesScanned) : "–", label: "folders")
                    divider
                    Stat(value: started ? Bytes.string(p.bytesScanned) : "–",
                         label: fraction.map { "measured · \(Percent.string($0))" } ?? "measured")
                }
                .padding(.vertical, Tokens.Space.l)
                .padding(.horizontal, Tokens.Space.s)
                .cardSurface(RoundedRectangle(cornerRadius: Tokens.Radius.hero, style: .continuous))

                HStack(spacing: Tokens.Space.m) {
                    Button("Cancel") { state.cancelScan() }
                        .buttonStyle(.studio(.secondary, large: true))
                        .keyboardShortcut(.cancelAction)
                        .help("Stop and discard this scan (Esc)")
                    // Pressing it is acknowledged at once; the results follow within a moment
                    // even when macOS is still holding a folder.
                    Button(state.isPartialScan ? "Stopping…" : "Stop and Show Results") { state.stopScan() }
                        .buttonStyle(.studio(.primary, large: true))
                        .disabled(state.isPartialScan || (!started && state.scanStall == nil))
                        .help("Stop now and browse everything measured so far")
                }
                .fixedSize()

                if state.scanStall != nil {
                    StallHint()
                        .transition(.opacity)
                }
            }
            .padding(Tokens.Space.xxl)
            .animation(Tokens.Motion.state(reduceMotion), value: state.scanStall)
        }
        .hidingWindowTitle()
        .task(id: state.scanRoot) { volumeUsed = Self.usedBytes(ifVolume: state.scanRoot) }
    }

    private func pathLine(_ path: String) -> some View {
        Text(path.isEmpty ? " " : path)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Tokens.Colors.textTertiary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 520)
    }

    /// "~/Music", or "~/Music + 2 more"; nil when the scan can't tell.
    private static func describe(_ paths: [String]) -> String? {
        guard let first = paths.first else { return nil }
        let shown = (first as NSString).abbreviatingWithTildeInPath
        return paths.count > 1 ? "\(shown) + \(paths.count - 1) more" : shown
    }

    /// Diameter of the progress ring around the ball.
    private static let ringSide: CGFloat = 232

    /// Used space when `url` is a volume's root, the same figure the start screen shows.
    private static func usedBytes(ifVolume url: URL?) -> Int64? {
        guard let url,
              let v = try? url.resourceValues(forKeys: [.isVolumeKey, .volumeTotalCapacityKey,
                                                        .volumeAvailableCapacityForImportantUsageKey,
                                                        .volumeAvailableCapacityKey]),
              v.isVolume == true, let total = v.volumeTotalCapacity else { return nil }
        let available = v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0)
        let used = Int64(total) - available
        return used > 0 ? used : nil
    }

    private var divider: some View {
        Rectangle().fill(Tokens.Colors.hairline).frame(width: 1, height: 40)
    }
}

/// Shown under the buttons while a scan is stalled: the usual cause is a macOS
/// privacy prompt waiting for an answer.
private struct StallHint: View {
    var body: some View {
        VStack(spacing: Tokens.Space.s) {
            Text("If macOS asked for access (Music, Pictures, Downloads…), answer the prompt; granting Full Disk Access in System Settings stops these prompts.")
                .font(.callout)
                .foregroundStyle(Tokens.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460)
            Button("Open Privacy Settings") { FullDiskAccess.openSettings() }
                .buttonStyle(.studio(.secondary))
                .help("Open Privacy & Security › Full Disk Access in System Settings")
        }
    }
}

private struct Stat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: Tokens.Space.xxs) {
            Text(value)
                .font(Tokens.Typeface.figure(28))
                .foregroundStyle(Tokens.Colors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.callout)
                .foregroundStyle(Tokens.Colors.textSecondary)
                .lineLimit(1)
        }
        .frame(width: 168)
        .accessibilityElement(children: .combine)
    }
}
