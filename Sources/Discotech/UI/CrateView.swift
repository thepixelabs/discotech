import Combine
import SwiftUI

/// The Crate, at the bottom of the sidebar. Accepts dragged node paths (from rows or
/// the chart), lists what's inside, and opens a review window. Nothing can be moved to
/// the Trash from the sidebar: only from the review window, which lists every item first
/// and asks for a final confirmation.
///
/// Empty, it is a dashed drop zone (the platform's "drop here" affordance, no fill).
/// Filled, it is a solid card whose clear button is the screen's one primary action.
/// While something is dragged over it, the outline turns into a solid spectrum rim —
/// a static change, no animation. `compact` (short windows) folds it to a single line.
struct CrateView: View {
    var compact = false
    @EnvironmentObject var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage("crateExpanded") private var expandedSetting = true
    /// In a short window the list starts folded, whatever the saved setting says.
    @State private var compactExpanded = false
    @State private var isTargeted = false
    @State private var reviewing = false
    /// Transient "can't go in the Crate" notice after a drop of protected items.
    @State private var refusal: RefusalNotice?

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous) }

    private var expanded: Bool {
        get { compact ? compactExpanded : expandedSetting }
        nonmutating set { if compact { compactExpanded = newValue } else { expandedSetting = newValue } }
    }

    var body: some View {
        let items = state.collected
        VStack(alignment: .leading, spacing: compact ? Tokens.Space.s : Tokens.Space.m) {
            if items.isEmpty {
                emptyState
            } else {
                header(items)
                if expanded { list(items) }
                actions
            }
        }
        .padding(compact ? Tokens.Space.s + Tokens.Space.xxs : Tokens.Space.m + Tokens.Space.xxs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { surface(filled: !items.isEmpty) }
        .overlay {
            if isTargeted { SpectrumRim(shape: shape, lineWidth: 2) }
        }
        .overlay(alignment: .top) {
            // Floats just above the Crate (over the list's last rows) so nothing shifts:
            // a zero-height anchor on the Crate's top edge, content growing upward.
            ZStack(alignment: .bottom) {
                if let refusal {
                    RefusalNoticeView(notice: refusal)
                        .padding(.bottom, Tokens.Space.s)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 0, alignment: .bottom)
            .allowsHitTesting(false)
        }
        .animation(Tokens.Motion.state(reduceMotion), value: items.count)
        .onChange(of: items.count) { old, new in
            // Adding something opens the list, so each item's remove button is in reach.
            if new > old { expanded = true }
        }
        .dropDestination(for: String.self) { paths, _ in
            let result = state.collectDropped(paths: paths)
            if !result.refused.isEmpty { showRefusal(result.refused) }
            return result.added > 0
        } isTargeted: { targeted in
            withAnimation(Tokens.Motion.hover(reduceMotion)) { isTargeted = targeted }
        }
        .sheet(isPresented: $reviewing) {
            CrateReviewSheet { reviewing = false }
                .environmentObject(state)
        }
        #if DEBUG
        .onAppear {
            if DebugHooks.trashAbandonTest != nil, !DebugHooks.trashAbandonOpened {
                DebugHooks.trashAbandonOpened = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { if !state.collected.isEmpty { reviewing = true } }
            }
            if DebugHooks.previewDrop { isTargeted = true }
            if DebugHooks.previewRefusal, let root = state.root {
                showRefusal([CrateRefusal(name: FileManager.default.displayName(atPath: root.path),
                                          reason: state.collectBlockReason(root) ?? "")])
            }
        }
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Brand.crate)
    }

    @ViewBuilder private func surface(filled: Bool) -> some View {
        if isTargeted {
            shape.fill(Tokens.Colors.selection)
        } else if filled {
            Color.clear.cardSurface(shape)
        } else {
            shape.strokeBorder(Tokens.Colors.hairlineStrong,
                               style: StrokeStyle(lineWidth: Tokens.Size.dashedStroke, dash: [5, 4]))
        }
    }

    /// "Take All Out" undoes collecting (nothing on disk changes); "Review…" is the one
    /// primary action on the browsing screen. It only opens the review window, where
    /// every item is listed before anything can be moved to the Trash.
    private var actions: some View {
        VStack(spacing: compact ? Tokens.Space.xxs : Tokens.Space.xs) {
            Button {
                reviewing = true
            } label: {
                Label("Review \(Count.items(state.collected.count))…", systemImage: "list.bullet.rectangle")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.studio(.primary, large: !compact))
            .keyboardShortcut(.delete, modifiers: .command)
            .help("See everything in the \(Brand.crate) before deciding what to do (⌘⌫)")

            Button {
                withAnimation(Tokens.Motion.state(reduceMotion)) { state.uncollectAll() }
            } label: {
                Label("Take All Out", systemImage: "arrow.uturn.backward")
                    .lineLimit(1)
            }
            .buttonStyle(.studio(.text))
            .help("Empty the \(Brand.crate) without deleting anything")
        }
    }

    // MARK: Refused drops

    /// Shows why a drop was (partly) refused for a few seconds, and tells VoiceOver.
    private func showRefusal(_ refused: [CrateRefusal]) {
        guard let first = refused.first else { return }
        let notice = RefusalNotice(first: first, more: refused.count - 1)
        withAnimation(Tokens.Motion.state(reduceMotion)) { refusal = notice }
        AccessibilityNotification.Announcement(notice.spokenText).post()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Tokens.Motion.noticeSeconds))
            guard refusal?.id == notice.id else { return }  // a newer notice replaced it
            withAnimation(Tokens.Motion.state(reduceMotion)) { refusal = nil }
        }
    }

    // MARK: States

    private var emptyState: some View {
        HStack(spacing: Tokens.Space.m) {
            Image(systemName: isTargeted ? "archivebox.fill" : "archivebox")
                .font(.system(size: compact ? 16 : 20))
                .foregroundStyle(isTargeted ? Tokens.Colors.accent : Tokens.Colors.textSecondary)
                .frame(width: Tokens.Size.badge)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
                Text(isTargeted ? "Drop to add to the \(Brand.crate)" : Brand.crate)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tokens.Colors.textPrimary)
                    .lineLimit(1)
                if !compact {
                    Text("Drag files and folders here to clear them out together.")
                        .font(.caption)
                        .foregroundStyle(Tokens.Colors.textSecondary)
                        .lineLimit(2...3)
                }
            }
            Spacer(minLength: 0)
        }
        .help("Drag files and folders here to clear them out together.")
    }

    private func header(_ items: [FileNode]) -> some View {
        Button {
            withAnimation(Tokens.Motion.state(reduceMotion)) { expanded.toggle() }
        } label: {
            HStack(spacing: Tokens.Space.m) {
                IconBadge(systemImage: "archivebox.fill", hue: .violet, size: compact ? 24 : Tokens.Size.badge)
                VStack(alignment: .leading, spacing: 0) {
                    Text(Brand.crate)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Tokens.Colors.textPrimary)
                    Text(Count.items(items.count))
                        .font(.caption)
                        .foregroundStyle(Tokens.Colors.textSecondary)
                }
                .lineLimit(1)
                Spacer(minLength: Tokens.Space.s)
                Text(ByteFormat.string(state.collectedSize))
                    .font(Tokens.Typeface.figure(compact ? 17 : 22))
                    .foregroundStyle(Tokens.Colors.textPrimary)
                    .lineLimit(1)
                    .layoutPriority(1)
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Tokens.Colors.textSecondary)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(Brand.crate), \(Count.items(items.count)), \(ByteFormat.string(state.collectedSize))")
        .accessibilityHint(expanded ? "Hides the list" : "Shows the list")
    }

    private func list(_ items: [FileNode]) -> some View {
        let cap = compact ? Tokens.Size.crateListCompactMaxHeight : Tokens.Size.crateListMaxHeight
        return ScrollView {
            VStack(spacing: 0) {
                ForEach(items) { node in
                    CrateRow(node: node,
                             reveal: { state.revealInFinder(node) },
                             remove: { withAnimation(Tokens.Motion.state(reduceMotion)) { state.uncollect(node) } })
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .frame(maxHeight: min(cap, CGFloat(items.count) * 30 + 2))
        .scrollBounceBehavior(.basedOnSize)
        .transition(.opacity)
    }
}

private struct CrateRow: View {
    let node: FileNode
    let reveal: () -> Void
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Tokens.Space.s) {
            FileIconView(path: node.path, isDirectory: node.isDirectory, size: 16)
            Text(node.name)
                .font(.callout)
                .foregroundStyle(Tokens.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(node.path)
            Spacer(minLength: Tokens.Space.s)
            Text(ByteFormat.string(node.size))
                .font(.system(.caption, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Tokens.Colors.textSecondary)
                .lineLimit(1)
            Button(action: remove) {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 14))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(hovering ? Tokens.Colors.textPrimary : Tokens.Colors.textSecondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Take out of the \(Brand.crate) (nothing is deleted)")
            .accessibilityLabel("Take \(node.name) out of the \(Brand.crate)")
        }
        .padding(.horizontal, Tokens.Space.xs)
        .frame(height: 30)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hovering ? Tokens.Colors.hairline : Color.clear)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Take Out of \(Brand.crate)", action: remove)
            Button("Show in Finder", action: reveal)
        }
    }
}

