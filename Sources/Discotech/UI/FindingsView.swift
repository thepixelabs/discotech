import SwiftUI

// MARK: - Model

/// Runs `Findings.find` off the main thread once per scan and holds the result for the
/// sidebar's Findings tab. Owned by `AppState` (not the sidebar, which a theme change
/// rebuilds) and told to `refresh` whenever `state.root` changes — a rescan hands back a
/// brand-new root `FileNode`, so identity alone is enough to know a recompute is needed.
///
/// The walk reads the live tree off the main thread, so it must never overlap a trash
/// run, which removes nodes from that same tree on the main actor. The run brackets its
/// changes with `beginTreeChange` (waits for any walk in flight and holds new ones back)
/// and `endTreeChange` (walks again, so whatever was trashed drops out).
@MainActor
final class FindingsModel: ObservableObject {
    @Published private(set) var findings: [Finding] = []
    @Published private(set) var isComputing = false

    private var root: FileNode?
    /// The latest walk. Each walk waits for the one before it to finish, so awaiting this
    /// one waits for every walk that may still be reading a tree.
    private var task: Task<Void, Never>?
    /// Bumped per walk started (and when the tree goes); a result from an older walk is dropped.
    private var generation = 0
    /// Trash runs changing the tree right now (each window can run one).
    private var treeChanges = 0

    func refresh(for root: FileNode?) {
        guard root !== self.root else { return }
        self.root = root
        guard root != nil else {
            task?.cancel()
            generation += 1
            findings = []
            isComputing = false
            return
        }
        isComputing = true
        startWalk()
    }

    /// Call before removing nodes from the tree. Returns once no walk is reading it; until
    /// the matching `endTreeChange`, a refresh only queues its walk.
    func beginTreeChange() async {
        treeChanges += 1
        await task?.value
    }

    /// The tree changed in place: walk it again, so trashed items drop out. The current
    /// cards stay up until the new result replaces them.
    func endTreeChange() {
        treeChanges -= 1
        if treeChanges == 0 { startWalk() }
    }

    private func startWalk() {
        task?.cancel()
        guard treeChanges == 0, let root else { return }  // `endTreeChange` starts it
        generation += 1
        let generation = self.generation
        let previous = task
        task = Task.detached(priority: .userInitiated) { [weak self] in
            // One walk at a time: a superseded walk can't be interrupted, only skipped.
            await previous?.value
            guard !Task.isCancelled else { return }
            #if DEBUG
            let started = ContinuousClock.now
            DebugHooks.findingsWalkStarted()
            defer { DebugHooks.findingsWalkEnded() }
            #endif
            let result = Findings.find(in: root)
            #if DEBUG
            if DebugHooks.logFindingsTiming { DebugHooks.logFindings(result, in: root, took: ContinuousClock.now - started) }
            #endif
            guard !Task.isCancelled else { return }
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.findings = result
                self.isComputing = false
            }
        }
    }
}

// MARK: - List

/// The sidebar's "Findings" tab: one card per cleanup suggestion, in two labelled
/// groups (Safe to clear, then Review first), largest first within each.
struct FindingsListView: View {
    @ObservedObject var model: FindingsModel
    @EnvironmentObject var state: AppState
    /// Short window: cards drop their explanation line.
    var compact = false

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(spacing: Tokens.Space.s) {
                if model.isComputing {
                    ForEach(0..<3, id: \.self) { _ in SkeletonCard() }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Looking for space you can clear")
                } else if model.findings.isEmpty {
                    EmptyFindingsCard()
                } else {
                    // `model.findings` is already safe-then-review, so the debug hooks'
                    // indices still match the order on screen.
                    ForEach(Finding.Tier.allCases, id: \.self) { tier in
                        let group = model.findings.filter { $0.tier == tier }
                        if !group.isEmpty {
                            FindingsGroupHeader(tier: tier, total: group.reduce(0) { $0 + $1.totalSize },
                                                compact: compact, isFirst: tier == model.findings.first?.tier)
                                .id(tier)
                            ForEach(group) { finding in
                                FindingCard(finding: finding, compact: compact)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Tokens.Space.s + Tokens.Space.xxs)
            .padding(.top, Tokens.Space.xxs)
            // Room to scroll the last card fully clear of the fade above the Crate.
            .padding(.bottom, Tokens.Space.xl)
        }
        .scrollBounceBehavior(.basedOnSize)
        .modifier(BottomFade())
        #if DEBUG
        .onChange(of: model.isComputing) { _, computing in
            if !computing { debugOpenFinding(); debugScroll(proxy) }
        }
        .onAppear { if !model.isComputing { debugOpenFinding(); debugScroll(proxy) } }
        #endif
        }
    }
}

/// Fades the last few points of a scroll area, so a card cut off by the edge reads as
/// "more below", not as broken.
struct BottomFade: ViewModifier {
    func body(content: Content) -> some View {
        content.mask {
            VStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: Tokens.Space.l)
            }
        }
    }
}

