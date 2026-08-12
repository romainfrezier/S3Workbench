#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP_NAME=${APP_NAME:-S3Workbench}
BUNDLE_IDENTIFIER=${BUNDLE_IDENTIFIER:-com.s3workbench.app}
BUILD_ROOT=${BUILD_ROOT:-"$ROOT/.build/distribution"}
APP_PATH="$BUILD_ROOT/$APP_NAME.app"
DIST_DIR=${DIST_DIR:-"$ROOT/dist"}
DMG_PATH="$DIST_DIR/$APP_NAME.dmg"
CODESIGN_IDENTITY=${CODESIGN_IDENTITY:--}
NOTARYTOOL_PROFILE=${NOTARYTOOL_PROFILE:-}

[[ "$APP_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Invalid APP_NAME" >&2; exit 2; }
if [[ ${SKIP_BUILD:-0} != 1 ]]; then
  "$ROOT/scripts/build-app.sh" >/dev/null
fi
[[ -d "$APP_PATH" ]] || { echo "App bundle not found: $APP_PATH" >&2; exit 1; }
if [[ -n "$NOTARYTOOL_PROFILE" && "$CODESIGN_IDENTITY" == "-" ]]; then
  echo "Notarization requires a Developer ID Application identity" >&2
  exit 2
fi

STAGING=$(mktemp -d "${TMPDIR:-/tmp}/s3workbench-dmg.XXXXXX")
cleanup() { rm -rf -- "$STAGING"; }
trap cleanup EXIT

/usr/bin/ditto "$APP_PATH" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"
mkdir -p "$DIST_DIR"
rm -f -- "$DMG_PATH"
hdiutil create -quiet -srcfolder "$STAGING" -volname "$APP_NAME" -format UDZO -o "$DMG_PATH"

if [[ "$CODESIGN_IDENTITY" != "-" ]]; then
  codesign --force --sign "$CODESIGN_IDENTITY" --timestamp -i "$BUNDLE_IDENTIFIER.dmg" "$DMG_PATH"
fi

if [[ -n "$NOTARYTOOL_PROFILE" ]]; then
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARYTOOL_PROFILE" --wait
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
fi

hdiutil verify "$DMG_PATH"
printf '%s\n' "$DMG_PATH"
