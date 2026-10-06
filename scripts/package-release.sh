#!/bin/bash
# Builds Discotech.app, checks it, and packages it into $DIST_DIR (default: dist):
#   Discotech-<version>-macOS.dmg / .zip   the release files
#   Discotech-macOS.dmg / .zip             identical copies with stable names, so
#                                          .../releases/latest/download/Discotech-macOS.dmg
#                                          always serves the newest release
#   checksums.txt                          SHA-256 of the four files above
# Run by semantic-release's prepare step (.releaserc.json) and by CI as a dry run:
#   VERSION=0.0.0 BUILD_NUMBER=1 DIST_DIR=/tmp/dist BUILD_DIR=/tmp/build ./scripts/package-release.sh
# Builds are ad-hoc signed (see docs/RELEASING.md for Developer ID signing, a future step).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:?VERSION is required}"
BUILD_NUMBER="${BUILD_NUMBER:?BUILD_NUMBER is required}"
export VERSION BUILD_NUMBER
DIST="${DIST_DIR:-dist}"
export BUILD_DIR="${BUILD_DIR:-build}"
APP="$BUILD_DIR/Discotech.app"
NAME="Discotech-$VERSION-macOS"

fail() { echo "::error::$*" >&2; exit 1; }

./build.sh release

echo "==> Checking $APP"
plutil -lint "$APP/Contents/Info.plist"
short="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[ "$short" = "$VERSION" ] || fail "Info.plist version is '$short', expected '$VERSION'"
codesign --verify --deep --strict "$APP" || fail "codesign --verify failed"

rm -rf "$DIST" && mkdir -p "$DIST"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Discotech.app"
ln -s /Applications "$STAGE/Applications" # drag-to-install target in the dmg

echo "==> Packaging $NAME"
ditto -c -k --keepParent "$STAGE/Discotech.app" "$DIST/$NAME.zip"
# hdiutil occasionally reports "Resource busy" on hosted runners; retry.
for attempt in 1 2 3; do
  hdiutil create -volname Discotech -srcfolder "$STAGE" -format UDZO -ov "$DIST/$NAME.dmg" && break
  [ "$attempt" = 3 ] && fail "hdiutil create failed 3 times"
  sleep 5
done
hdiutil verify "$DIST/$NAME.dmg"

cp "$DIST/$NAME.dmg" "$DIST/Discotech-macOS.dmg"
cp "$DIST/$NAME.zip" "$DIST/Discotech-macOS.zip"
(cd "$DIST" && shasum -a 256 "$NAME.dmg" "$NAME.zip" Discotech-macOS.dmg Discotech-macOS.zip > checksums.txt)
cat "$DIST/checksums.txt"