private struct RefusalNotice: Identifiable {
    let id = UUID()
    let first: CrateRefusal
    let more: Int

    var title: String {
        more > 0 ? "“\(first.name)” and \(Count.items(more)) more can’t go in the \(Brand.crate)"
                 : "“\(first.name)” can’t go in the \(Brand.crate)"
    }
    var spokenText: String { "\(title). \(first.reason)" }
}

/// Small glass capsule: lock, what was refused, and why.
private struct RefusalNoticeView: View {
    let notice: RefusalNotice

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s) {
            Image(systemName: "lock.fill")
                .foregroundStyle(Tokens.Colors.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
                Text(notice.title)
                    .font(.system(.callout, design: .rounded).weight(.medium))
                    .lineLimit(2)
                Text(notice.first.reason)
                    .font(.caption)
                    .foregroundStyle(Tokens.Colors.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Tokens.Space.m)
        .padding(.vertical, Tokens.Space.s)
        .glassSurface(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Drives one trashing run for the review window, and lets the run (in `AppState`) pause
/// to ask about an item in a sensitive location, however far in it is.
@MainActor
final class TrashSession: ObservableObject {
    enum Phase { case review, running, finished }
    struct Warning: Identifiable {
        let id = UUID()
        let node: FileNode
        let reason: String
    }

    @Published var phase = Phase.review
    @Published var current: FileNode?
    @Published var handled = 0
    @Published var total = 0
    @Published var warning: Warning?
    @Published var outcome = AppState.TrashOutcome()

    private var continuation: CheckedContinuation<AppState.SensitiveDecision, Never>?

    /// Does the actual run: `AppState.trashCollected`. Only the DEBUG self-test passes
    /// something else, a stand-in that never touches the disk (`DebugHooks.stubTrashRun`).
    typealias Runner = @MainActor (AppState, _ progress: (FileNode, Int) -> Void,
                                   _ confirmSensitive: (FileNode, String) async -> AppState.SensitiveDecision)
        async -> AppState.TrashOutcome
    private let runner: Runner

    init(runner: @escaping Runner = { state, progress, confirmSensitive in
        await state.trashCollected(progress: progress, confirmSensitive: confirmSensitive)
    }) {
        self.runner = runner
    }

    private var runTask: Task<Void, Never>?
    private var scanWatch: AnyCancellable?

    /// Starts the run (once). `abandon` stops it.
    func start(_ state: AppState) {
        guard runTask == nil else { return }
        // A rescan or All Drives ends the run. The sheet can't be relied on for that: with
        // its prompt up it can outlive the window content it was presented from.
        scanWatch = state.$phase.dropFirst()
            .sink { [weak self] phase in MainActor.assumeIsolated { if phase != .browsing { self?.abandon() } } }
        runTask = Task { await run(state) }
    }

    private func run(_ state: AppState) async {
        total = state.collected.count
        handled = 0
        phase = .running
        outcome = await runner(state, { [weak self] node, done in
            self?.current = node
            self?.handled = done
        }, { [weak self] node, reason in
            guard let self else { return .stop }
            return await self.ask(node, reason)
        })
        scanWatch = nil
        current = nil
        phase = .finished
    }

    private func ask(_ node: FileNode, _ reason: String) async -> AppState.SensitiveDecision {
        // Abandoned: nobody is left to answer.
        if Task.isCancelled { return .stop }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            warning = Warning(node: node, reason: reason)
        }
    }

    /// Resumes a pending prompt with `decision`; does nothing if none is pending, so the
    /// prompt's continuation is resumed exactly once whoever answers first.
    func answer(_ decision: AppState.SensitiveDecision) {
        #if DEBUG
        DebugHooks.trashAbandonLog("answer \(decision), prompt pending: \(continuation != nil)")
        #endif
        warning = nil
        let pending = continuation
        continuation = nil
        pending?.resume(returning: decision)
    }

    /// The review sheet is going away (taken down with the window's content by All Drives
    /// or a theme change), or the scan changed under the run (`start`'s watch). Stops the
    /// run before its next item and answers a pending sensitive-item prompt with Stop;
    /// without this the run would wait forever on a prompt nobody can see. Safe at any
    /// time, any number of times.
    func abandon() {
        #if DEBUG
        DebugHooks.trashAbandonLog("abandon: run \(runTask == nil ? "not started" : "cancelled"), prompt pending: \(continuation != nil)")
        #endif
        runTask?.cancel()
        answer(.stop)
    }
}

/// The review window. Lists every item in the Crate (name, location, size, and a flag on
/// those in sensitive places) before anything can be moved to the Trash. "Move to Trash…"
/// asks one more time, and during the run each sensitive item asks again on its own.
/// Neither confirmation is a default button: Return never trashes files.
struct CrateReviewSheet: View {
    let close: () -> Void
    @EnvironmentObject var state: AppState
    #if DEBUG
    @StateObject private var session = DebugHooks.trashAbandonTest != nil
        ? TrashSession(runner: DebugHooks.stubTrashRun) : TrashSession()
    #else
    @StateObject private var session = TrashSession()
    #endif
    @State private var confirming = false

    private var sensitiveCount: Int {
        state.collected.filter { Safety.sensitivityReason(forPath: $0.path) != nil }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.l) {
            switch session.phase {
            case .review: review
            case .running: running
            case .finished: finished
            }
        }
        .padding(Tokens.Space.xl)
        .frame(width: 600)
        .interactiveDismissDisabled(session.phase == .running)
        .alert("Move \(Count.items(state.collected.count)) to the Trash?",
               isPresented: $confirming) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive) { session.start(state) }
        } message: {
            Text("They move to the macOS Trash. About \(ByteFormat.string(state.collectedSize)) is freed once the Trash is emptied."
                 + (sensitiveCount > 0 ? "\n\n\(Count.items(sensitiveCount)) in system or app-data folders. You’ll be asked about each one before it moves." : "")
                 + "\n\n" + Terms.deleteReminder)
        }
        .alert("Are you sure?",
               isPresented: Binding(get: { session.warning != nil }, set: { _ in })) {
            Button("Skip This One", role: .cancel) { session.answer(.skip) }
            Button("Stop Here") { session.answer(.stop) }
            Button("Move to Trash", role: .destructive) { session.answer(.moveIt) }
        } message: {
            if let w = session.warning {
                Text("We noticed “\(w.node.name)”, \(w.node.isDirectory ? "a folder" : "a file") you’re moving to the Trash, is \(w.reason).\n\n\(w.node.path)\n\nMoving it could break an app or lose settings.\n\n" + Terms.deleteReminder)
            }
        }
        // However the sheet goes, a run must not keep waiting on a prompt in it.
        .onDisappear { session.abandon() }
        #if DEBUG
        .onAppear { DebugHooks.startTrashAbandonTest(session, state) }
        .onChange(of: session.warning?.id) { _, id in if id != nil { DebugHooks.trashPromptShown(state, close: close) } }
        #endif
    }

    // MARK: Review

    @ViewBuilder private var review: some View {
        let items = state.collected
        HStack(alignment: .top, spacing: Tokens.Space.m) {
            IconBadge(systemImage: "archivebox.fill", hue: .violet, size: 40)
            VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                Text("Review the \(Brand.crate)")
                    .font(.system(.headline, design: .rounded))
                Text("\(Count.items(items.count)) · \(ByteFormat.string(state.collectedSize)). Nothing has been deleted. Take out anything you want to keep.")
                    .font(.callout)
                    .foregroundStyle(Tokens.Colors.textSecondary)
            }
        }

        List(items) { node in
            ReviewRow(node: node) {
                withAnimation { state.uncollect(node) }
            } reveal: { state.revealInFinder(node) }
        }
        .listStyle(.bordered(alternatesRowBackgrounds: true))
        .frame(minHeight: 200, idealHeight: 340, maxHeight: 420)

        HStack {
            Text("Total \(ByteFormat.string(state.collectedSize))")
                .font(.system(.callout, design: .rounded).weight(.medium))
                .monospacedDigit()
            Spacer()
            Button("Take All Out") { state.uncollectAll(); close() }
            Button("Close", role: .cancel, action: close)
                .keyboardShortcut(.cancelAction)
            Button("Move to Trash…", role: .destructive) { confirming = true }
                .disabled(items.isEmpty)
        }
        .onChange(of: items.isEmpty) { _, empty in if empty { close() } }
    }

    // MARK: Running

    private var running: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.m) {
            Text("Moving to the Trash…")
                .font(.system(.headline, design: .rounded))
            ProgressView(value: Double(session.handled), total: Double(max(session.total, 1)))
            Text(session.current.map { "\(session.handled + 1) of \(session.total): \($0.name)" } ?? " ")
                .font(.callout)
                .foregroundStyle(Tokens.Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(minHeight: 120)
    }

    // MARK: Finished

    @ViewBuilder private var finished: some View {
        let o = session.outcome
        Text(o.moved == 0 ? "Nothing was moved" : "Moved \(Count.items(o.moved)) to the Trash")
            .font(.system(.headline, design: .rounded))
        if o.skipped > 0 || o.stopped || !o.failures.isEmpty {
            Text(Count.items(state.collected.count) + " stayed in the \(Brand.crate).")
                .font(.callout)
                .foregroundStyle(Tokens.Colors.textSecondary)
        }
        if !o.failures.isEmpty {
            VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
                ForEach(Array(o.failures.prefix(6).enumerated()), id: \.offset) { _, f in
                    Text("\(f.0.name): \(f.1)").font(.caption).lineLimit(2)
                }
                if o.failures.count > 6 { Text("…and \(o.failures.count - 6) more").font(.caption) }
            }
        }
        HStack {
            Spacer()
            Button("Done", action: close).keyboardShortcut(.defaultAction)
        }
    }
}

