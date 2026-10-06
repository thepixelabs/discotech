import SwiftUI

@main
struct DiscotechApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()
    @StateObject private var themes = ThemeStore.shared
    @StateObject private var terms = TermsStore.shared

    var body: some Scene {
        WindowGroup(Brand.name) {
            // The terms come first: until they are accepted, the agreement screen is all
            // the window shows (`TermsGate`).
            ThemedRoot { TermsGate { ContentView() } }
                .environmentObject(state)
                .environmentObject(state.findings)
                // The smallest size every screen is verified at; below it things would
                // have to overlap, so the window simply can't get smaller.
                .frame(minWidth: Tokens.Size.windowMin.width, minHeight: Tokens.Size.windowMin.height)
        }
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        .defaultSize(width: Tokens.Size.windowDefault.width, height: Tokens.Size.windowDefault.height)
        .commands {
            ViewCommands(state: state, themes: themes, terms: terms)
            HelpCommands(terms: terms)
        }

        Settings {
            SettingsView()
                .tint(Tokens.Colors.accent)
        }

        // Help → Discotech Help (⌘?): the same help centre the toolbar "?" opens.
        Window("\(Brand.name) Help", id: HelpCommands.windowID) {
            HelpCenterView()
                .frame(width: 400, height: 560)
                .tint(Tokens.Colors.accent)
        }
        .windowResizability(.contentSize)

        // Help → Discotech Terms of Use… and Settings → Terms: the terms, read-only.
        Window(Terms.windowTitle, id: TermsDocumentView.windowID) {
            TermsDocumentView()
                .tint(Tokens.Colors.accent)
        }
        .windowResizability(.contentSize)
    }
}

/// The View menu: every canvas and navigation shortcut, written down in one place so
/// they can be discovered without hovering the right control first.
private struct ViewCommands: Commands {
    @ObservedObject var state: AppState
    @ObservedObject var themes: ThemeStore
    @ObservedObject var terms: TermsStore

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            let browsing = terms.isAccepted && state.phase == .browsing
            ForEach(Array(AppState.CanvasMode.allCases.enumerated()), id: \.element) { index, mode in
                Button("Show as \(mode.title)") { state.canvasMode = mode }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    .disabled(!browsing)
            }
            Divider()
            Picker("Palette Style", selection: $themes.style) {
                ForEach(PaletteStyle.allCases) { Text($0.title).tag($0) }
            }
            if themes.style == .signal {
                Picker("Theme", selection: $themes.signal) {
                    ForEach(SignalTheme.allCases) { Text($0.title).tag($0) }
                }
            } else {
                Picker("Theme", selection: $themes.theme) {
                    ForEach(Theme.allCases) { Text($0.title).tag($0) }
                }
            }
            Divider()
            Button("Enclosing Folder") { state.zoomOut() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!browsing || state.focus?.parent == nil)
            Button("Quick Look") {
                if let node = state.selected ?? state.hovered { QuickLookController.shared.preview(node) }
            }
            .disabled(!browsing || (state.selected ?? state.hovered).map(\.isSynthetic) ?? true)
            Divider()
            Button("Scan Again") { state.rescan() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!terms.isAccepted || state.scanRoot == nil || state.phase == .scanning)
            Button("All Drives") { state.backToStart() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(!terms.isAccepted || state.phase == .start)
            Divider()
        }
    }
}

/// Replaces the default (empty) Help menu item with the help centre and the terms. Both
/// stay disabled until the terms are accepted (the agreement screen already shows them).
private struct HelpCommands: Commands {
    static let windowID = "help"
    @ObservedObject var terms: TermsStore
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("\(Brand.name) Help") { openWindow(id: Self.windowID) }
                .keyboardShortcut("?", modifiers: .command)
                .disabled(!terms.isAccepted)
            Button("\(Terms.windowTitle)…") { openWindow(id: TermsDocumentView.windowID) }
                .disabled(!terms.isAccepted)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (swift run) rather than a bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        #if DEBUG
        DebugHooks.applicationLaunched()
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
