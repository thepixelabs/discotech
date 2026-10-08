import Foundation

/// One cleanup suggestion: a kind of cache, rebuildable output or large personal item,
/// grouped across the whole tree, plus every matched node so the sidebar can list and
/// select them.
struct Finding: Identifiable {
    /// How sure we are that clearing it is harmless. Decides which group the card is in.
    enum Tier: Int, CaseIterable {
        /// Rebuilt or downloaded again automatically when it's needed.
        case safe
        /// Probably not needed, but personal or not rebuilt: worth a look before adding.
        case review
    }

    let id: String
    let title: String
    /// One calm line on what this is and why it may go — no alarmism, no red.
    let reason: String
    let icon: String
    /// Singular noun for the count line ("23 projects", "6 caches").
    let unitLabel: String
    let tier: Tier
    /// False for findings shown only so the space is visible (the Trash's contents): their
    /// items are refused by `Safety`, so they can't go in the Crate either way.
    let isCollectible: Bool
    /// Largest first, matching the sidebar's own convention for node lists.
    let nodes: [FileNode]

    var totalSize: Int64 { nodes.reduce(0) { $0 + $1.size } }
    var countLabel: String { nodes.count == 1 ? "1 \(unitLabel)" : "\(nodes.count) \(unitLabel)s" }
}

/// Finds cleanup candidates in an already-scanned tree. Pure in-memory work — no disk
/// I/O beyond the small, bounded number of `Safety` checks on nodes it's about to
/// surface (never the whole tree) — so it's safe to run on a background thread right
/// after a scan finishes. Everything comes from names, locations, extensions and sizes.
///
/// **Rule categories**, in priority order (an earlier rule wins a node):
/// 1. *Already in the Trash* (informational: `Safety` refuses these, so no Add button).
/// 2. *Known folders, safe*: package manager caches (Homebrew, npm, Yarn, pnpm, pip,
///    Cargo, Go, CocoaPods, Gradle), browser caches (Chromium-family profiles, Firefox),
///    desktop app web caches (any Application Support folder with Chromium's `GPUCache` /
///    `Code Cache` signature), Xcode build data, device support files and previews,
///    Simulator and Gradle caches, crash reports.
/// 3. *Known folders, review*: Xcode archives, simulators, iPhone/iPad backups, Docker
///    Desktop data, downloaded AI models, conda environments, Android emulator images,
///    Mail attachment copies, VirtualBox machines, installers and archives in Downloads.
/// 4. *Catch-alls*: the rest of `~/Library/Caches` and `~/Library/Logs`.
/// 5. *One tree walk* (explicit stack, no recursion): marker-pair dev output (a folder
///    name plus a sibling marker file — `node_modules` + `package.json`), Python virtual
///    environments by content (any folder holding `pyvenv.cfg`: Safe beside a recipe
///    such as `requirements.txt` or `uv.lock`, Review with none), then by extension and
///    size: virtual machine bundles, disk images, large videos in Movies/Downloads/Desktop,
///    and the largest files left over.
///
/// **Never in two findings:** a node already claimed, or inside a claimed node, is
/// dropped; a folder that *holds* a claimed node is split into its other children (so
/// `~/Library/Caches/Google` lists everything but the Chrome cache claimed above). The
/// walk never descends into a claimed node, a whole-folder rule's folder, or a package
/// (bundles are one thing: nothing inside one is surfaced on its own).
///
/// **Not done:** age-based findings ("untouched for a year") need the scanner to record
/// modification dates; duplicates need content hashing, and the scanner never reads file
/// contents. Leftovers from deleted apps need more signals than a name.
enum Findings {
    static func find(in root: FileNode) -> [Finding] {
        var run = Run(root: root)
        run.apply(trashRule)
        for rule in safePathRules { run.apply(rule) }
        run.applyBrowserCaches()
        run.applyAppWebCaches()
        for rule in reviewPathRules { run.apply(rule) }
        for rule in catchAllRules { run.apply(rule) }
        run.walk()
        return run.findings()
    }

    // MARK: - What a finding says

    private struct Spec {
        let id: String
        let title: String
        let reason: String
        let icon: String
        let unitLabel: String
        var tier: Finding.Tier = .safe
        var isCollectible = true
    }

