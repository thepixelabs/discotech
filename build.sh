#!/bin/bash
# Builds Discotech.app into ./build. Usage: ./build.sh [debug|release]
#
# Version overrides (used by CI/releases; local usage is unaffected):
#   VERSION=1.2.3 BUILD_NUMBER=42 ./build.sh release
# Without them, VERSION is the newest vX.Y.Z tag (0.0.0-dev when there is no tag or no
# git) and BUILD_NUMBER is the commit count (1 without git). BUILD_DIR (default: build)
# changes where the .app lands, e.g. for a packaging dry run outside the repo.
set -euo pipefail
cd "$(dirname "$0")"

# The app's name lives in exactly one place; change it here only.
APP_NAME="Discotech"
BUNDLE_ID="com.pixelabs.discotech"

CONFIG="${1:-release}"
# Only ask git inside this checkout, never a repository the folder happens to sit in.
git_here() { [ -e .git ] && git "$@" 2>/dev/null; }
if [ -z "${VERSION:-}" ]; then
  VERSION="$(git_here describe --tags --abbrev=0 --match 'v[0-9]*' || true)"
  VERSION="${VERSION#v}"
  VERSION="${VERSION:-0.0.0-dev}"
fi
BUILD_NUMBER="${BUILD_NUMBER:-$(git_here rev-list --count HEAD || echo 1)}"

# Reproducible link: without this, ld writes each object file's modification time into
# the executable's debug map (N_OSO entries), so two clean builds of one commit differ.
export ZERO_AR_DATE="${ZERO_AR_DATE:-1}"

swift build -c "$CONFIG" --arch arm64
BIN="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)/$APP_NAME"
APP="${BUILD_DIR:-build}/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

# Icon is optional: copy it in and declare CFBundleIconFile only if it exists,
# so this script keeps working before the illustrator's AppIcon.icns lands.
ICON_SRC="Resources/AppIcon.icns"
ICON_KEY=""
if [ -f "$ICON_SRC" ]; then
  cp "$ICON_SRC" "$APP/Contents/Resources/AppIcon.icns"
  ICON_KEY="    <key>CFBundleIconFile</key><string>AppIcon</string>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
$ICON_KEY
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
# Ad-hoc sign so Full Disk Access can be granted to a stable identity.
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP ($VERSION build $BUILD_NUMBER)"
