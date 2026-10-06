# Contributing to Discotech

Thanks for helping. Discotech is a native macOS app (Swift, SwiftUI and AppKit) with no
third-party dependencies, released under the [MIT license](LICENSE).

## Build and run

You need Xcode 26 or later (the macOS 26 SDK). The app itself runs on macOS 14 or later.

```sh
swift build                 # debug build
.build/debug/Discotech      # run it

./build.sh                  # release build, wrapped in build/Discotech.app (Apple silicon)
```

Debug builds read a few environment variables that help with manual testing and
screenshots, for example `DISCOTECH_AUTOSCAN=/some/folder`, `DISCOTECH_CANVAS=ball|columns|floor`,
`DISCOTECH_APPEARANCE=light|dark` and `DISCOTECH_SNAPSHOTS=5:/tmp/shot.png`. The full list
is at the top of `DebugHooks` in `Sources/Discotech/UI/ContentView.swift`. None of them
exist in release builds.

## Testing

```sh
swift test                                   # the whole suite, a few seconds
swift test --filter SafetyProtectionTests    # one suite
swift test --enable-code-coverage
scripts/coverage-summary.sh [threshold]      # line coverage per source directory; non-zero below the threshold
```

`scripts/coverage-summary.sh` wraps `xcrun llvm-cov export` on
`.build/debug/DiscotechPackageTests.xctest/Contents/MacOS/DiscotechPackageTests` with
`.build/debug/codecov/default.profdata` (`swift build --show-bin-path` gives the folder). It prints
every directory and gates `Model`, `Scanner`, `Legal` and `Canvas` (set `COVERAGE_GATE_DIRS` to change that).
The SwiftUI and AppKit views are not unit-tested, so their directories read low.

Tests live in `Tests/DiscotechTests`, one file per area, with the shared helpers (in-memory
`FileNode` builders, the temp-folder fixture, isolated settings, wait helpers) in `TestSupport.swift`.
They use Swift Testing (`import Testing`, `@Test`, `#expect`) and import the app with `@testable import Discotech`.

Rules every test follows:

- **Temp folders only.** Real files go in a `TempTree` (`withTempTree`) under the system temporary
  directory, which removes itself, including permission and `uchg` changes. Never touch anything else.
- **Never trash.** No test calls `trashCollected`, `FileManager.trashItem` or clicks "Move to Trash".
  Trash runs are tested through `TrashSession`'s `runner` stand-in.
- **No screenshots, windows or network.** Tests that need a view's logic test the layout or model type behind it.
- **Isolated settings.** Use `withIsolatedDefaults` (a `UserDefaults(suiteName:)` that is removed afterwards)
  and pass it to `TermsStore`, `ThemeStore`, `ColorModeStore` and the `initial(defaults:environment:)` helpers.
  Anything that changes the process-wide look goes in the `GlobalState` suite, which runs serialized and puts
  everything back.
- **No sleeping.** Wait on a published value (`awaitValue`), never on a fixed delay.
- **Fast and deterministic.** The suite stays well under 30 seconds and each test under 2.
- A test for a real bug that is not fixed yet uses `withKnownIssue("what is wrong")`, so it fails the day the bug is fixed.

## Where things live

| Area | Location |
| --- | --- |
| Scanner | `Sources/Discotech/Scanner/` |
| Tree, Crate, safety rules, Findings | `Sources/Discotech/Model/` |
| Ball, Layers and Floor | `Sunburst/`, `Columns/`, `Floor/` |
| App shell, design tokens | `Sources/Discotech/UI/` (tokens in `DesignTokens.swift`) |
| Node colors | `Sources/Discotech/Sunburst/Palette.swift` (which ramp step a node takes, per the "Colour by" setting in `Canvas/ColorMode.swift`; size steps in `Canvas/SizeRamp.swift`) `Canvas/PaletteSchemes.swift` (the Gradient themes' light and dark ramps, pale to strong) and `Canvas/MulticolourThemes.swift` (the Multicolour palette style: six multi-hue ramps such as green to red) |

## Ground rules

- **Scan results stay in memory.** Never write scan results or scan history to disk,
  and don't add networking. These are product promises, not implementation details.
- **Safety rules live in one place.** Anything about what may or may not go in the
  Crate belongs in `Model/Safety.swift`; always check eligibility through
  `AppState.collectBlockReason`.
- **Test the Crate on throwaway data.** When you work on anything near "Move to Trash",
  scan a scratch folder you created for the purpose, never real files.
- **Use the tokens.** Colors, spacing, radii and motion come from `DesignTokens.swift`
  and node colors from `Palette`; don't hard-code values in views.
- **Every screen in both appearances.** Check light and dark mode, and Reduce Motion,
  Increase Contrast and Reduce Transparency, at the 900 x 600 minimum window size.
- **Discotech has its own identity.** Don't name or imitate other disk tools in code,
  comments, copy or commit messages.

## Adding a Findings rule

Findings rules are entries in `devOutputRules` (or `knownFolders`) in
`Model/Findings.swift`: a folder name, the sibling file that proves the folder is
rebuildable, and a one-line reason. Only add a rule when the folder is truly recreated
by a tool; if name and marker can't tell a build output from something a person made,
leave it out.

## Pull requests

Keep each pull request focused on one change and say how you tested it (what you
scanned, which views and appearances you checked). The pull request template has the
checklist. Run `swift test` first; a change to logic in `Model/`, `Scanner/`, `Canvas/` or `Legal/` comes with a test.

**Title it as a Conventional Commit**, for example `fix: Layers labels overlap at 900 px`
or `feat(floor): tile labels`. Pull requests are squash-merged, so the title becomes the
commit on `main`, and that decides the next release: `fix:` ships a patch, `feat:` a minor
version, `feat!:` a major one (put the `!` in the title; the PR description is not part
of the squashed commit); `perf:` and `revert:` ship a patch; `docs:`, `refactor:`, `ci:`,
`chore:`, `test:` and `build:` ship nothing on their own. A check fails the pull request if
the title doesn't follow the format.

CI runs on every pull request, but only the jobs your changed files can affect; the one
check that must pass is `ci-ok` (a skipped job counts as passed, a failed one does not):

- **Build and test** (Swift sources, tests, `Package.swift`, `Resources/`, `build.sh`):
  debug and release builds on macOS with the latest stable Xcode 26, `swift test`, and
  a packaging dry run (dmg and zip, never published). Compiler warnings fail the build.
- **Lint** (workflows and scripts): `bash -n` and shellcheck, actionlint, release config.
- **Site** (`site/`): `scripts/check-site.py` for broken HTML, missing images, dead
  `#links` and anything loaded from another server.

A change to Markdown docs alone runs none of them.

To run the same checks before pushing:

```sh
swift build && swift build -c release --arch arm64
swift test
python3 scripts/check-site.py site
for f in build.sh scripts/*.sh; do bash -n "$f"; done
```

Releases and the website deploy happen automatically after merge; see
[docs/RELEASING.md](docs/RELEASING.md).

## Reporting bugs

Use the bug report form under Issues. It asks for your Discotech and macOS versions, what
you scanned (a drive or a folder), what you expected and what you saw. Screenshots help,
but crop out file names you'd rather not share.
