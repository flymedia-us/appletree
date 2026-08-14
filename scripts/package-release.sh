#!/usr/bin/env bash
# Archive, Developer ID-sign, notarize, and wrap AppleTree in a DMG.
#
# Required environment (CI secrets or a local export):
#   APP_STORE_CONNECT_KEY_ID
#   APP_STORE_CONNECT_ISSUER_ID
#   APP_STORE_CONNECT_API_KEY          raw .p8 contents
#     — or —
#   APP_STORE_CONNECT_API_KEY_PATH     path to the .p8 file
#
# Optional:
#   SKIP_NOTARIZE=1     skip notarytool (layout tests only; do not ship)
#   OUTPUT_DIR          default: dist
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

OUTPUT_DIR=${OUTPUT_DIR:-"$ROOT/dist"}
SKIP_NOTARIZE=${SKIP_NOTARIZE:-0}
TEAM_ID=BJZSH247Q9
ARCHIVE_PATH=$OUTPUT_DIR/AppleTree.xcarchive
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

run_xcodebuild() {
  # Extra args first so a Developer ID archive can pass authentication flags
  # without relying on bash 3.2 empty-array expansion under `set -u`.
  # Manual style is required here: the project is Automatic for local/App
  # Store signing, and Automatic + CODE_SIGN_IDENTITY="Developer ID
  # Application" is the conflicting-provisioning-settings archive failure.
  # Export still uses automatic Developer ID so -allowProvisioningUpdates
  # can mint/refresh the sandboxed profile.
  xcodebuild "$@" \
    -project AppleTree.xcodeproj \
    -scheme AppleTree \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO
}

echo "==> Archiving Release (universal)"
rm -rf "$ARCHIVE_PATH" "$EXPORT_DIR"
if [[ "$SKIP_NOTARIZE" != "1" ]]; then
  run_xcodebuild \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$AUTH_KEY_PATH" \
    -authenticationKeyID "$APP_STORE_CONNECT_KEY_ID" \
    -authenticationKeyIssuerID "$APP_STORE_CONNECT_ISSUER_ID" \
    -archivePath "$ARCHIVE_PATH" \
    archive
else
  run_xcodebuild \
    -archivePath "$ARCHIVE_PATH" \
    archive
fi

echo "==> Exporting Developer ID app"
if [[ "$SKIP_NOTARIZE" != "1" ]]; then
  xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$ROOT/packaging/exportOptions-developer-id.plist" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$AUTH_KEY_PATH" \
    -authenticationKeyID "$APP_STORE_CONNECT_KEY_ID" \
    -authenticationKeyIssuerID "$APP_STORE_CONNECT_ISSUER_ID"
else
  xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$ROOT/packaging/exportOptions-developer-id.plist"
fi

APP=$EXPORT_DIR/AppleTree.app
if [[ ! -d "$APP" ]]; then
  echo "error: export did not produce AppleTree.app in $EXPORT_DIR" >&2
  ls -la "$EXPORT_DIR" >&2 || true
  exit 1
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
