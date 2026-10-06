import AppKit
import SwiftUI

/// Finder icons, looked up lazily off the main thread and cached by path.
/// `NSWorkspace.icon(forFile:)` hits the disk and LaunchServices, so it must never
/// run inline in a row's `body`.
///
/// When LaunchServices can't resolve a path (it vanished, or TCC hides it) it returns
/// the generic *document* icon — even for a folder. The scan already knows what every
/// node is, so a path that isn't there as a folder resolves to `nil` here and the view
/// keeps its own correct generic icon instead.
@MainActor
final class IconCache {
    static let shared = IconCache()

    /// Boxed so a known miss can be cached too (NSCache can't store nil).
    private final class Entry { let image: NSImage?; init(_ image: NSImage?) { self.image = image } }

    private let cache = NSCache<NSString, Entry>()
    private var inflight: [String: [CheckedContinuation<NSImage?, Never>]] = [:]
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "Discotech.IconCache"
        q.maxConcurrentOperationCount = 4
        q.qualityOfService = .utility
        return q
    }()

    static let folder = NSWorkspace.shared.icon(for: .folder)
    static let document = NSWorkspace.shared.icon(for: .data)

    private init() { cache.countLimit = 4000 }

    /// `.some(nil)` = looked up, nothing usable; `nil` = not looked up yet.
    func cached(_ path: String) -> NSImage?? {
        cache.object(forKey: path as NSString).map(\.image)
    }

    /// The Finder icon, or nil when the path can't be resolved to what the scan saw.
    /// `urgent` jumps the queue (the hover card, which must not wait behind a list's
    /// worth of row icons).
    func icon(for path: String, isDirectory: Bool, urgent: Bool = false) async -> NSImage? {
        if let hit = cached(path) { return hit }
        return await withCheckedContinuation { cont in
            if inflight[path] != nil {
                inflight[path]!.append(cont)
                return
            }
            inflight[path] = [cont]
            let op = BlockOperation {
                var isDir: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
                // Only a folder can be mislabeled as a document; files keep whatever LS says.
                let image: NSImage? = exists && (isDir.boolValue || !isDirectory)
                    ? NSWorkspace.shared.icon(forFile: path) : nil
                Task { @MainActor in
                    self.cache.setObject(Entry(image), forKey: path as NSString)
                    for c in self.inflight.removeValue(forKey: path) ?? [] { c.resume(returning: image) }
                }
            }
            if urgent {
                op.queuePriority = .veryHigh
                op.qualityOfService = .userInitiated
            }
            queue.addOperation(op)
        }
    }
}

/// A Finder icon for `path`: shows the generic folder/document icon immediately,
/// then swaps in the real one once loaded. The loaded image is remembered together
/// with its path, so a view reused for another item (the hover card) never shows the
/// previous item's icon while the new one loads.
struct FileIconView: View {
    let path: String
    let isDirectory: Bool
    var size: CGFloat = Tokens.Size.rowIcon
    var urgent = false

    @State private var loaded: (path: String, image: NSImage?)?

    var body: some View {
        let fallback = isDirectory ? IconCache.folder : IconCache.document
        let resolved: NSImage? = loaded?.path == path ? loaded?.image : IconCache.shared.cached(path) ?? nil
        Image(nsImage: resolved ?? fallback)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
            .task(id: path) {
                let image = await IconCache.shared.icon(for: path, isDirectory: isDirectory, urgent: urgent)
                loaded = (path, image)
            }
    }
}
