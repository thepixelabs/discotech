#if DEBUG
import AppKit
import SwiftUI

/// Dev-only hooks for the terms screens (never compiled into release). With them, plus the
/// store's DISCOTECH_RESET_TERMS / DISCOTECH_ACCEPT_TERMS (see `TermsStore`):
///   DISCOTECH_TERMS_TICK=2             tick the agreement checkbox 2 s after the screen shows
///   DISCOTECH_TERMS_AGREE=4            press Agree and Continue 4 s after it shows (does
///                                      nothing unless the box is ticked by then)
///   DISCOTECH_OPEN_TERMS=1             open Help → Discotech Terms of Use… 1 s after launch
///   DISCOTECH_TERMS_SNAPSHOT=/a.png    once the Terms window is up, write it to PNG
extension DebugHooks {
    static func applyTermsGate(tick: @escaping @MainActor () -> Void, agree: @escaping @MainActor () -> Void) async {
        applyPresentation()
        let env = ProcessInfo.processInfo.environment
        FileHandle.standardError.write(Data("terms gate shown (accepted version \(TermsStore.shared.acceptedVersion), current \(Terms.version))\n".utf8))
        if let t = env["DISCOTECH_TERMS_TICK"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { tick() }
        }
        if let t = env["DISCOTECH_TERMS_AGREE"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { agree() }
        }
    }

    /// Writes the window it sits in to PNG 1.2 s after it appears, when `envKey` names a path.
    struct WindowSnapshotHook: NSViewRepresentable {
        let envKey: String

        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            guard let path = ProcessInfo.processInfo.environment[envKey] else { return view }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak view] in
                guard let window = view?.window else { return }
                DebugHooks.snapshot(to: path, window: window)
                FileHandle.standardError.write(Data("\(envKey): \(path)\n".utf8))
            }
            return view
        }

        func updateNSView(_ nsView: NSView, context: Context) {}
    }
}
#endif
