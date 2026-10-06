<!--
Title: a Conventional Commit, because it becomes the squashed commit on main and
decides the next release. CI checks it.
  fix: ...    patch release     feat: ...   minor release
  feat!: ...  major release     docs:, refactor:, ci:, chore: ...  no release
-->

## What changed

<!-- One focused change. What and why, in a few lines. -->

## How I tested it

<!-- What you scanned (a scratch folder, a drive), which views, which appearances. -->

- [ ] Light and dark mode
- [ ] Reduce Motion, Increase Contrast and Reduce Transparency, where the change is visual
- [ ] At the 900 x 600 minimum window size, where the change is visual
- [ ] Anything near the Crate or Move to Trash was tried on throwaway data only

## Ground rules

- [ ] Scan results still stay in memory; nothing new is written to disk
- [ ] No networking added to the app
- [ ] Colors, spacing and motion come from `DesignTokens.swift` / `Palette`
- [ ] Crate eligibility still goes through `Model/Safety.swift` and `AppState.collectBlockReason`
