#!/bin/bash
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT="$HERE/../../.build/file-provider-poc"
APP="$OUT/S3WorkbenchPOC.app"
EXT="$APP/Contents/PlugIns/Provider.appex"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}
SDK=$(xcrun --sdk macosx --show-sdk-path)
mkdir -p "$APP/Contents/MacOS" "$EXT/Contents/MacOS"
swiftc -swift-version 5 -target arm64-apple-macos15.0 -sdk "$SDK" -parse-as-library \
  "$HERE/Provider.swift" "$HERE/Checks.swift" -o "$OUT/checks"
"$OUT/checks"
swiftc -swift-version 5 -target arm64-apple-macos15.0 -sdk "$SDK" -parse-as-library \
  "$HERE/Host.swift" -o "$APP/Contents/MacOS/Host"
swiftc -swift-version 5 -target arm64-apple-macos15.0 -sdk "$SDK" -parse-as-library \
  -application-extension "$HERE/Provider.swift" -Xlinker -e -Xlinker _NSExtensionMain \
  -o "$EXT/Contents/MacOS/Provider"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.s3workbench.fileprovider-poc</string>
<key>CFBundleExecutable</key><string>Host</string>
<key>CFBundleName</key><string>S3WorkbenchPOC</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.0.1</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
cat > "$EXT/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.s3workbench.fileprovider-poc.provider</string>
<key>CFBundleExecutable</key><string>Provider</string>
<key>CFBundleName</key><string>S3Workbench POC</string>
<key>CFBundlePackageType</key><string>XPC!</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.0.1</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSExtension</key><dict>
<key>NSExtensionPointIdentifier</key><string>com.apple.fileprovider-nonui</string>
<key>NSExtensionPrincipalClass</key><string>POCProvider</string>
<key>NSExtensionFileProviderSupportsEnumeration</key><true/>
<key>NSExtensionFileProviderDocumentGroup</key><string>group.com.s3workbench.fileprovider-poc</string>
</dict>
</dict></plist>
PLIST
cat > "$OUT/sandbox.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.application-groups</key><array><string>group.com.s3workbench.fileprovider-poc</string></array>
</dict></plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" "$EXT/Contents/Info.plist" "$OUT/sandbox.entitlements"
codesign --force --sign - --entitlements "$OUT/sandbox.entitlements" "$EXT"
codesign --force --sign - --entitlements "$OUT/sandbox.entitlements" "$APP"
codesign --verify --deep --strict "$APP"
printf '%s\n' "$APP"
