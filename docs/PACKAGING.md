# Packaging and distribution

## Homebrew installation and updates

The personal [tap](https://github.com/romainfrezier/homebrew-s3workbench) distributes
the same Apple Silicon DMG as GitHub Releases, with a versioned URL and SHA-256:

```sh
brew tap romainfrezier/s3workbench
brew trust --cask romainfrezier/s3workbench/s3-workbench
brew install --cask s3-workbench
brew update
brew upgrade --cask s3-workbench
```

It requires macOS 15 or later. Homebrew upgrades the app bundle without removing
saved connections, preferences, local indexes or Keychain credentials. The cask
has no custom installer, credential handling or `zap` cleanup. An ordinary
`brew uninstall --cask s3-workbench` also leaves saved app data in place.

Homebrew delivery is separate from Developer ID signing, Apple notarization and
Gatekeeper approval. The current release is ad-hoc signed and not notarized;
installing through Homebrew does not change that. S3Workbench has no Sparkle or
other in-app updater. Manual [release DMGs](https://github.com/romainfrezier/S3Workbench/releases/latest)
remain available.

## Update the Homebrew cask after a release

Publish and verify the tag-CI assets using the release procedure below first.
Then download both published files into a new directory and verify the checksum:

```sh
VERSION=0.7.0 # Example: replace with the newly published release.
gh release download "v$VERSION" --repo romainfrezier/S3Workbench \
  --pattern "S3Workbench-$VERSION.dmg*" --dir "release-$VERSION"
(cd "release-$VERSION" && shasum -a 256 -c "S3Workbench-$VERSION.dmg.sha256")
```

In the tap's [Casks/s3-workbench.rb](https://github.com/romainfrezier/homebrew-s3workbench/blob/main/Casks/s3-workbench.rb),
update `version` and `sha256` from those verified assets. Its interpolated URL
already includes the version; change that URL only if the asset naming changes.
Keep the immutable version URL and checksum: never use `latest` or `:no_check`.

Open a tap pull request, link the release, and run:

```sh
brew audit --cask --strict romainfrezier/s3workbench/s3-workbench
brew style Casks/s3-workbench.rb
```

Run those commands against the candidate in the installed tap checkout, not an
unrelated clone. The tap's Cask workflow tests the exact candidate, including
fresh installation, upgrade from 0.6.0 with disposable app-data/Keychain sentinels,
and rejection of an incorrect checksum. Review that evidence before merging.
Hosted-runner installation is separate from interactive app launch, Gatekeeper
approval and access to a user's existing Keychain; report those checks separately.

## Build an arm64 app and DMG

Requirements: an Apple Silicon Mac, Xcode 26 or later, and the macOS 15 SDK.

```sh
VERSION=0.7.0 # Example: use the version being built or published.
MARKETING_VERSION="$VERSION" scripts/package-dmg.sh
MARKETING_VERSION="$VERSION" scripts/verify-dmg.sh
(cd dist && shasum -a 256 -c "S3Workbench-$VERSION.dmg.sha256")
```

The app is built in Release mode for arm64 only, assembled at `.build/distribution/S3Workbench.app`, ad-hoc signed by default, and packaged as `dist/S3Workbench-X.Y.Z.dmg` with `dist/S3Workbench-X.Y.Z.dmg.sha256`. The disk image includes an Applications symlink. `verify-dmg.sh` verifies the checksum and version, validates the UDIF image, mounts it read-only, copies the app to a temporary Applications directory, validates the code signature and Info.plist, and requires an arm64-only executable.

Set `LAUNCH_TEST=1` on `verify-dmg.sh` to add a local launch/quit smoke test. A final release should also be copied to `/Applications` and launched on a clean Mac or VM so quarantine and Gatekeeper behavior match the user experience.

## Publish a GitHub release

Follow [Gitflow](../CONTRIBUTING.md#gitflow): merge a validated `release/<version>`
or `hotfix/<version>` PR into `main` with a merge commit. Create and push the
annotated tag only from that intended, green `main` merge commit. Keep the source
branch until its back-merge into `develop` (and any open release for a hotfix) is
complete. After the tag workflow succeeds, download its two assets and verify
them before publication:

```sh
VERSION=0.7.0 # Example: use the version being built or published.
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
VERSION=0.7.0 # Example: use the version being built or published.
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
VERSION=0.7.0 # Example: use the version being built or published.
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
