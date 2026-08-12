#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP_NAME=${APP_NAME:-S3Workbench}
EXECUTABLE_NAME=${EXECUTABLE_NAME:-S3Workbench}
BUNDLE_IDENTIFIER=${BUNDLE_IDENTIFIER:-com.s3workbench.app}
MARKETING_VERSION=${MARKETING_VERSION:-0.1.0}
BUILD_NUMBER=${BUILD_NUMBER:-1}
BUILD_ROOT=${BUILD_ROOT:-"$ROOT/.build/distribution"}
APP_PATH="$BUILD_ROOT/$APP_NAME.app"
INFO_TEMPLATE="$ROOT/Packaging/Info.plist"
ENTITLEMENTS=${ENTITLEMENTS:-"$ROOT/Packaging/S3Workbench.entitlements"}
CODESIGN_IDENTITY=${CODESIGN_IDENTITY:--}

[[ "$APP_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Invalid APP_NAME" >&2; exit 2; }
[[ "$EXECUTABLE_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Invalid EXECUTABLE_NAME" >&2; exit 2; }
[[ "$BUNDLE_IDENTIFIER" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "Invalid BUNDLE_IDENTIFIER" >&2; exit 2; }
[[ "$MARKETING_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || { echo "Invalid MARKETING_VERSION" >&2; exit 2; }
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || { echo "Invalid BUILD_NUMBER" >&2; exit 2; }
[[ -f "$INFO_TEMPLATE" && -f "$ENTITLEMENTS" ]] || { echo "Packaging templates are missing" >&2; exit 2; }

swift build --package-path "$ROOT" --configuration release --arch arm64 --product "$EXECUTABLE_NAME"
BIN_PATH=$(swift build --package-path "$ROOT" --configuration release --arch arm64 --show-bin-path)
[[ -x "$BIN_PATH/$EXECUTABLE_NAME" ]] || { echo "Release executable not found" >&2; exit 1; }

case "$APP_PATH" in
  "$BUILD_ROOT"/*.app) rm -rf -- "$APP_PATH" ;;
  *) echo "Unsafe app output path: $APP_PATH" >&2; exit 2 ;;
esac
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
/usr/bin/ditto "$BIN_PATH/$EXECUTABLE_NAME" "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"

if [[ -f "$ROOT/Sources/S3Workbench/Resources/AppIcon.icns" ]]; then
  /usr/bin/ditto "$ROOT/Sources/S3Workbench/Resources/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"
fi

while IFS= read -r -d '' bundle; do
  /usr/bin/ditto "$bundle" "$APP_PATH/Contents/Resources/$(basename "$bundle")"
done < <(find "$BIN_PATH" -maxdepth 1 -type d -name '*.bundle' -print0)
if [[ -f "$ROOT/Sources/$EXECUTABLE_NAME/Resources/AppIcon.icns" ]]; then
  /usr/bin/ditto "$ROOT/Sources/$EXECUTABLE_NAME/Resources/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"
fi

/usr/bin/sed \
  -e "s|@APP_NAME@|$APP_NAME|g" \
  -e "s|@EXECUTABLE_NAME@|$EXECUTABLE_NAME|g" \
  -e "s|@BUNDLE_IDENTIFIER@|$BUNDLE_IDENTIFIER|g" \
  -e "s|@MARKETING_VERSION@|$MARKETING_VERSION|g" \
  -e "s|@BUILD_NUMBER@|$BUILD_NUMBER|g" \
  "$INFO_TEMPLATE" > "$APP_PATH/Contents/Info.plist"
plutil -lint "$APP_PATH/Contents/Info.plist" >/dev/null

if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
  codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP_PATH"
  echo "Built ad-hoc signed app: $APP_PATH"
else
  codesign --force --sign "$CODESIGN_IDENTITY" --timestamp --options runtime --entitlements "$ENTITLEMENTS" "$APP_PATH"
  echo "Built Developer ID signed app: $APP_PATH"
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
[[ "$(lipo -archs "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME")" == "arm64" ]] || {
  echo "Release executable is not arm64-only" >&2
  exit 1
}

printf '%s\n' "$APP_PATH"
