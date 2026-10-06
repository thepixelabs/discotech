import AppKit
import SwiftUI

/// Shows `content` only once the current terms are accepted; until then the agreement
/// screen fills the window instead. Nothing inside `content` (the start screen and its
/// drive list, folder drop target, ⌘O, debug autoscan) exists before that.
struct TermsGate<Content: View>: View {
    @ObservedObject private var terms = TermsStore.shared
    @ViewBuilder let content: () -> Content

    var body: some View {
        if terms.isAccepted {
            content()
        } else {
            TermsGateView()
        }
    }
}

/// The agreement screen (docs/TERMS.md sections 1 and 5): heading and summary fixed at the
/// top, the full terms scrolling in the middle, the checkbox and buttons fixed at the
/// bottom. Agree stays disabled until the box is ticked, is never the Return button, and
/// the box starts unticked every time the screen appears.
struct TermsGateView: View {
    @ObservedObject private var terms = TermsStore.shared
    @State private var understood = false

    var body: some View {
        ZStack {
            Backdrop(wash: nil)
            VStack(alignment: .leading, spacing: Tokens.Space.l) {
                header
                FullTermsText()
                    .frame(minHeight: 96, maxHeight: .infinity)
                Toggle(isOn: $understood) {
                    Text(Terms.checkbox)
                        .font(.system(size: 13))
                        .foregroundStyle(Tokens.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.checkbox)
                buttons
            }
            .padding(.horizontal, Tokens.Space.xl)
            .padding(.vertical, Tokens.Space.l)
            .frame(maxWidth: 560, maxHeight: 760)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(Terms.windowTitle)
        .tint(Tokens.Colors.accent)
        .background(QuitWhenWindowCloses())
        #if DEBUG
        .task { await DebugHooks.applyTermsGate(tick: { understood = true }, agree: agree) }
        #endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.m) {
            Text(Terms.heading)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(Tokens.Colors.textPrimary)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: Tokens.Space.xs + 1) {
                ForEach(Array(Terms.summary.enumerated()), id: \.offset) { index, line in
                    HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s) {
                        Text("•").foregroundStyle(Tokens.Colors.accentText).accessibilityHidden(true)
                        Text(line)
                            .font(.system(size: 13, weight: index == 0 ? .semibold : .regular))
                            .foregroundStyle(Tokens.Colors.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: Tokens.Space.m) {
            Spacer(minLength: 0)
            Button(Terms.quitButton) { NSApp.terminate(nil) }
                .buttonStyle(.studio(.secondary, large: true))
                .accessibilityHint(Text("Quits \(Brand.name) without accepting."))
            // No keyboard shortcut on purpose: Return must never agree.
            Button(Terms.agreeButton, action: agree)
                .buttonStyle(.studio(.primary, large: true))
                .disabled(!understood)
                .accessibilityHint(Text(understood ? "Accepts the terms and opens \(Brand.name)."
                                                   : "Tick the checkbox above first."))
        }
    }

    private func agree() {
        guard understood else { return }
        terms.accept()
    }
}

/// The full terms, read-only and selectable, in a scrolling card. Shared by the agreement
/// screen and the Terms window.
struct FullTermsText: View {
    var body: some View {
        ScrollView {
            Text(Terms.fullTextAttributed)
                .font(.system(size: 12))
                .foregroundStyle(Tokens.Colors.textPrimary)
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Tokens.Space.m)
        }
        .scrollBounceBehavior(.basedOnSize)
        .cardSurface(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
        .accessibilityLabel(Text("Full terms"))
    }
}

/// Closing the agreement window (close button, ⌘W) quits: the app must never sit
/// faceless, or with another window open, while the terms are unaccepted. Watches the
/// window itself rather than `onDisappear`, which also fires when a theme change rebuilds
/// the view.
private struct QuitWhenWindowCloses: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowWatcher() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowWatcher: NSView {
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                              object: window, queue: .main) { _ in
                MainActor.assumeIsolated {
                    if !TermsStore.shared.isAccepted { NSApp.terminate(nil) }
                }
            }
        }
    }
}
