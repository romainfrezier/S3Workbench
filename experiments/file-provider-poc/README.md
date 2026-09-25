# Finder File Provider POC

## Historical Finder validation — 2026-09-18

**Positive for native Finder integration with a synthetic, immutable file.**
This is not yet an S3-backed drive or a production-ready extension.
The standalone prototype lives under `experiments/file-provider-poc/` and is
not included in the application or its release packaging. The production
feature remains tracked in [issue #41](https://github.com/romainfrezier/S3Workbench/issues/41).

Verified on macOS 27.0 beta (26A5425a), Apple Silicon, using Swift 6.4 and
Command Line Tools. The full Xcode installation was blocked by an unaccepted
license; the existing Command Line Tools compiled this probe without changing
the selected developer directory or accepting a license.

| Check | Result |
| --- | --- |
| Compile host and replicated File Provider extension | Passed, deployment target macOS 15 |
| Fixture checks | Passed: read-only capabilities, metadata size, enumeration, invalid page, invalidation |
| Bundle plists and nested code signatures | Passed |
| Register extension and add domain | Passed with local ad-hoc signing; no Apple signing identity installed |
| Finder sidebar | `S3WorkbenchPOC` appeared under Locations |
| Domain activation | Finder initially requested Enable; activation succeeded |
| Lazy materialization | `README.txt` initially showed Not Downloaded, 53 bytes |
| Quick Look | Opening the placeholder displayed the exact synthetic fixture content |
| Cleanup | Domain removed successfully; its Finder sidebar entry disappeared |
| Real S3 listing/download/authentication | Not implemented or tested by this probe |
| Stable supported macOS versions, clean Mac, Developer ID, notarization | Not tested |

The probe is separate from the application, its connections, Keychain, release
scripts and Swift package. It contains no real credentials, no S3 endpoint,
and no network calls. No S3 compatibility claim follows from this result.
The existing `S3Service` interface already provides prefix listing with opaque
continuation tokens, metadata and file-backed downloads; reusing it in the
extension still needs implementation and validation.

## Current build validation — 2026-09-21

The checked-in source was compiled again on the same macOS 27 beta / Apple
Silicon environment using Command Line Tools. Fixture checks, bundle plist
validation and strict nested ad-hoc signature verification passed. This run
did not register a domain, open Finder, access Keychain or repeat the historical
Finder/Quick Look validation above. No S3 integration or release validation
was performed.

## Reproduce locally

Run from the repository root on Apple Silicon with Command Line Tools installed.
The script targets arm64 and macOS 15; Intel and stable macOS runtime behavior
have not been validated. It builds only these small Swift files, runs fixture
checks and verifies plists and signatures; it does not rebuild the app or its
AWS SDK dependencies, register an extension or add a Finder domain.

```sh
bash experiments/file-provider-poc/build.sh
```

The following optional manual steps register the synthetic provider and add
its fixed `readonly-fixture` domain. Use only one checkout of this POC at a
time; remove its existing test domain and registration before rebuilding or
registering another copy.

```sh
APP="$PWD/.build/file-provider-poc/S3WorkbenchPOC.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" &&
pluginkit -a "$APP/Contents/PlugIns/Provider.appex" &&
"$APP/Contents/MacOS/Host" add
```

In Finder, select S3WorkbenchPOC under Locations and click Enable if prompted.
Select README.txt and press Space. Expect:

```text
S3Workbench File Provider POC — read-only fixture.
```

The file's read-only capability and all three mutation callbacks reject writes.
This does not prove every application's local editing behavior: macOS controls
the local replica. The immutable provider never persists any modification.
Its constant change anchor is valid only for this immutable fixture; it must
not be copied into a mutable S3 implementation.

Before rebuilding an installed probe or finishing the test, remove only its
synthetic domain and registration:

```sh
APP="$PWD/.build/file-provider-poc/S3WorkbenchPOC.app"
"$APP/Contents/MacOS/Host" remove &&
pluginkit -r "$APP/Contents/PlugIns/Provider.appex" &&
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP"
```

If removal fails or times out, keep the bundle and registration in place and
retry removal before rebuilding. The chained commands stop at the first error.
Do not manually delete the CloudStorage directory or modify other providers.
An ad-hoc signature working on this development machine does not establish
the distribution requirements; signing and provisioning must be validated
independently before release.

## Proposed feature: optional read-only S3 drive

Add an explicit **Add to Finder** action for one configured bucket/prefix.
The resulting domain lets the user browse objects, open them in other apps
and copy them out through Finder. Keep the existing S3Workbench browser and
all its features available independently. This is distinct from issue #16,
which covers drag export from the existing app.

### First-release scope

- Opt-in File Provider extension embedded in S3Workbench, one domain per
  selected bucket/prefix, with Add to Finder and Remove from Finder controls.
- Preserve exact configured access roots; restricted credentials must never
  need global bucket listing or access outside their prefix.
- Enumerate folders progressively with complete S3 pagination, bounded memory,
  cancellation and rejection of results from obsolete configuration generations.
- Fetch file contents on demand using the existing streaming download path and
  File Provider's temporary directory on the correct volume.
- Advertise read-only capabilities and reject create, modify, delete, rename,
  move and trash operations through the provider.
- Implement a documented refresh policy for external S3 additions, changes and
  deletions, with real working-set enumeration and persistent sync anchors.
- Retain usable content during transient failures; distinguish authentication,
  missing object, unavailable endpoint and cancellation without exposing secrets.
- Support explicit reconnect after configuration changes and removal of only
  the selected domain. Explain the system-managed local cache to the user.

### Technical work and decisions to resolve

- Add the extension target and embedding/signing to the existing build pipeline
  without turning this standalone probe script into the production packager.
- Reuse `S3WorkbenchCore` and `S3Service`; keep networking and credentials out
  of views. Validate extension lifecycle, concurrency and restart behavior.
- Design the least-privilege sharing of connection metadata and Keychain items
  between host and extension. Do not copy credentials into an App Group file or
  silently migrate existing credentials.
- Define stable item identity separately from displayed paths, and a reversible
  mapping for S3 keys. Handle `foo` alongside `foo/bar`, case/Unicode collisions,
  repeated slashes, dot segments and empty folder markers without normalizing
  keys, losing objects or broadening access.
- Map opaque S3 continuation tokens to File Provider pages: Apple limits page
  payloads to 500 bytes, so do not assume arbitrary S3 tokens fit directly.
- Define content and metadata version semantics; multipart ETags are not MD5
  hashes. Detect an object changing during download before returning contents.
- Choose bounded change detection for generic S3-compatible providers; do not
  assume AWS event notifications or provider-specific APIs exist.
- Verify Developer ID/provisioning/App Group requirements, notarization,
  upgrades and clean uninstall on supported stable macOS releases.

### Acceptance criteria

- [ ] Packaged app registers a File Provider domain; enable/disable UX works
  on the minimum supported stable macOS and current stable macOS.
- [ ] More than 1,000 objects and nested prefixes enumerate completely, with
  no whole-bucket load and no request outside the configured access root.
- [ ] A not-downloaded object opens through Finder/Quick Look and a normal app;
  a large download remains file-backed and memory-bounded.
- [ ] Cancelled work and removed/edited connections cannot publish stale items.
- [ ] Remote additions, modifications and deletions become visible under the
  documented refresh policy, including after extension/app restart.
- [ ] Mutation attempts cannot write to S3; externally read-only credentials
  work and errors remain actionable.
- [ ] Adversarial keys and name collisions have explicit, lossless behavior.
- [ ] Offline/unreachable/authentication failures recover without clearing
  unrelated content or leaking credentials, endpoints or real object names.
- [ ] Automated unit checks, MinIO integration, RustFS integration, Finder UI,
  large-file runtime and signed/notarized packaging evidence are recorded
  separately. Name any live provider actually tested.
- [ ] Removal affects only the selected domain and documents local-cache
  handling; the existing object browser still works without the extension.

Full bidirectional sync, offline editing, conflict resolution and Finder writes
are subsequent work. They need a separate contract covering copy/delete moves,
concurrent writers, retry recovery and data-loss prevention.

## References

- [Apple replicated File Provider](https://developer.apple.com/documentation/fileprovider/replicated-file-provider-extension)
- [Apple synchronization model](https://developer.apple.com/documentation/fileprovider/synchronizing-the-file-provider-extension)
- [Apple NSFileProviderPage](https://developer.apple.com/documentation/fileprovider/nsfileproviderpage)
- Repository `docs/ARCHITECTURE.md`, `docs/SECURITY.md`, `docs/TESTING.md` and
  `Sources/S3WorkbenchCore/S3Service.swift`.