// MARK: - Card

/// Badge hue per kind of finding, fixed so it's learnable: caches azure, build output
/// pink, dependencies lime, environments and devices teal, logs and machine images
/// indigo, personal files and anything else violet. Review-tier kinds never use pink,
/// the warmest hue, so nothing there reads as a warning.
extension Finding {
    var hue: Tokens.Spectrum.Hue {
        switch icon {
        case "tray", "tray.2", "globe", "macwindow", "cloud": .azure
        case "hammer", "gamecontroller": .pink
        case "shippingbox", "chart.bar.xaxis": .lime
        case "leaf", "iphone", "ipad.and.iphone", "apps.iphone": .teal
        case "doc.text", "doc.text.magnifyingglass", "cpu", "cube.box", "desktopcomputer",
             "opticaldiscdrive", "externaldrive": .indigo
        default: .violet  // trash, archives, attachments, installers, videos, largest files
        }
    }
}

extension Finding.Tier {
    var title: String {
        switch self {
        case .safe: "Safe to clear"
        case .review: "Review first"
        }
    }

    var caption: String {
        switch self {
        case .safe: "Rebuilt or downloaded again automatically when needed."
        case .review: "Probably not needed, but personal or not rebuilt. Look through these before adding them."
        }
    }
}

/// Labels one group of cards: tracked title and its total, then a one-line caption
/// (dropped in a short window, like the cards' explanations).
private struct FindingsGroupHeader: View {
    let tier: Finding.Tier
    let total: Int64
    let compact: Bool
    let isFirst: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.xs) {
                Text(tier.title.uppercased())
                    .font(Tokens.Typeface.eyebrow)
                    .tracking(Tokens.Typeface.eyebrowTracking)
                    .foregroundStyle(Tokens.Colors.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: Tokens.Space.xs)
                Text(ByteFormat.string(total))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Tokens.Colors.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            if !compact {
                Text(tier.caption)
                    .font(.caption)
                    .foregroundStyle(Tokens.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Tokens.Space.xxs)
        // Space above the second group so it reads as a new section, not another card.
        .padding(.top, isFirst ? 0 : Tokens.Space.m)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel("\(tier.title), \(ByteFormat.string(total))")
    }
}