    private static let trashRule = PathRule(
        spec: Spec(id: "trash", title: "Already in the Trash",
                   reason: "Items you’ve already moved to the Trash. They take up space until it’s emptied.",
                   icon: "trash", unitLabel: "item", isCollectible: false),
        paths: [".Trash"], pick: .children)

    // MARK: - Known folders

    private struct PathRule {
        let spec: Spec
        /// Relative to the home folder, or absolute when they start with "/".
        let paths: [String]
        let pick: Pick
    }

    private enum Pick {
        /// The folder itself is one item.
        case itself
        /// Each child is one item; the walk skips the folder (it's fully accounted for).
        case children
        /// Each child folder is one item (loose files such as a `device_set.plist` stay).
        case childFolders
        /// Each child with one of these lowercased extensions; the walk still visits the rest.
        case childrenWithExtension(Set<String>)
    }

    private static let safePathRules: [PathRule] = [
        PathRule(spec: Spec(id: "package-caches", title: "Package caches",
                            reason: "Downloaded again automatically the next time a package is installed.",
                            icon: "tray.2", unitLabel: "cache"),
                 paths: ["Library/Caches/Homebrew", ".npm/_cacache", "Library/Caches/Yarn", ".yarn/berry/cache",
                         "Library/pnpm/store", ".local/share/pnpm/store", "Library/Caches/pip",
                         ".cargo/registry", ".cargo/git", "go/pkg/mod/cache", "Library/Caches/go-build",
                         "Library/Caches/CocoaPods", ".gradle/wrapper/dists"],
                 pick: .itself),
        PathRule(spec: Spec(id: "xcode-derived-data", title: "Xcode build data",
                            reason: "Rebuilt automatically the next time you build in Xcode.",
                            icon: "hammer", unitLabel: "project"),
                 paths: ["Library/Developer/Xcode/DerivedData"], pick: .children),
        PathRule(spec: Spec(id: "xcode-device-support", title: "Xcode device support files",
                            reason: "Xcode copies these from your device again the next time you connect it.",
                            icon: "iphone", unitLabel: "OS version"),
                 paths: ["Library/Developer/Xcode/iOS DeviceSupport", "Library/Developer/Xcode/watchOS DeviceSupport",
                         "Library/Developer/Xcode/tvOS DeviceSupport"],
                 pick: .childFolders),
        PathRule(spec: Spec(id: "xcode-previews", title: "Xcode preview simulators",
                            reason: "Xcode sets these up again the next time you open a preview.",
                            icon: "iphone", unitLabel: "folder"),
                 paths: ["Library/Developer/Xcode/UserData/Previews"], pick: .itself),
        PathRule(spec: Spec(id: "simulator-caches", title: "iOS Simulator caches",
                            reason: "Redownloaded and rebuilt automatically by Simulator.",
                            icon: "tray", unitLabel: "cache"),
                 paths: ["Library/Developer/CoreSimulator/Caches"], pick: .children),
        PathRule(spec: Spec(id: "gradle-caches", title: "Gradle caches",
                            reason: "Redownloaded automatically the next time Gradle needs them.",
                            icon: "tray", unitLabel: "cache"),
                 paths: [".gradle/caches"], pick: .children),
        PathRule(spec: Spec(id: "crash-reports", title: "Crash reports",
                            reason: "Reports from past app crashes, only useful when troubleshooting.",
                            icon: "doc.text.magnifyingglass", unitLabel: "report"),
                 paths: ["Library/Logs/DiagnosticReports"], pick: .children),
    ]

