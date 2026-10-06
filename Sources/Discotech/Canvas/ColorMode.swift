import Combine
import Foundation

/// What a node's colour means: the user's "Colour by" setting (Settings). Every canvas, the
/// sidebar dots and the hover card resolve colour through `Palette`, which reads
/// `ColorMode.current`, so a switch needs no caller changes. Switching is live: the canvases
/// hear `.discotechThemeDidChange` and the main window's root is rebuilt (`ThemedRoot`).
enum ColorMode: String, CaseIterable, Identifiable {
    /// Ramp position from the item's share of the folder in view: stronger = bigger.
    case size
    /// One ramp step per `ContentKind`, the same everywhere.
    case kind
    /// One ramp step per top-level folder of the scan, kept while zooming.
    case folder

    var id: String { rawValue }

    var title: String {
        switch self {
        case .size: return "Size"
        case .kind: return "Kind of content"
        case .folder: return "Top-level folder"
        }
    }

    /// One line for Settings and the help centre.
    var explanation: String {
        switch self {
        case .size: return "\(ColorMode.sizeReading), so the biggest items stand out."
        case .kind: return "Apps, media, documents, code, caches and so on each keep one colour everywhere."
        case .folder: return "Everything inside a top-level folder of the scan shares its colour, even when you zoom in."
        }
    }

    /// How Size reads in the active palette style and theme: "Lighter is smaller, stronger
    /// is bigger" for Gradient themes, the theme's own hue order for Multicolour ones.
    static var sizeReading: String {
        guard PaletteStyle.current == .signal else { return "Lighter is smaller, stronger is bigger" }
        let reading = SignalTheme.current.sizeReading
        return reading.prefix(1).uppercased() + reading.dropFirst()
    }

    static let defaultsKey = "colorBy"
    static let fallback: ColorMode = .size

    /// The mode everything draws with right now. Change it through `ColorModeStore.shared`.
    static var current: ColorMode { storage }

    fileprivate static var storage: ColorMode = initial()

    /// `defaults` and `environment` are injectable for tests; the app passes neither.
    static func initial(defaults: UserDefaults = .standard,
                        environment: [String: String] = ProcessInfo.processInfo.environment) -> ColorMode {
        #if DEBUG
        // DISCOTECH_COLOR_BY=size|kind|folder for screenshots; not persisted.
        if let spec = environment["DISCOTECH_COLOR_BY"]?.lowercased(), let mode = ColorMode(rawValue: spec) {
            return mode
        }
        #endif
        return defaults.string(forKey: defaultsKey).flatMap(ColorMode.init(rawValue:)) ?? fallback
    }
}

/// The observable side of `ColorMode` (Settings, the help centre, the legend, the root view).
@MainActor
final class ColorModeStore: ObservableObject {
    static let shared = ColorModeStore()

    @Published var mode: ColorMode {
        didSet {
            guard mode != oldValue else { return }
            ColorMode.storage = mode
            #if DEBUG
            if ProcessInfo.processInfo.environment["DISCOTECH_COLOR_BY"] == nil {
                defaults.set(mode.rawValue, forKey: ColorMode.defaultsKey)
            }
            #else
            defaults.set(mode.rawValue, forKey: ColorMode.defaultsKey)
            #endif
            // The same redraw signal a theme switch sends: canvases drop cached colours.
            NotificationCenter.default.post(name: .discotechThemeDidChange, object: nil)
        }
    }

    private let defaults: UserDefaults

    /// `defaults` is injectable so tests never write the real settings; the app uses `shared`.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = ColorMode.storage
    }
}

// MARK: - Kind of content

/// A small fixed set of content kinds for "Colour by: Kind of content". Files are classified
/// by extension, well-known folders by name, any other folder by the kind holding most of
/// its bytes (see `FileNode.contentKind`).
enum ContentKind: UInt8, CaseIterable, Identifiable {
    case apps = 1, media, documents, code, caches, system, archives, other

    var id: UInt8 { rawValue }

    var title: String {
        switch self {
        case .apps: return "Apps"
        case .media: return "Media"
        case .documents: return "Documents"
        case .code: return "Code & dev"
        case .caches: return "Caches & logs"
        case .system: return "System & libraries"
        case .archives: return "Archives & disk images"
        case .other: return "Other"
        }
    }

    /// Legend label (the legend sits in a narrow row).
    var shortTitle: String {
        switch self {
        case .apps: return "Apps"
        case .media: return "Media"
        case .documents: return "Docs"
        case .code: return "Code"
        case .caches: return "Caches"
        case .system: return "System"
        case .archives: return "Archives"
        case .other: return "Other"
        }
    }

    /// The theme ramp step this kind always takes. Eight kinds, eight steps.
    /// - Gradient (one colour family): by visual weight, "Other" the quietest.
    /// - Multicolour (distinct hues): the kinds that usually fill a disk (system, apps, media,
    ///   code) sit on every other step, so they never get neighbouring hues.
    var step: Int {
        if PaletteStyle.current == .signal {
            switch self {
            case .system: return 0
            case .other: return 1
            case .apps: return 2
            case .documents: return 3
            case .media: return 4
            case .caches: return 5
            case .code: return 6
            case .archives: return 7
            }
        }
        switch self {
        case .media: return 7
        case .code: return 6
        case .apps: return 5
        case .archives: return 4
        case .documents: return 3
        case .caches: return 2
        case .system: return 1
        case .other: return 0
        }
    }

