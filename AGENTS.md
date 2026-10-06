# AGENTS.md

Guidance for coding agents and contributors working in this repository.

## Project

Discotech is a native macOS disk-space map written in Swift (SwiftUI and AppKit), MIT licensed, with no third-party dependencies.
It scans a drive or folder, shows the result in three views, suggests space that is usually safe to clear, and moves what the user picks to the Trash.
One SwiftPM executable target (`Package.swift`, tools 6.0, Swift 5 language mode, macOS 14+). Building needs Xcode 26 or later.

## Setup, build, run

```sh
swift build                    # debug build
.build/debug/Discotech         # run the debug binary
swift build -c release --arch arm64   # release build, as CI does
./build.sh                     # release build wrapped in build/Discotech.app, ad-hoc signed
```

`./build.sh [debug|release]` accepts `VERSION` and `BUILD_NUMBER` overrides. `scripts/package-release.sh` builds the dmg and zip and is run by the release workflow.

Tests live in `Tests/DiscotechTests` (Swift Testing, `@testable import Discotech`) and run with `swift test`. Verify by building, running the tests and, for visual changes, looking at the app (see Verification).

## Glossary

The UI uses product words; some folders and types still carry older code names.

| Term | Meaning | In code |
| --- | --- | --- |
| Ball | The ring view (sunburst) | `Sources/Discotech/Sunburst/` |
| Layers | One column per folder level | `Sources/Discotech/Columns/` |
| Floor | Bento treemap of blocks sized by space | `Sources/Discotech/Floor/` |
| Crate | Items staged for the Trash (`collect` and `collected` in code) | `Model/AppState.swift`, `UI/CrateView.swift` |
| Findings | Cleanup suggestions, "Safe to clear" and "Review first" | `Model/Findings.swift` |
| Multicolour | Palette style of multi-hue ramps | `PaletteStyle.signal` in `Canvas/PaletteStyle.swift`, ramps in `Canvas/MulticolourThemes.swift` |

## Where things live

| Folder (under `Sources/Discotech/`) | Contents |
| --- | --- |
| `Scanner/` | Directory walking and tree building |
| `Model/` | `FileNode` tree, `AppState`, `Safety`, `TrashCheck`, `Findings`, space accounting |
| `Canvas/` | Themes, palettes, colour modes, size ramp, shared highlight and backdrop |
| `Sunburst/`, `Columns/`, `Floor/` | The Ball, Layers and Floor views; `Sunburst/Palette.swift` decides node colours |
| `UI/` | App shell, sidebar, Crate, Findings views, Settings, Help, `DesignTokens.swift` |
| `scripts/`, `.github/workflows/` | Packaging, site checks, CI, release, Pages |
| `site/`, `docs/` | Static website, and maintainer docs (releasing) |

## Ground rules

- Scan results stay in memory. Never write scan results or scan history to disk.
- The app has no networking. Do not add any.
- Every rule about what may not go in the Crate lives in `Model/Safety.swift`. Check eligibility through `AppState.collectBlockReason`, never by re-implementing a rule in a view.
- Items only go to the Trash from the Crate review window, after the user confirms. Nothing else moves or deletes files.
- Never exercise "Move to Trash" or call `trashCollected` on real data. Test against throwaway folders you created for the purpose.
- User-facing words are Ball, Layers, Floor and Crate.
- Discotech has its own identity. Never name or compare it to other disk-analyzer apps in code, comments, docs or commit messages.
- Colours, spacing, radii and motion come from `UI/DesignTokens.swift` and `Sunburst/Palette.swift`. Do not hard-code them in views.

## Verification

Both builds must finish with no `warning:` lines. CI fails on compiler warnings, and a clean tree builds this way today.

```sh
swift build 2>&1 | grep -c 'warning:'
swift build -c release --arch arm64 2>&1 | grep -c 'warning:'
```

Tests must pass, and the test target must build with no warnings either:

```sh
swift test                                          # all tests, in a few seconds
swift test --enable-code-coverage && scripts/coverage-summary.sh   # per-directory line coverage
swift build --build-tests 2>&1 | grep -c 'warning:'
```

Tests use temp folders under `FileManager.default.temporaryDirectory` only, isolated `UserDefaults` suites, no windows or screenshots, and never move anything to the Trash. See the Testing section of [CONTRIBUTING.md](CONTRIBUTING.md).

Checks CI also runs, which you can run locally (`ci-ok` is the one required check):

```sh
python3 scripts/check-site.py site
for f in build.sh scripts/*.sh; do bash -n "$f"; done
shellcheck build.sh scripts/*.sh && actionlint      # if installed
```

Debug builds read environment variables for screenshots and manual checks. The full list is in the comment above `enum DebugHooks` in `Sources/Discotech/UI/ContentView.swift`; other files add a few more. They do not exist in release builds. Examples:

```sh
# Scan a folder and open the Floor view in dark mode
DISCOTECH_AUTOSCAN=/path/to/scratch/folder DISCOTECH_CANVAS=floor DISCOTECH_APPEARANCE=dark .build/debug/Discotech

# Fixed window size, write a PNG 8 seconds in, then quit
DISCOTECH_AUTOSCAN=/path/to/scratch/folder DISCOTECH_WINDOW=1280x800 DISCOTECH_SNAPSHOTS=8:/tmp/shot.png .build/debug/Discotech

# Colour by kind of content, Layers view
DISCOTECH_AUTOSCAN=/path/to/scratch/folder DISCOTECH_CANVAS=columns DISCOTECH_COLOR_BY=kind .build/debug/Discotech

# Multicolour palette style
DISCOTECH_AUTOSCAN=/path/to/scratch/folder DISCOTECH_PALETTE_STYLE=signal .build/debug/Discotech
```

Use a scratch folder you made. Do not click Move to Trash, even in a debug run.

## Conventions

- Commits and PR titles are Conventional Commits. They drive semantic-release on `main`: `fix:`, `perf:` and `revert:` are a patch, `feat:` a minor, a `!` after the type (`feat!:`, `fix!:`) a major; `docs:`, `refactor:`, `ci:`, `chore:`, `test:` and `build:` release nothing on their own. A CI check rejects other PR titles. Rules and pipeline: [docs/RELEASING.md](docs/RELEASING.md).
- One logical change per commit. Pull requests are squash-merged.
- Do not commit build outputs (`.build/`, `build/`, `dist/`).
- Keep files focused. New files should stay under about 400 lines; several existing views are larger and are not a precedent.
- Put DEBUG-only code in clearly marked `#if DEBUG` blocks, and make sure the release build still compiles.
- Check new UI in light and dark appearance at the 900 x 600 minimum window size.

## More

- [CONTRIBUTING.md](CONTRIBUTING.md): ground rules, adding a Findings rule, pull request checks.
- [README.md](README.md): what the app does, install, build from source.
- [docs/RELEASING.md](docs/RELEASING.md): how releases and the website deploy.