private struct ReviewRow: View {
    let node: FileNode
    let remove: () -> Void
    let reveal: () -> Void

    var body: some View {
        let sensitive = Safety.sensitivityReason(forPath: node.path)
        HStack(spacing: Tokens.Space.s) {
            FileIconView(path: node.path, isDirectory: node.isDirectory)
            VStack(alignment: .leading, spacing: 0) {
                Text(node.name).lineLimit(1).truncationMode(.middle)
                Text(node.parent?.path ?? node.path)
                    .font(.caption)
                    .foregroundStyle(Tokens.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            if sensitive != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Tokens.Colors.warning)
                    .help("In a system or app-data folder. You’ll be asked again before it moves.")
                    .accessibilityLabel("In a system or app-data folder")
            }
            Spacer(minLength: Tokens.Space.s)
            Text(ByteFormat.string(node.size))
                .font(.system(.body, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Tokens.Colors.textSecondary)
            Button(action: remove) {
                Image(systemName: "minus.circle.fill").symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.borderless)
            .help("Take out of the \(Brand.crate) (nothing is deleted)")
            .accessibilityLabel("Take \(node.name) out of the \(Brand.crate)")
        }
        .contextMenu {
            Button("Take Out of \(Brand.crate)", action: remove)
            Button("Show in Finder", action: reveal)
        }
    }
}