private struct FindingCard: View {
    let finding: Finding
    let compact: Bool
    @EnvironmentObject var state: AppState

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s) {
            header
            if !compact {
                Text(finding.reason)
                    .font(.caption)
                    .foregroundStyle(Tokens.Colors.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Kept in a short window too: it's the one line that says "look first".
            if finding.tier == .review {
                Label("Check before adding", systemImage: "eye")
                    .font(.caption)
                    .foregroundStyle(Tokens.Colors.textSecondary)
                    .lineLimit(1)
            }
            HStack(spacing: Tokens.Space.s) {
                if finding.isCollectible {
                    addButton
                } else {
                    Label("Empty the Trash in Finder", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(Tokens.Colors.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                }
                Spacer(minLength: Tokens.Space.s)
                viewButton
            }
        }
        .padding(Tokens.Space.m)
        .cardSurface(shape)
        .onHover { inside in
            if inside { state.emphasize(finding.nodes) } else { state.clearEmphasis() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var text = "\(finding.title), \(ByteFormat.string(finding.totalSize)), \(finding.countLabel)"
        if finding.tier == .review { text += ", check before adding" }
        if !finding.isCollectible { text += ", empty the Trash in Finder to free this space" }
        return text
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Tokens.Space.s + Tokens.Space.xxs) {
            IconBadge(systemImage: finding.icon, hue: finding.hue)
            VStack(alignment: .leading, spacing: 1) {
                Text(finding.title)
                    .font(Tokens.Typeface.cardTitle)
                    .foregroundStyle(Tokens.Colors.textPrimary)
                    .lineLimit(2)
                Text(finding.countLabel)
                    .font(.caption)
                    .foregroundStyle(Tokens.Colors.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Tokens.Space.xs)
            Text(ByteFormat.string(finding.totalSize))
                .font(Tokens.Typeface.cardFigure)
                .foregroundStyle(Tokens.Colors.textPrimary)
                .lineLimit(1)
                .fixedSize()
        }
    }

    /// Swaps the canvas for this finding's files view (the card is too narrow
    /// to list paths); the open finding's card is marked so you can tell which one it is.
    private var viewButton: some View {
        let isOpen = state.detailFinding?.id == finding.id
        return Button {
            if isOpen { state.closeFindingDetail() } else { state.openFindingDetail(finding) }
        } label: {
            HStack(spacing: Tokens.Space.xxs) {
                Text(isOpen ? "Close list" : "View items")
                Image(systemName: "list.bullet.rectangle")
                    .accessibilityHidden(true)
            }
            .font(.caption)
            .foregroundStyle(isOpen ? Tokens.Colors.accentText : Tokens.Colors.textSecondary)
            .lineLimit(1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOpen ? "Close the list of \(Count.items(finding.nodes.count))"
                                   : "View the \(Count.items(finding.nodes.count))")
    }

    @ViewBuilder private var addButton: some View {
        if finding.nodes.allSatisfy(state.isCollected) {
            Label("In \(Brand.crate)", systemImage: "checkmark")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Tokens.Colors.positive)
                .lineLimit(1)
        } else {
            Button {
                finding.nodes.forEach(state.collect)
            } label: {
                Label("Add to \(Brand.crate)", systemImage: "plus")
                    .lineLimit(1)
            }
            .buttonStyle(.studioText)
        }
    }
}

/// Static placeholder while Findings are computed (no shimmer: nothing to animate).
private struct SkeletonCard: View {
    var body: some View {
        let bar = { (w: CGFloat, h: CGFloat) in
            RoundedRectangle(cornerRadius: h / 2).fill(Tokens.Colors.track).frame(width: w, height: h)
        }
        VStack(alignment: .leading, spacing: Tokens.Space.s) {
            HStack(spacing: Tokens.Space.s + Tokens.Space.xxs) {
                RoundedRectangle(cornerRadius: Tokens.Radius.badge, style: .continuous)
                    .fill(Tokens.Colors.track)
                    .frame(width: Tokens.Size.badge, height: Tokens.Size.badge)
                VStack(alignment: .leading, spacing: Tokens.Space.xs) { bar(110, 9); bar(64, 7) }
                Spacer()
                bar(56, 12)
            }
            bar(170, 7)
        }
        .padding(Tokens.Space.m)
        .cardSurface(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
        .accessibilityHidden(true)
    }
}

private struct EmptyFindingsCard: View {
    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Space.s + Tokens.Space.xxs) {
            IconBadge(systemImage: "checkmark", hue: .lime)
            VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
                Text("Nothing to clean up here")
                    .font(Tokens.Typeface.cardTitle)
                    .foregroundStyle(Tokens.Colors.textPrimary)
                Text("Caches and rebuildable dev output show up under Safe to clear; big downloads, backups and other things worth a look under Review first. Suggestions under \(Findings.minFindingSize >> 20) MB are left out.")
                    .font(.caption)
                    .foregroundStyle(Tokens.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Tokens.Space.m)
        .cardSurface(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
