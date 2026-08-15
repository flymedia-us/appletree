#!/usr/bin/env bash
# Sign, notarize, and wrap AppleTree in a DMG for GitHub Releases.
#
# App Store builds stay on Automatic signing in the Xcode project. This script
# never asks xcodebuild to mix that with Developer ID — that hangs or errors
# on CI. It reuses the unsigned Release compile (same as PR CI), then codesign
# + notarytool.
#
# Required environment (CI secrets or a local export):
#   APP_STORE_CONNECT_KEY_ID
#   APP_STORE_CONNECT_ISSUER_ID
#   APP_STORE_CONNECT_API_KEY          raw .p8 contents
#     — or —
#   APP_STORE_CONNECT_API_KEY_PATH     path to the .p8 file
#
# Optional:
#   SKIP_NOTARIZE=1     skip sign/notary (layout tests only; do not ship)
#   OUTPUT_DIR          default: dist
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

OUTPUT_DIR=${OUTPUT_DIR:-"$ROOT/dist"}
SKIP_NOTARIZE=${SKIP_NOTARIZE:-0}
TEAM_ID=BJZSH247Q9
DERIVED=$OUTPUT_DIR/DerivedData
EXPORT_DIR=$OUTPUT_DIR/export
AUTH_KEY_PATH=${APP_STORE_CONNECT_API_KEY_PATH:-}

mkdir -p "$OUTPUT_DIR"

if [[ "$SKIP_NOTARIZE" != "1" ]]; then
  : "${APP_STORE_CONNECT_KEY_ID:?Set APP_STORE_CONNECT_KEY_ID}"
  : "${APP_STORE_CONNECT_ISSUER_ID:?Set APP_STORE_CONNECT_ISSUER_ID}"
  if [[ -z "$AUTH_KEY_PATH" ]]; then
    : "${APP_STORE_CONNECT_API_KEY:?Set APP_STORE_CONNECT_API_KEY or APP_STORE_CONNECT_API_KEY_PATH}"
    AUTH_KEY_PATH=$OUTPUT_DIR/AuthKey_${APP_STORE_CONNECT_KEY_ID}.p8
    printf '%s\n' "$APP_STORE_CONNECT_API_KEY" > "$AUTH_KEY_PATH"
    chmod 600 "$AUTH_KEY_PATH"
    trap 'rm -f "$AUTH_KEY_PATH"' EXIT
  fi
  if [[ ! -f "$AUTH_KEY_PATH" ]]; then
    echo "error: API key file not found: $AUTH_KEY_PATH" >&2
    exit 1
  fi
fi

echo "==> Building unsigned Release (universal)"
rm -rf "$DERIVED" "$EXPORT_DIR"
mkdir -p "$EXPORT_DIR"
xcodebuild \
  -project AppleTree.xcodeproj \
  -scheme AppleTree \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  build

APP_SRC=$(find "$DERIVED" -path '*/Build/Products/Release/AppleTree.app' -type d | head -n 1)
if [[ -z "$APP_SRC" ]]; then
  echo "error: Release AppleTree.app not found under $DERIVED" >&2
  find "$DERIVED" -name 'AppleTree.app' >&2 || true
  exit 1
fi

APP=$EXPORT_DIR/AppleTree.app
rm -rf "$APP"
ditto "$APP_SRC" "$APP"

# Embed the license before signing so the DMG script does not invalidate
# the Developer ID signature by copying files into a signed bundle.
if [[ -f "$ROOT/LICENSE" ]]; then
  mkdir -p "$APP/Contents/Resources"
  cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"
fi

if [[ "$SKIP_NOTARIZE" != "1" ]]; then
  echo "==> Signing with Developer ID"
  IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')
  if [[ -z "$IDENTITY" ]]; then
    echo "error: no Developer ID Application identity in the keychain" >&2
    security find-identity -v -p codesigning >&2 || true
    exit 1
  fi
  echo "identity=$IDENTITY"
  codesign --force --timestamp --options runtime \
    --entitlements "$ROOT/AppleTree/AppleTree.entitlements" \
    --generate-entitlement-der \
    --sign "$IDENTITY" \
    "$APP"
  codesign --verify --verbose=2 --strict "$APP"
  codesign --display --verbose=2 --entitlements - "$APP"
fi

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
DMG_VERSIONED=$OUTPUT_DIR/AppleTree-${VERSION}.dmg
DMG_STABLE=$OUTPUT_DIR/AppleTree.dmg
APP_ZIP=$OUTPUT_DIR/AppleTree-${VERSION}.zip

if [[ "$SKIP_NOTARIZE" != "1" ]]; then
  echo "==> Notarizing app"
  rm -f "$APP_ZIP"
  ditto -c -k --keepParent "$APP" "$APP_ZIP"
  xcrun notarytool submit "$APP_ZIP" \
    --key "$AUTH_KEY_PATH" \
    --key-id "$APP_STORE_CONNECT_KEY_ID" \
    --issuer "$APP_STORE_CONNECT_ISSUER_ID" \
    --wait
  xcrun stapler staple "$APP"
fi

echo "==> Building DMG"
"$ROOT/scripts/package-dmg.sh" "$APP" "$DMG_VERSIONED"
cp "$DMG_VERSIONED" "$DMG_STABLE"

if [[ "$SKIP_NOTARIZE" != "1" ]]; then
  echo "==> Notarizing DMG"
  xcrun notarytool submit "$DMG_VERSIONED" \
    --key "$AUTH_KEY_PATH" \
    --key-id "$APP_STORE_CONNECT_KEY_ID" \
    --issuer "$APP_STORE_CONNECT_ISSUER_ID" \
    --wait
  xcrun stapler staple "$DMG_VERSIONED"
  cp "$DMG_VERSIONED" "$DMG_STABLE"
fi

echo "version=$VERSION"
echo "dmg=$DMG_VERSIONED"
echo "dmg_stable=$DMG_STABLE"
