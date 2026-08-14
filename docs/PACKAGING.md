# Packaging and distribution

## Build an arm64 app and DMG

Requirements: an Apple Silicon Mac, Xcode 26 or later, and the macOS 15 SDK.

```sh
VERSION=0.4.0
MARKETING_VERSION="$VERSION" scripts/package-dmg.sh
MARKETING_VERSION="$VERSION" scripts/verify-dmg.sh
(cd dist && shasum -a 256 -c "S3Workbench-$VERSION.dmg.sha256")
```

The app is built in Release mode for arm64 only, assembled at `.build/distribution/S3Workbench.app`, ad-hoc signed by default, and packaged as `dist/S3Workbench-X.Y.Z.dmg` with `dist/S3Workbench-X.Y.Z.dmg.sha256`. The disk image includes an Applications symlink. `verify-dmg.sh` verifies the checksum and version, validates the UDIF image, mounts it read-only, copies the app to a temporary Applications directory, validates the code signature and Info.plist, and requires an arm64-only executable.

Set `LAUNCH_TEST=1` on `verify-dmg.sh` to add a local launch/quit smoke test. A final release should also be copied to `/Applications` and launched on a clean Mac or VM so quarantine and Gatekeeper behavior match the user experience.

## Publish a GitHub release

Create and push the annotated tag only from the intended, green `main` commit. After the tag workflow succeeds, download its two assets and verify them before publication:

```sh
VERSION=0.4.0
git tag -a "v$VERSION" -m "S3Workbench $VERSION"
git push origin "v$VERSION"
gh run list --workflow CI --branch "v$VERSION"
RUN_ID=123456789
gh run download "$RUN_ID" --name "S3Workbench-v$VERSION-arm64" --dir "dist/v$VERSION"
(cd "dist/v$VERSION" && shasum -a 256 -c "S3Workbench-$VERSION.dmg.sha256")
gh release create "v$VERSION" \
  "dist/v$VERSION/S3Workbench-$VERSION.dmg" \
  "dist/v$VERSION/S3Workbench-$VERSION.dmg.sha256" \
  --verify-tag --title "S3Workbench $VERSION" --notes-file release-notes.md
```

## Developer ID signing and notarization

Install a `Developer ID Application` certificate and store notarization credentials without putting secrets in scripts:

```sh
VERSION=0.4.0
xcrun notarytool store-credentials s3workbench-notary \
  --apple-id you@example.com \
  --team-id TEAMID \
  --password APP_SPECIFIC_PASSWORD

CODESIGN_IDENTITY='Developer ID Application: Name (TEAMID)' \
NOTARYTOOL_PROFILE=s3workbench-notary \
MARKETING_VERSION="$VERSION" scripts/package-dmg.sh

MARKETING_VERSION="$VERSION" REQUIRE_GATEKEEPER=1 scripts/verify-dmg.sh
```

The package script signs the app with Hardened Runtime and a secure timestamp, signs the DMG, submits the DMG with `notarytool`, waits for acceptance, staples the ticket, and validates the staple. Always inspect the notary log if Apple reports warnings.

Useful independent checks:

```sh
VERSION=0.4.0
codesign --verify --deep --strict --verbose=4 .build/distribution/S3Workbench.app
codesign -dvvv .build/distribution/S3Workbench.app
xcrun stapler validate "dist/S3Workbench-$VERSION.dmg"
hdiutil verify "dist/S3Workbench-$VERSION.dmg"
spctl -a -t open -vvv --context context:primary-signature "dist/S3Workbench-$VERSION.dmg"
syspolicy_check distribution .build/distribution/S3Workbench.app
```

## Unsigned/ad-hoc limitation

Without a Developer ID certificate and notarization credentials, the scripts produce a functional ad-hoc signed app in an unsigned DMG. Gatekeeper will not trust that artifact as downloaded software. Users may need to use Finder's Open override in Privacy & Security; do not describe the artifact as signed or notarized.

## Security note

The Info.plist permits arbitrary network loads because connecting to explicitly configured `http://` S3 endpoints is a core requirement. TLS verification remains enabled by default in the client and any opt-out must be scoped to a saved connection. The direct-distribution build is not App Sandbox-enabled so Finder-style file access and Keychain persistence work without security-scoped bookmark plumbing; revisit sandboxing before any Mac App Store distribution.

Apple references: [Packaging Mac software for distribution](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution), [Creating distribution-signed code](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/), and [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).
