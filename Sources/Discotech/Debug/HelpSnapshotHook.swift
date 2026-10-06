#if DEBUG
import AppKit
import SwiftUI

/// `DISCOTECH_HELP_SNAPSHOT=/path.png` (with `DISCOTECH_OPEN_HELP=t` to open the Help window
/// t s after launch): once the help centre is up, write its window to PNG.
struct HelpSnapshotHook: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        guard let path = ProcessInfo.processInfo.environment["DISCOTECH_HELP_SNAPSHOT"] else { return view }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak view] in
            guard let window = view?.window else { return }
            // DISCOTECH_SNAPSHOT_MODE=view: render the view hierarchy (works while the screen is locked).
            if ProcessInfo.processInfo.environment["DISCOTECH_SNAPSHOT_MODE"] == "view", let root = window.contentView?.superview,
               let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                root.cacheDisplay(in: root.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                return
            }
            typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
            guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return }
            let create = unsafeBitCast(sym, to: CreateImage.self)
            guard let image = create(.null, 1 << 3, UInt32(window.windowNumber), (1 << 0) | (1 << 3))?.takeRetainedValue() else { return }
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif
