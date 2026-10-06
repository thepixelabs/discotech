#!/usr/bin/env python3
"""Copy site/ to an output directory and write the latest release into the copy.

    python3 scripts/stamp-site.py <site_dir> <out_dir> [release.json]

release.json is `gh api repos/thepixelabs/discotech/releases/latest`. The text between
<!--release:meta--> and <!--/release:meta--> becomes "Version X.Y.Z, N.N MB disk image".
With no usable release data the copy keeps its fallback text. With release data but no
marker in any page, it fails, so a markup change cannot silently drop the version.
"""
import json
import re
import shutil
import sys
from pathlib import Path

META = re.compile(r"(<!--release:meta-->)(.*?)(<!--/release:meta-->)", re.S)


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    site, out = Path(sys.argv[1]), Path(sys.argv[2])
    shutil.rmtree(out, ignore_errors=True)
    shutil.copytree(site, out)

    try:
        release = json.loads(Path(sys.argv[3]).read_text()) if len(sys.argv) > 3 else {}
    except (OSError, ValueError):
        release = {}
    tag = str(release.get("tag_name") or "") if isinstance(release, dict) else ""
    dmg = next((a for a in release.get("assets", []) if a.get("name") == "Discotech-macOS.dmg"), None) if tag else None
    if not dmg:
        print("stamp-site: no release with Discotech-macOS.dmg; site copied with fallback text")
        return 0

    text = f"Version {tag.removeprefix('v')}, {int(dmg.get('size') or 0) / 1_000_000:.1f} MB disk image"
    stamped = 0
    for page in out.rglob("*.html"):
        html = page.read_text(encoding="utf-8")
        new, n = META.subn(lambda m: m.group(1) + text + m.group(3), html)
        if n:
            page.write_text(new, encoding="utf-8")
            stamped += n
    if not stamped:
        print("stamp-site: no <!--release:meta--> marker found in any page", file=sys.stderr)
        return 1
    print(f"stamp-site: {text} ({stamped} places)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