    private static let reviewPathRules: [PathRule] = [
        PathRule(spec: Spec(id: "xcode-archives", title: "Xcode archives",
                            reason: "App builds you archived. Keep any you may resubmit or need for reading crash reports.",
                            icon: "archivebox", unitLabel: "folder", tier: .review),
                 paths: ["Library/Developer/Xcode/Archives"], pick: .children),
        PathRule(spec: Spec(id: "simulator-devices", title: "Simulators",
                            reason: "Each one keeps its installed apps and data. Xcode can make new ones, but not what was on them.",
                            icon: "ipad.and.iphone", unitLabel: "simulator", tier: .review),
                 paths: ["Library/Developer/CoreSimulator/Devices"], pick: .childFolders),
        PathRule(spec: Spec(id: "device-backups", title: "iPhone and iPad backups",
                            reason: "Make sure you have a newer backup, here or in iCloud, before removing one.",
                            icon: "externaldrive", unitLabel: "backup", tier: .review),
                 paths: ["Library/Application Support/MobileSync/Backup"], pick: .childFolders),
        PathRule(spec: Spec(id: "docker-data", title: "Docker Desktop data",
                            reason: "Your Docker images, containers and volumes. Docker Desktop can clean these up for you too.",
                            icon: "cube.box", unitLabel: "folder", tier: .review),
                 paths: ["Library/Containers/com.docker.docker"], pick: .itself),
        PathRule(spec: Spec(id: "ai-models", title: "Downloaded AI models",
                            reason: "They can be downloaded again, but they’re large and take a while to fetch.",
                            icon: "cpu", unitLabel: "folder", tier: .review),
                 paths: [".ollama/models", ".cache/huggingface/hub", ".cache/huggingface/datasets", ".cache/torch/hub",
                         ".lmstudio/models", ".cache/lm-studio/models"],
                 pick: .itself),
        PathRule(spec: Spec(id: "conda-envs", title: "Conda environments",
                            reason: "Each can be recreated, but only if you still have its package list.",
                            icon: "leaf", unitLabel: "environment", tier: .review),
                 paths: ["miniconda3/envs", "anaconda3/envs", "miniforge3/envs", "mambaforge/envs", ".conda/envs"],
                 pick: .childFolders),
        PathRule(spec: androidSpec,
                 paths: ["Library/Android/sdk/system-images"], pick: .childFolders),
        // Whole: each emulator is a `.avd` folder plus a `.ini` file that points at it.
        PathRule(spec: androidSpec, paths: [".android/avd"], pick: .itself),
        PathRule(spec: Spec(id: "mail-downloads", title: "Mail attachment copies",
                            reason: "Copies of attachments you opened in Mail. The originals stay with the messages.",
                            icon: "paperclip", unitLabel: "item", tier: .review),
                 paths: ["Library/Containers/com.apple.mail/Data/Library/Mail Downloads"], pick: .children),
        PathRule(spec: vmSpec, paths: ["VirtualBox VMs"], pick: .childFolders),
        PathRule(spec: Spec(id: "downloads-installers", title: "Installers and archives",
                            reason: "In your Downloads folder. Once installed or unpacked, they’re usually not needed.",
                            icon: "doc.zipper", unitLabel: "file", tier: .review),
                 paths: ["Downloads"],
                 pick: .childrenWithExtension(["dmg", "pkg", "mpkg", "iso", "zip", "xip", "tar", "tgz", "gz",
                                               "bz2", "xz", "7z", "rar", "ipa"])),
    ]

    /// Run last among the known folders, so everything more specific inside them
    /// (Homebrew's cache, crash reports, …) has already been claimed and is left out.
    private static let catchAllRules: [PathRule] = [
        PathRule(spec: Spec(id: "user-caches", title: "App & system caches",
                            reason: "macOS and your apps rebuild these automatically as they’re needed.",
                            icon: "tray", unitLabel: "cache"),
                 paths: ["Library/Caches"], pick: .children),
        PathRule(spec: Spec(id: "user-logs", title: "Logs",
                            reason: "Apps start new logs as they run. Old ones only help with troubleshooting.",
                            icon: "doc.text", unitLabel: "log"),
                 paths: ["Library/Logs"], pick: .children),
    ]

    // MARK: - Web caches (browsers and desktop apps built on Chromium)

    private static let browserSpec = Spec(
        id: "browser-caches", title: "Browser caches",
        reason: "Filled again as you browse. Quit the browser before you empty the Crate.",
        icon: "globe", unitLabel: "cache")

    private static let appWebSpec = Spec(
        id: "app-web-caches", title: "Desktop app web caches",
        reason: "Apps built on web technology refill these as they run. Quit the app first.",
        icon: "macwindow", unitLabel: "cache")

    /// Browser caches macOS-style: whole folders under `~/Library/Caches`.
    private static let browserCacheFolders = [
        "Library/Caches/Google/Chrome", "Library/Caches/Microsoft Edge", "Library/Caches/BraveSoftware/Brave-Browser",
        "Library/Caches/Chromium", "Library/Caches/Vivaldi", "Library/Caches/Firefox",
    ]

