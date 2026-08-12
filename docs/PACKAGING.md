# Packaging and distribution

## Build an arm64 app and DMG

Requirements: an Apple Silicon Mac, Xcode 26 or later, and the macOS 15 SDK.

```sh
scripts/build-app.sh
scripts/package-dmg.sh
scripts/verify-dmg.sh
```

The app is built in Release mode for arm64 only, assembled at `.build/distribution/S3Workbench.app`, ad-hoc signed by default, and packaged at `dist/S3Workbench.dmg`. The disk image includes an Applications symlink. `verify-dmg.sh` verifies the UDIF image, mounts it read-only, copies the app to a temporary Applications directory, validates the code signature and Info.plist, and requires an arm64-only executable.

Set `LAUNCH_TEST=1` to add a local launch/quit smoke test. A final release should also be copied to `/Applications` and launched on a clean Mac or VM so quarantine and Gatekeeper behavior match the user experience.

## Developer ID signing and notarization

Install a `Developer ID Application` certificate and store notarization credentials without putting secrets in scripts:

```sh
xcrun notarytool store-credentials s3workbench-notary \
  --apple-id you@example.com \
  --team-id TEAMID \
  --password APP_SPECIFIC_PASSWORD

CODESIGN_IDENTITY='Developer ID Application: Name (TEAMID)' \
NOTARYTOOL_PROFILE=s3workbench-notary \
scripts/package-dmg.sh

REQUIRE_GATEKEEPER=1 scripts/verify-dmg.sh
```

The package script signs the app with Hardened Runtime and a secure timestamp, signs the DMG, submits the DMG with `notarytool`, waits for acceptance, staples the ticket, and validates the staple. Always inspect the notary log if Apple reports warnings.

Useful independent checks:

```sh
codesign --verify --deep --strict --verbose=4 .build/distribution/S3Workbench.app
codesign -dvvv .build/distribution/S3Workbench.app
xcrun stapler validate dist/S3Workbench.dmg
hdiutil verify dist/S3Workbench.dmg
spctl -a -t open -vvv --context context:primary-signature dist/S3Workbench.dmg
syspolicy_check distribution .build/distribution/S3Workbench.app
```

## Unsigned/ad-hoc limitation

Without a Developer ID certificate and notarization credentials, the scripts produce a functional ad-hoc signed app in an unsigned DMG. Gatekeeper will not trust that artifact as downloaded software. Users may need to use Finder's Open override in Privacy & Security; do not describe the artifact as signed or notarized.

## Security note

The Info.plist permits arbitrary network loads because connecting to explicitly configured `http://` S3 endpoints is a core requirement. TLS verification remains enabled by default in the client and any opt-out must be scoped to a saved connection. The direct-distribution build is not App Sandbox-enabled so Finder-style file access and Keychain persistence work without security-scoped bookmark plumbing; revisit sandboxing before any Mac App Store distribution.

Apple references: [Packaging Mac software for distribution](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution), [Creating distribution-signed code](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/), and [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).
