#!/usr/bin/env bash
# Build a drag-to-Applications DMG from an already-built AppleTree.app.
#
# Usage:
#   scripts/package-dmg.sh <AppleTree.app> <output.dmg>
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <AppleTree.app> <output.dmg>" >&2
  exit 2
fi

APP_SRC=$1
DMG_OUT=$2

if [[ ! -d "$APP_SRC" ]]; then
  echo "error: app bundle not found: $APP_SRC" >&2
  exit 1
fi

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BACKGROUND=$ROOT/packaging/dmg/background@2x.png
SETTINGS=$ROOT/packaging/dmg/settings.py
REQUIREMENTS=$ROOT/packaging/dmg/requirements.txt
ICONSET_SRC=$ROOT/AppleTree/Assets.xcassets/AppIcon.appiconset

if [[ ! -f "$BACKGROUND" ]]; then
  echo "error: missing $BACKGROUND — run packaging/dmg/render-background.swift" >&2
  exit 1
fi
if [[ ! -f "$SETTINGS" ]]; then
  echo "error: missing $SETTINGS" >&2
  exit 1
fi

STAGE=$(mktemp -d "${TMPDIR:-/tmp}/appletree-dmg.XXXXXX")
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

mkdir -p "$STAGE/source"
cp -R "$APP_SRC" "$STAGE/source/AppleTree.app"

# GPLv3 requires the license to accompany the binary. Keep it inside the
# bundle so the DMG window stays a clean drag-and-drop of the app. Do not
# overwrite an already-embedded copy: that would break a Developer ID
# signature (release builds copy LICENSE before codesign).
if [[ -f "$ROOT/LICENSE" && ! -f "$STAGE/source/AppleTree.app/Contents/Resources/LICENSE" ]]; then
  mkdir -p "$STAGE/source/AppleTree.app/Contents/Resources"
  cp "$ROOT/LICENSE" "$STAGE/source/AppleTree.app/Contents/Resources/LICENSE"
fi

# Volume icon: iconutil wants a .iconset directory with the canonical names,
# which the asset catalog already uses.
ICONSET=$STAGE/AppIcon.iconset
mkdir -p "$ICONSET"
for name in \
  icon_16x16.png icon_16x16@2x.png \
  icon_32x32.png icon_32x32@2x.png \
  icon_128x128.png icon_128x128@2x.png \
  icon_256x256.png icon_256x256@2x.png \
  icon_512x512.png icon_512x512@2x.png
do
  cp "$ICONSET_SRC/$name" "$ICONSET/$name"
done
iconutil -c icns -o "$STAGE/AppIcon.icns" "$ICONSET"

echo "==> Installing dmgbuild (ephemeral venv)"
python3 -m venv "$STAGE/venv"
"$STAGE/venv/bin/pip" install --quiet --disable-pip-version-check -r "$REQUIREMENTS"

mkdir -p "$(dirname "$DMG_OUT")"
rm -f "$DMG_OUT"

# Icon coordinates are window points and must match the chevron in
# packaging/dmg/render-background.swift.
echo "==> Building DMG"
"$STAGE/venv/bin/dmgbuild" \
  -s "$SETTINGS" \
  -D "app=$STAGE/source/AppleTree.app" \
  -D "icon=$STAGE/AppIcon.icns" \
  -D "background=$BACKGROUND" \
  "AppleTree" \
  "$DMG_OUT"

echo "wrote $DMG_OUT"
