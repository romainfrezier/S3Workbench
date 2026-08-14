#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP_NAME=${APP_NAME:-S3Workbench}
EXECUTABLE_NAME=${EXECUTABLE_NAME:-S3Workbench}
MARKETING_VERSION=${MARKETING_VERSION:-}
DMG_NAME="$APP_NAME-$MARKETING_VERSION.dmg"
DMG_PATH=${1:-"$ROOT/dist/$DMG_NAME"}
CHECKSUM_PATH="$DMG_PATH.sha256"

[[ "$MARKETING_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "MARKETING_VERSION must be a release version such as 0.4.0" >&2; exit 2; }
[[ "$(basename "$DMG_PATH")" == "$DMG_NAME" ]] || { echo "Expected versioned DMG named $DMG_NAME" >&2; exit 2; }
[[ -f "$DMG_PATH" ]] || { echo "DMG not found: $DMG_PATH" >&2; exit 2; }
[[ -f "$CHECKSUM_PATH" ]] || { echo "Checksum not found: $CHECKSUM_PATH" >&2; exit 2; }
CHECKSUM_LINE=$(<"$CHECKSUM_PATH")
EXPECTED_DIGEST=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')
[[ "$CHECKSUM_LINE" == "$EXPECTED_DIGEST  $DMG_NAME" ]] || { echo "Invalid checksum file: $CHECKSUM_PATH" >&2; exit 1; }
(
  cd "$(dirname "$DMG_PATH")"
  shasum -a 256 -c "$DMG_NAME.sha256"
)
hdiutil verify "$DMG_PATH"

ATTACH_PLIST=$(mktemp "${TMPDIR:-/tmp}/s3workbench-attach.XXXXXX")
COPY_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/s3workbench-copy.XXXXXX")
MOUNT_POINT=
cleanup() {
  if [[ -n "$MOUNT_POINT" ]]; then hdiutil detach "$MOUNT_POINT" -quiet || true; fi
  rm -f -- "$ATTACH_PLIST"
  rm -rf -- "$COPY_ROOT"
}
trap cleanup EXIT

hdiutil attach -readonly -nobrowse -plist "$DMG_PATH" > "$ATTACH_PLIST"
for index in {0..9}; do
  MOUNT_POINT=$(/usr/libexec/PlistBuddy -c "Print :system-entities:$index:mount-point" "$ATTACH_PLIST" 2>/dev/null || true)
  [[ -n "$MOUNT_POINT" ]] && break
done
[[ -n "$MOUNT_POINT" ]] || { echo "Unable to determine DMG mount point" >&2; exit 1; }

MOUNTED_APP="$MOUNT_POINT/$APP_NAME.app"
COPIED_APP="$COPY_ROOT/Applications/$APP_NAME.app"
[[ -d "$MOUNTED_APP" ]] || { echo "App bundle missing from DMG" >&2; exit 1; }
mkdir -p "$(dirname "$COPIED_APP")"
/usr/bin/ditto "$MOUNTED_APP" "$COPIED_APP"

codesign --verify --deep --strict --verbose=2 "$COPIED_APP"
ARCHS=$(lipo -archs "$COPIED_APP/Contents/MacOS/$EXECUTABLE_NAME")
[[ "$ARCHS" == "arm64" ]] || { echo "Expected arm64-only binary, got: $ARCHS" >&2; exit 1; }
plutil -lint "$COPIED_APP/Contents/Info.plist" >/dev/null
BUNDLE_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$COPIED_APP/Contents/Info.plist")
[[ "$BUNDLE_VERSION" == "$MARKETING_VERSION" ]] || { echo "Expected app version $MARKETING_VERSION, got: $BUNDLE_VERSION" >&2; exit 1; }

if [[ ${REQUIRE_GATEKEEPER:-0} == 1 ]]; then
  spctl --assess --type exec --verbose=4 "$COPIED_APP"
  spctl --assess --type open --verbose=4 --context context:primary-signature "$DMG_PATH"
fi

if [[ ${LAUNCH_TEST:-0} == 1 ]]; then
  "$COPIED_APP/Contents/MacOS/$EXECUTABLE_NAME" >/dev/null 2>&1 &
  APP_PID=$!
  sleep 3
  kill -0 "$APP_PID" 2>/dev/null || { echo "App did not remain running" >&2; exit 1; }
  kill "$APP_PID"
  wait "$APP_PID" 2>/dev/null || true
fi

echo "Verified checksum, DMG, app version, copy, signature, and arm64 executable: $DMG_PATH"