    /// Folders whose name alone says what they are (their own content is not consulted;
    /// what is inside them is still classified on its own).
    private static let byName: [String: ContentKind] = {
        var map: [String: ContentKind] = [:]
        for n in ["Applications"] { map[n] = .apps }
        for n in ["node_modules", ".git", "DerivedData", ".build", "build", "Pods", ".gradle", ".swiftpm",
                  "venv", ".venv", "__pycache__", "site-packages", ".cargo", ".rustup", "bower_components"] { map[n] = .code }
        for n in ["Caches", "Cache", "cache", ".cache", "Logs", "logs", "tmp", "TemporaryItems", "CachedData",
                  "GPUCache", "Code Cache", "DiagnosticReports", ".npm", ".yarn-cache"] { map[n] = .caches }
        for n in ["Library", "System", "usr", "private", "bin", "sbin", "cores", "Frameworks", "PrivateFrameworks"] { map[n] = .system }
        return map
    }()

    private static let byExtension: [String: ContentKind] = {
        var map: [String: ContentKind] = [:]
        func add(_ kind: ContentKind, _ list: String) {
            for ext in list.split(separator: " ") { map[String(ext)] = kind }
        }
        add(.apps, "app appex prefpane saver")
        add(.media, "jpg jpeg png gif heic heif tif tiff bmp webp raw cr2 cr3 nef arw dng psd svg ico " +
                    "mp3 m4a m4b aac wav aif aiff flac ogg opus caf mid midi " +
                    "mp4 mov m4v avi mkv webm mpg mpeg mts m2ts 3gp braw r3d " +
                    "photoslibrary photolibrary aplibrary musiclibrary tvlibrary fcpbundle imovielibrary logicx band")
        add(.documents, "pdf doc docx xls xlsx ppt pptx pages numbers key rtf rtfd txt md markdown csv tsv " +
                        "epub mobi azw azw3 ibooks odt ods odp tex eml emlx mbox")
        add(.code, "swift m mm h c cc cpp hpp js mjs cjs ts tsx jsx py pyc rb go rs java class jar kt kts scala cs php " +
                   "lua sh zsh bash fish pl r sql json yaml yml toml xml html htm css scss sass less vue svelte ipynb " +
                   "o a gradle xcodeproj xcworkspace playground xcassets wasm map " +
                   // Model weights and ML data: developer assets, often the biggest files on a dev disk.
                   "safetensors ckpt pt pth onnx gguf ggml mlmodel mlpackage mlmodelc h5 tflite npy npz parquet")
        add(.caches, "log cache tmp temp crash ips diag")
        add(.system, "dylib framework kext plist bundle plugin component dext so")
        add(.archives, "zip dmg iso tar gz tgz bz2 xz 7z rar pkg mpkg xip sparseimage sparsebundle img cpio lz zst xar ipa " +
                       "vmdk vdi qcow2 hdd utm pvm")
        return map
    }()

    /// Lowercased extension of `name`, or nil (no dot, a leading-dot name, or too long to be one).
    private static func fileExtension(_ name: String) -> String? {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        let ext = name[name.index(after: dot)...]
        guard !ext.isEmpty, ext.count <= 14 else { return nil }
        return ext.lowercased()
    }

    /// The kind of a real node, without the memo. Folders recurse through their children's
    /// (memoised) kinds, so classifying a whole tree once is O(n).
    fileprivate static func classify(_ node: FileNode) -> ContentKind {
        if node.isDirectory {
            if let kind = byName[node.name] { return kind }
            if node.isPackage, let ext = fileExtension(node.name), let kind = byExtension[ext] { return kind }
            var totals = [Int64](repeating: 0, count: Int(ContentKind.other.rawValue) + 1)
            for child in node.children where child.kind == .item && child.size > 0 {
                if let kind = child.contentKind { totals[Int(kind.rawValue)] += child.size }
            }
            var best = ContentKind.other
            var bestBytes: Int64 = 0
            for kind in ContentKind.allCases where totals[Int(kind.rawValue)] > bestBytes {
                best = kind
                bestBytes = totals[Int(kind.rawValue)]
            }
            return best
        }
        if let ext = fileExtension(node.name), let kind = byExtension[ext] { return kind }
        return .other
    }
}

extension FileNode {
    /// What this item is, for "Colour by: Kind of content": by extension for files, by name
    /// for well-known folders, otherwise the kind holding most of a folder's bytes. `nil` for
    /// synthetic (Free/Purgeable/Unseen) nodes. Memoised per node; `removeFromParent` clears
    /// the memo up the chain, and a rescan builds new nodes.
    var contentKind: ContentKind? {
        guard kind == .item else { return nil }
        if let cached = ContentKind(rawValue: contentKindCache) { return cached }
        let kind = ContentKind.classify(self)
        contentKindCache = kind.rawValue
        return kind
    }
}
