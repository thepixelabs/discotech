# Releasing Discotech

Releases are automatic. [semantic-release](https://semantic-release.gitbook.io/) reads the
Conventional Commit titles merged into `main`, picks the version, builds the app, tags
`vX.Y.Z` and publishes a GitHub Release. Nobody bumps a version or pushes a tag by hand.

## Workflows

| File | What it does |
|---|---|
| `ci.yml` | On pull requests, runs only what the changed files can affect: Swift build (debug and release, warnings fail), `swift test` and a packaging dry run; lint for workflows and scripts; the site check. `ci-ok` is the one required check. Full run when called by `release.yml` or run by hand. |
| `pr-title.yml` | Fails a pull request whose title is not a Conventional Commit. |
| `release.yml` | On every push to `main`: all of `ci.yml`, then semantic-release, then `pages.yml` if something was released. By hand: a dry run (the default) prints the next version and notes and changes nothing. |
| `pages.yml` | Deploys `site/` to GitHub Pages with the latest version and dmg size written in. Skips the deploy, with a warning, while Pages is not enabled. |

Dependabot (`.github/dependabot.yml`) opens weekly PRs for the pinned actions (`ci:`) and
the npm release tooling (`build:`); neither releases anything by itself.

## Versions

Pull requests are squash-merged, so the **PR title** is the commit semantic-release reads.

| PR title | Release | From 1.2.3 |
|---|---|---|
| any type with `!`, e.g. `feat!: ...`, `fix!: ...` | major | 2.0.0 |
| `feat: ...` | minor | 1.3.0 |
| `fix:`, `perf:`, `revert:` | patch | 1.2.4 |
| `docs:`, `refactor:`, `style:`, `test:`, `build:`, `ci:`, `chore:` | none | 1.2.3 |

Several unreleased commits release once, at the highest bump. Versions are counted from
the newest `vX.Y.Z` tag. The first release, v0.7.2, was built by hand with
`scripts/package-release.sh` and tagged on the first commit, so every later `fix:` gives
0.7.3 and a `feat:` gives 0.8.0. A breaking change (`feat!:`) releases 1.0.0 when you
are ready for it. To see what `main` would release now:
Actions > Release > Run workflow with "dry-run" ticked.

Release notes are generated from the commit titles and live only in the GitHub Release;
there is no CHANGELOG file and the release never pushes a commit.

A release contains `Discotech-X.Y.Z-macOS.dmg` and `.zip`, identical copies named
`Discotech-macOS.dmg` and `.zip`, and `checksums.txt`. The copies make these links always
serve the newest release (the site's Download button uses the first):

- https://github.com/thepixelabs/discotech/releases/latest/download/Discotech-macOS.dmg
- https://github.com/thepixelabs/discotech/releases/latest/download/Discotech-macOS.zip
- https://github.com/thepixelabs/discotech/releases/latest/download/checksums.txt

Before anything is tagged or uploaded, `scripts/package-release.sh` checks that
`Info.plist` lints and carries the release version, that `codesign --verify` passes, and
that `hdiutil verify` passes on the dmg. A failure there stops the release with nothing
published. Builds are ad-hoc signed; Developer ID signing and notarization are a future
step (add them to `scripts/package-release.sh` behind repository secrets).

## Owner checklist (repository settings)

1. Make the repository public (free macOS minutes and Pages; release links work without
   signing in).
2. Settings > General > Pull Requests: squash merging only, default message **Pull request
   title**; allow auto-merge; delete head branches.
3. Settings > Pages > Source: **GitHub Actions**, custom domain `discotech.pixelabs.net`.
4. Settings > Rules > new branch ruleset for `main`: require a pull request, require the
   checks **`ci-ok`** and **`Conventional Commit title`**, block force pushes. No bypass
   is needed: the release only creates a tag and a GitHub Release.
5. Settings > Security: secret scanning with push protection, Dependabot alerts, private
   vulnerability reporting.

## When something goes wrong

- **A release failed.** semantic-release opens an issue and GitHub emails you the failed
  run. If it failed before "Created tag", nothing was published: fix `main` and push, or
  re-run the failed jobs. If the tag exists but the Release does not, delete the tag
  (`git push origin :refs/tags/vX.Y.Z`) and re-run.
- **Roll back a bad release.** Delete the Release, keep its tag:

  ```sh
  gh release delete vX.Y.Z -R thepixelabs/discotech --yes
  ```

  The previous release becomes "latest" at once, so the download links serve it; run
  Actions > Pages to update the version shown on the site. Then merge a `revert:` or
  `fix:` PR, which releases vX.Y.Z+1. Keep the tag: without it semantic-release would cut
  vX.Y.Z again with different files.
- **Tag already exists.** The release stops before building. Someone tagged by hand:
  delete that tag if it never became a release.
- **"recent account payments have failed".** macOS minutes on a private repository are
  billed; make the repository public or raise the Actions spending limit.
