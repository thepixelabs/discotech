import Foundation

/// Directory extensions that macOS treats as opaque "packages" — shown as a single
/// item in Finder even though they're really a directory tree. Cheap extension-list
/// check rather than an `LSItem`/`NSWorkspace` round-trip per entry (those are far
/// too slow to call millions of times during a scan).
///
/// Not exhaustive by design — anything missing here just shows up as a regular
/// (still fully-scanned) directory instead of a collapsed package.
enum PackageKind {
    static let extensions: Set<String> = [
        "app", "bundle", "framework", "plugin", "kext", "prefpane",
        "qlgenerator", "mdimporter", "xpc", "appex", "systemextension",
        "docset", "playground", "xcodeproj", "xcworkspace", "xcarchive",
        "photoslibrary", "musiclibrary", "tvlibrary", "theater",
        "imovielibrary", "fcpbundle", "logicx", "band", "garageband",
        "rtfd", "saver", "component", "webloc", "download", "sparkleupdate",
    ]

    /// `name` is a bare filename (e.g. "Xcode.app"), not a full path.
    static func isPackage(name: String) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        let ext = name[name.index(after: dot)...]
        guard !ext.isEmpty else { return false }
        return extensions.contains(ext.lowercased())
    }
}