    /// Chromium-family "User Data" folders; their profiles hold more caches.
    private static let chromiumDataFolders = [
        "Library/Application Support/Google/Chrome", "Library/Application Support/Microsoft Edge",
        "Library/Application Support/BraveSoftware/Brave-Browser", "Library/Application Support/Arc/User Data",
        "Library/Application Support/Chromium", "Library/Application Support/Vivaldi",
    ]

    /// Shader caches shared by every profile of a Chromium browser.
    private static let chromiumSharedCaches = ["GrShaderCache", "GraphiteDawnCache", "ShaderCache"]

    /// Per-profile (or per-app, for desktop apps) Chromium caches, as paths inside it.
    private static let chromiumProfileCaches = [
        "Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache",
        "Service Worker/CacheStorage", "Service Worker/ScriptCache",
    ]

    /// App data folders checked for the Chromium signature beyond `Application Support`'s
    /// direct children (one level deeper, or inside an app's sandbox).
    private static let extraAppDataFolders = [
        "Library/Application Support/Microsoft/Teams",
        "Library/Containers/com.tinyspeck.slackmacgap/Data/Library/Application Support/Slack",
    ]

    // MARK: - Tree walk: marker-pair dev output

    private struct DevOutputRule {
        let spec: Spec
        /// Lowercased folder names this rule matches.
        let folderNames: Set<String>
        /// Lowercased sibling names that confirm the match. Empty means the folder name
        /// alone is enough (`__pycache__`).
        var markerNames: Set<String> = []
        /// Lowercased sibling suffixes that also confirm it (`.tf`).
        var markerSuffixes: [String] = []
        /// Every marker must be present, not just one (Unity's `Assets` + `ProjectSettings`).
        var requiresAllMarkers = false
    }

    private static func devRule(_ id: String, _ title: String, _ reason: String, _ icon: String,
                                folders: Set<String>, markers: Set<String> = [], suffixes: [String] = [],
                                requiresAll: Bool = false) -> DevOutputRule {
        DevOutputRule(spec: Spec(id: id, title: title, reason: reason, icon: icon, unitLabel: "project"),
                      folderNames: folders, markerNames: markers, markerSuffixes: suffixes,
                      requiresAllMarkers: requiresAll)
    }

    private static let rebuilt = "Rebuilt automatically the next time you build the project."

