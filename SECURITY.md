# Security policy

## Supported versions

Only the latest release gets fixes. Security fixes ship as a new patch release from
`main`; older versions are not patched. Update from the
[latest release](https://github.com/thepixelabs/discotech/releases/latest).

| Version | Supported |
| --- | --- |
| Latest release | Yes |
| Anything older | No |

## Reporting a vulnerability

Report it privately through GitHub:
[**Report a vulnerability**](https://github.com/thepixelabs/discotech/security/advisories/new)
(the repository's Security tab, then "Report a vulnerability").

Please do not open a public issue, pull request or discussion for a suspected
vulnerability.

Include what you can of:

- the Discotech version (Discotech > About Discotech) and the macOS version;
- the steps to reproduce, ideally against a throwaway folder;
- what an attacker gains, and what they need first (local access, a crafted folder or
  file name, a tampered download).

You should get a reply within 7 days. Once a fix is released, the advisory is published
with credit to you unless you prefer otherwise.

## What is in scope

Discotech reads your disk, so the sensitive parts are:

- **Moving items to the Trash.** Anything that gets an item into the Crate that the rules
  in `Sources/Discotech/Model/Safety.swift` should refuse, or moves something other than
  what the review window showed.
- **Scan data leaving memory.** Scan results are never written to disk and the app makes
  no network connections. A way to make either happen is a vulnerability.
- **Crafted file system content.** File names, symlinks, hard links, packages or
  permissions that crash the scanner, hang it, or mislead what the views show.
- **Release integrity.** Release files that do not match the `checksums.txt` published
  with them, or a problem in the build and release workflows in `.github/workflows/`.

Out of scope: problems that need an attacker to already control your user account, and
the first-launch Gatekeeper prompt on releases that are not notarized (documented in the
README).

## Verifying a download

Every release has a `checksums.txt`. In the folder you downloaded to:

```sh
shasum -a 256 -c checksums.txt --ignore-missing
```