    private static let devOutputRules: [DevOutputRule] = [
        devRule("rust-target", "Rust build output", rebuilt, "hammer",
                folders: ["target"], markers: ["cargo.toml"]),
        devRule("maven-target", "Maven build output", rebuilt, "hammer",
                folders: ["target"], markers: ["pom.xml"]),
        devRule("node-modules", "Node.js dependencies",
                "Reinstalled automatically the next time you run npm, yarn or pnpm install.", "shippingbox",
                folders: ["node_modules"], markers: ["package.json"]),
        // Python virtual environments are matched by content, not name: see
        // `pythonEnvironmentSpec(for:in:parentIsHome:)`.
        devRule("native-build", "Build output", rebuilt, "hammer",
                folders: ["build"], markers: ["build.gradle", "build.gradle.kts", "cmakelists.txt", "pubspec.yaml"]),
        devRule("swiftpm-build", "Swift package build output",
                "Rebuilt automatically the next time you build the package.", "hammer",
                folders: [".build"], markers: ["package.swift"]),
        devRule("pods", "CocoaPods dependencies",
                "Reinstalled automatically the next time you run pod install.", "shippingbox",
                folders: ["pods"], markers: ["podfile"]),
        devRule("next-build", "Next.js build output",
                "Rebuilt automatically the next time you run next build.", "hammer",
                folders: [".next"], markers: ["package.json"]),
        devRule("js-build-caches", "JavaScript build caches",
                "Regenerated automatically the next time you build or start the dev server.", "tray",
                folders: [".turbo", ".parcel-cache", ".svelte-kit", ".nuxt", ".cache"], markers: ["package.json"]),
        devRule("js-coverage", "Test coverage reports",
                "Written again the next time you run your tests with coverage.", "chart.bar.xaxis",
                folders: ["coverage"], markers: ["package.json"]),
        devRule("gradle-project", "Gradle project caches",
                "Rebuilt automatically the next time you run Gradle.", "tray",
                folders: [".gradle"],
                markers: ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts", "gradlew"]),
        devRule("dart-tool", "Dart and Flutter tool caches",
                "Regenerated the next time you run flutter pub get or build.", "tray",
                folders: [".dart_tool"], markers: ["pubspec.yaml"]),
        devRule("unity-library", "Unity project caches",
                "Unity rebuilds this the next time you open the project, which can take a while.", "gamecontroller",
                folders: ["library"], markers: ["assets", "projectsettings"], requiresAll: true),
        devRule("terraform", "Terraform providers",
                "Downloaded again the next time you run terraform init.", "cloud",
                folders: [".terraform"], markers: [".terraform.lock.hcl"], suffixes: [".tf"]),
        devRule("pycache", "Python bytecode caches",
                "Regenerated automatically the next time you run the code.", "leaf",
                folders: ["__pycache__"]),
        devRule("python-tool-caches", "Python tool caches",
                "Recreated automatically the next time the tool runs.", "leaf",
                folders: [".pytest_cache", ".mypy_cache", ".ruff_cache", ".tox"]),
        // Deliberately left out:
        // - dist/: often intentionally-committed output (a published package, a site to
        //   deploy) rather than something purely rebuilt by a tool; name+sibling alone
        //   can't tell the two apart.
        // - vendor/: frequently committed, hand-patched dependencies (Go, PHP, Ruby).
        // - .swiftpm/: can hold shared Xcode schemes people commit and edit by hand.
    ]

    /// Folder name → the rules that may claim it, so the walk does one hash lookup per
    /// folder instead of lowercasing every name. Keyed by the spellings tools actually
    /// write: lowercase, and capitalized (`Pods`, `Library`, `Build`).
    private static let devOutputRulesByName: [String: [DevOutputRule]] = {
        var map: [String: [DevOutputRule]] = [:]
        for rule in devOutputRules {
            for name in rule.folderNames {
                for spelling in Set([name, name.prefix(1).uppercased() + name.dropFirst()]) {
                    map[spelling, default: []].append(rule)
                }
            }
        }
        return map
    }()

    private static func matchingDevOutputRule(for node: FileNode) -> DevOutputRule? {
        guard let rules = devOutputRulesByName[node.name] else { return nil }
        for rule in rules {
            if rule.markerNames.isEmpty && rule.markerSuffixes.isEmpty { return rule }
            guard let parent = node.parent else { continue }
            let siblings = parent.children.lazy.map { $0.name.lowercased() }
            if rule.requiresAllMarkers {
                if rule.markerNames.allSatisfy({ marker in siblings.contains(marker) }) { return rule }
            } else if siblings.contains(where: { name in
                rule.markerNames.contains(name) || rule.markerSuffixes.contains { name.hasSuffix($0) }
            }) {
                return rule
            }
        }
        return nil
    }

    // MARK: - Tree walk: Python virtual environments

    private static let pythonEnvSpec = Spec(
        id: "python-venv", title: "Python virtual environments",
        reason: "Recreated automatically the next time you set up the project.",
        icon: "leaf", unitLabel: "environment")
    private static let pythonEnvNoRecipeSpec = Spec(
        id: "python-venv-no-recipe", title: "Python environments with no requirements file",
        reason: "Nothing next to it lists what is installed, so check before clearing it.",
        icon: "leaf", unitLabel: "environment", tier: .review)

    /// Names that count as an environment even without `pyvenv.cfg` inside (one that was
    /// half deleted), but only with a recipe beside them.
    private static let pythonEnvNames: Set<String> = [".venv", "venv", "Venv"]

    /// Lowercased names of files that list a project's Python packages, so an environment
    /// beside one can be set up again. Any `requirements*.txt` counts too.
    private static let pythonRecipeNames: Set<String> = [
        "pyproject.toml", "requirements.txt", "setup.py", "setup.cfg", "pipfile", "pipfile.lock",
        "poetry.lock", "uv.lock", "environment.yml", "environment.yaml", "tox.ini",
    ]

    private static func isPythonRecipe(_ name: String) -> Bool {
        let lower = name.lowercased()
        return pythonRecipeNames.contains(lower) || (lower.hasPrefix("requirements") && lower.hasSuffix(".txt"))
    }

    /// `venv`, `virtualenv` and `uv` all write `pyvenv.cfg` at the top of an environment,
    /// so that file, not the folder's name, makes `node` one. A conda environment
    /// (`conda-meta`) is left to the conda rule. Safe when a recipe sits beside it; Review
    /// when nothing does, since then only the environment knows what was installed. The
    /// home folder is never a project, so a recipe there doesn't count.
    private static func pythonEnvironmentSpec(for node: FileNode, in parent: FileNode, parentIsHome: Bool) -> Spec? {
        let byContent = node.children.contains { $0.name == "pyvenv.cfg" }
            && !node.children.contains { $0.name == "conda-meta" }
        guard byContent || pythonEnvNames.contains(node.name) else { return nil }
        if !parentIsHome, parent.children.contains(where: { !$0.isDirectory && isPythonRecipe($0.name) }) {
            return pythonEnvSpec
        }
        return byContent ? pythonEnvNoRecipeSpec : nil
    }

    // MARK: - Tree walk: extension and size

    private static let androidSpec = Spec(
        id: "android-emulators", title: "Android emulator images",
        reason: "Android Studio can download system images again; emulators keep their own data.",
        icon: "apps.iphone", unitLabel: "item", tier: .review)
    private static let vmSpec = Spec(
        id: "virtual-machines", title: "Virtual machines",
        reason: "Everything inside the machine goes with it. Keep any you still use.",
        icon: "desktopcomputer", unitLabel: "virtual machine", tier: .review)
    private static let diskImageSpec = Spec(
        id: "disk-images", title: "Disk images",
        reason: "Installers and archived disks. Keep any you made yourself as a backup.",
        icon: "opticaldiscdrive", unitLabel: "image", tier: .review)
    private static let videoSpec = Spec(
        id: "large-videos", title: "Large videos",
        reason: "Videos over 500 MB in Movies, Downloads and Desktop. Only you know which to keep.",
        icon: "film", unitLabel: "video", tier: .review)
    private static let largestSpec = Spec(
        id: "largest-files", title: "Largest files",
        reason: "Your biggest files over 1 GB that aren’t in another group. Worth a look.",
        icon: "doc", unitLabel: "file", tier: .review)

    private static let vmExtensions: Set<String> = ["pvm", "vmwarevm", "utm"]
    private static let diskImageExtensions: Set<String> = ["dmg", "iso", "sparseimage", "sparsebundle"]
    private static let videoExtensions: Set<String> = ["mov", "mp4", "mkv", "avi", "m4v"]

    private static let mb: Int64 = 1 << 20
    private static let gb: Int64 = 1 << 30
    private static let minDiskImage = 200 * mb
    private static let minVideo = 500 * mb
    private static let minLargeFile = gb
    /// Below this a folder isn't checked for a VM or sparse bundle extension at all.
    private static let minBundleFolder = 50 * mb
    /// A finding whose items add up to less than this is dropped, so the list only holds
    /// suggestions worth acting on. Applied once, in `Run.findings()`, so every view and
    /// total sees the same list. Binary units, like the thresholds above.
    static let minFindingSize = 50 * mb
    private static let maxVideos = 50
    private static let maxLargestFiles = 25

    /// Home-relative folders whose files are surfaced as videos.
    private static let mediaFolders = ["Movies", "Downloads", "Desktop"]

    /// Never walked: macOS-owned trees (`Safety` refuses them anyway, so walking them is
    /// wasted time on a whole-disk scan), and Simulator runtimes, which are managed from
    /// Xcode's Platforms settings — their images are mounted while in use.
    private static let walkExclusions = [
        "/System", "/usr", "/bin", "/sbin", "/cores", "/dev", "/private/var", "/Library/Apple",
        "/Library/Developer/CoreSimulator",
    ]

    private static func fileExtension(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }

    // MARK: - One run

    private struct Run {
        let root: FileNode
        let home = NSHomeDirectory()
        /// Spec order of first appearance, and each finding's nodes.
        private var specs: [Spec] = []
        private var buckets: [String: [FileNode]] = [:]
        /// Nodes already in a finding.
        private var claimed = Set<ObjectIdentifier>()
        /// Ancestors of claimed nodes: taking one of these means taking its other children.
        private var holdsClaimed = Set<ObjectIdentifier>()
        /// Folders the walk doesn't enter.
        private var walkSkip = Set<ObjectIdentifier>()

        init(root: FileNode) { self.root = root }

        /// Walks down from `root` by path component, the same way `AppState.node(atPath:)`
        /// resolves a dropped path — `root` may be a whole volume or an arbitrary folder,
        /// so most known folders simply won't be under it, which is fine.
        func node(at path: String) -> FileNode? {
            let target = path.hasPrefix("/") ? path : home + "/" + path
            let rootPath = root.path
            if target == rootPath { return root }
            let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            guard target.hasPrefix(prefix) else { return nil }
            var node = root
            for component in target.dropFirst(prefix.count).split(separator: "/") {
                guard let next = node.children.first(where: { $0.name == component }) else { return nil }
                node = next
            }
            return node
        }

        /// Adds `candidate` to `spec`'s finding unless it, or an ancestor, is already in
        /// one. If it holds something already claimed, its other children go in instead.
        /// Returns how many nodes went in.
        @discardableResult
        mutating func take(_ candidate: FileNode, as spec: Spec) -> Int {
            var ancestor = candidate.parent
            while let current = ancestor {
                if claimed.contains(ObjectIdentifier(current)) { return 0 }
                ancestor = current.parent
            }
            var added = 0
            var pending = [candidate]
            while let node = pending.popLast() {
                let id = ObjectIdentifier(node)
                guard !node.isSynthetic, !claimed.contains(id) else { continue }
                // The scanned folder itself can't go in the Crate: offer what's inside.
                if holdsClaimed.contains(id) || node === root { pending.append(contentsOf: node.children); continue }
                // Informational findings list what Safety refuses (that's why they can't
                // be collected); everything else must pass it.
                if spec.isCollectible, Safety.protectionReason(for: node) != nil { continue }
                claim(node)
                if buckets[spec.id] == nil { specs.append(spec) }
                buckets[spec.id, default: []].append(node)
                added += 1
            }
            return added
        }

        private mutating func claim(_ node: FileNode) {
            claimed.insert(ObjectIdentifier(node))
            var parent = node.parent
            while let current = parent, holdsClaimed.insert(ObjectIdentifier(current)).inserted {
                parent = current.parent
            }
        }

        mutating func apply(_ rule: PathRule) {
            for path in rule.paths {
                guard let folder = node(at: path) else { continue }
                switch rule.pick {
                case .itself:
                    take(folder, as: rule.spec)
                case .children, .childFolders:
                    guard folder.isDirectory else { continue }
                    walkSkip.insert(ObjectIdentifier(folder))
                    var foldersOnly = false
                    if case .childFolders = rule.pick { foldersOnly = true }
                    for child in folder.children where !foldersOnly || child.isDirectory {
                        take(child, as: rule.spec)
                    }
                case .childrenWithExtension(let extensions):
                    for child in folder.children where extensions.contains(fileExtension(child.name)) {
                        take(child, as: rule.spec)
                    }
                }
            }
        }

        mutating func applyBrowserCaches() {
            for path in browserCacheFolders {
                if let folder = node(at: path) { take(folder, as: browserSpec) }
            }
            for path in chromiumDataFolders {
                guard let data = node(at: path), data.isDirectory else { continue }
                for name in chromiumSharedCaches {
                    if let cache = data.child(name), cache.isDirectory { take(cache, as: browserSpec) }
                }
                for profile in data.children where profile.isDirectory && Self.isProfile(profile.name) {
                    takeWebCaches(in: profile, as: browserSpec)
                }
            }
        }

        /// Desktop apps built on Chromium (chat apps, editors, …) keep the same cache
        /// folders a browser profile does. `GPUCache` / `Code Cache` are Chromium's own
        /// names, so their presence is the signature — no list of apps to keep current.
        mutating func applyAppWebCaches() {
            var candidates = node(at: "Library/Application Support")?.children ?? []
            candidates += extraAppDataFolders.compactMap { node(at: $0) }
            for app in candidates where app.isDirectory {
                guard app.child("GPUCache") != nil || app.child("Code Cache") != nil else { continue }
                takeWebCaches(in: app, as: appWebSpec)
            }
        }

        private mutating func takeWebCaches(in folder: FileNode, as spec: Spec) {
            for path in chromiumProfileCaches {
                var node: FileNode? = folder
                for component in path.split(separator: "/") { node = node?.child(String(component)) }
                if let node, node.isDirectory { take(node, as: spec) }
            }
        }

        private static func isProfile(_ name: String) -> Bool {
            name == "Default" || name.hasPrefix("Profile ") || name == "Guest Profile" || name == "System Profile"
        }

        /// One explicit-stack pass over the whole tree (no recursion, so depth is never a
        /// stack-overflow risk on a real filesystem).
        mutating func walk() {
            for path in walkExclusions {
                if let excluded = node(at: path) { walkSkip.insert(ObjectIdentifier(excluded)) }
            }
            let mediaRoots = Set(mediaFolders.compactMap { node(at: $0) }.map(ObjectIdentifier.init))
            let homeNode = node(at: home)

            var videos: [FileNode] = []
            var diskImages: [FileNode] = []
            var bigFiles: [FileNode] = []

            // Folders only on the stack; files are judged in their parent's loop, and
            // almost all of them stop at the size check before any string work.
            let noEntry = claimed.union(walkSkip)
            var stack: [(node: FileNode, inMedia: Bool)] = noEntry.contains(ObjectIdentifier(root)) ? [] : [(root, false)]
            while let item = stack.popLast() {
                let folder = item.node
                let inMedia = item.inMedia || mediaRoots.contains(ObjectIdentifier(folder))
                for node in folder.children {
                    if !node.isDirectory {
                        guard node.size >= minDiskImage, node.hardLink != .secondary, !node.isSynthetic,
                              !claimed.contains(ObjectIdentifier(node)) else { continue }
                        let ext = fileExtension(node.name)
                        if inMedia, node.size >= minVideo, videoExtensions.contains(ext) {
                            videos.append(node)
                        } else if diskImageExtensions.contains(ext) {
                            diskImages.append(node)
                        } else if node.size >= minLargeFile {
                            bigFiles.append(node)
                        }
                        continue
                    }
                    let id = ObjectIdentifier(node)
                    if node.isPackage || node.isSynthetic || noEntry.contains(id) { continue } // a bundle is one thing
                    if !holdsClaimed.contains(id) {
                        // A project is never the home folder itself (`~/.cache`, `~/Library`).
                        let parentIsHome = folder === homeNode
                        if !parentIsHome, let rule = matchingDevOutputRule(for: node) {
                            take(node, as: rule.spec)
                            continue // never descend into a matched folder, even one Safety refused
                        }
                        if let spec = pythonEnvironmentSpec(for: node, in: folder, parentIsHome: parentIsHome) {
                            take(node, as: spec)
                            continue
                        }
                        if node.size >= minBundleFolder {
                            let ext = fileExtension(node.name)
                            if vmExtensions.contains(ext) { take(node, as: vmSpec); continue }
                            if ext == "sparsebundle" { diskImages.append(node); continue }
                        }
                    }
                    stack.append((node, inMedia))
                }
            }

            for video in videos.sorted(by: { $0.size > $1.size }) where count(of: videoSpec) < maxVideos {
                take(video, as: videoSpec)
            }
            for image in diskImages where image.size >= minDiskImage { take(image, as: diskImageSpec) }
            for file in bigFiles.sorted(by: { $0.size > $1.size }) where count(of: largestSpec) < maxLargestFiles {
                take(file, as: largestSpec)
            }
        }

        private func count(of spec: Spec) -> Int { buckets[spec.id]?.count ?? 0 }

        /// Safe first, then review; largest first within each.
        func findings() -> [Finding] {
            specs.compactMap { spec -> Finding? in
                guard let nodes = buckets[spec.id] else { return nil }
                // A finding too small to matter (including one that frees nothing, such as an
                // empty `.cache`) is only noise.
                guard nodes.reduce(0, { $0 + $1.size }) >= minFindingSize else { return nil }
                return Finding(id: spec.id, title: spec.title, reason: spec.reason, icon: spec.icon,
                               unitLabel: spec.unitLabel, tier: spec.tier, isCollectible: spec.isCollectible,
                               nodes: nodes.sorted { $0.size > $1.size })
            }
            .sorted { a, b in
                a.tier != b.tier ? a.tier.rawValue < b.tier.rawValue : a.totalSize > b.totalSize
            }
        }
    }
}

private extension FileNode {
    func child(_ name: String) -> FileNode? { children.first { $0.name == name } }
}
