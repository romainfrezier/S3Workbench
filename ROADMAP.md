# S3Workbench roadmap

S3Workbench is a deliberately simple, native macOS browser for S3-compatible
object storage. It is built for developers and operators who need to find,
inspect, and move objects without learning a cloud console.

This file is the product direction, not a release promise. Priorities move only
after an explicit product decision; dates and completion percentages are omitted
until the work is actually scheduled.

## Product principles

- Keep the app understandable without documentation. Prefer one predictable
  workflow over modes, query languages, and provider-specific switches.
- Remain S3-compatible first. A core feature must work with MinIO and avoid AWS
  hostname or account assumptions.
- Use native macOS controls and conventions before custom UI or dependencies.
- Keep object keys byte-for-byte meaningful. Never treat prefixes as real
  directories or silently normalize keys.
- Keep memory bounded, network work cancellable, and existing content visible
  during refreshes.
- Put actionable information before personality. Geek humor may support a state,
  but must never replace an error, hide progress, expose sensitive data, or
  trivialize a destructive operation.

The current feature set is summarized in [README.md](README.md). Implementation
boundaries live in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), security rules in
[docs/SECURITY.md](docs/SECURITY.md), and validation levels in
[docs/TESTING.md](docs/TESTING.md).

## P0 — Recursive search and loading experience

The current search is a prefix filter for the displayed location. The next
product priority is a real recursive search below the current prefix.

### Search behavior

- Pressing Return starts a case-insensitive substring search over the complete
  relative object key below the current prefix.
- The search never escapes a connection's configured access root.
- S3 has no server-side substring search. Scan `ListObjectsV2` without a
  delimiter, follow every continuation token, and filter each page locally.
- Publish flat results progressively. Show the object name, relative path, size,
  modification date, and storage class.
- Display the scanned-object count and match count. Do not invent a percentage
  because S3 does not provide the total work in advance.
- Allow cancellation and an explicit retry. An empty query exits search and
  restores normal browsing.
- Preserve inspection, Quick Look, download, rename, delete, and presigned URL
  actions. Add **Reveal in Prefix** to return to normal browsing at the object's
  parent and select it.
- Cancel and discard the active scan when its connection, bucket, prefix, or
  query context becomes stale. Late pages from an old scan must not change the
  current results.

### Loading and error states

- Delay visible loading indicators by 200 ms to avoid flashing for fast calls.
- On the first load with no data, use a centered native `ProgressView` with a
  clear title and one secondary line.
- During refresh, keep the current table visible and show a compact,
  non-blocking activity indicator.
- During search, switch from the centered initial loader to a bottom activity
  bar as soon as results exist. The bar contains the spinner, scanned count,
  match count, and **Cancel**.
- If refresh or search fails while data is visible, retain the data and show an
  inline banner with the real error and **Retry**. Only an initial failure may
  replace an empty view.
- Loading, refresh, pagination, search, and transfer activity are separate
  states. One global boolean must not blank unrelated UI.
- State changes and result counts must be usable with VoiceOver and keyboard
  navigation.

Use one stable secondary line per operation rather than rotating messages:

| State | Secondary copy |
| --- | --- |
| Loading buckets | “Asking S3 where it put everything…” |
| Loading a prefix | “Following the slashes…” |
| Recursive search | “Walking the prefix tree. S3 made us do it.” |
| No matches | “No matches. The needle may be in another bucket.” |
| Empty prefix | “Nothing here. Impressively lightweight.” |
| Network failure | “The network took an unscheduled coffee break.” |
| Access denied | “S3 said nope. Check the credentials and permissions.” |
| Other service failure | “The cloud returned a plot twist.” |
| Cancelled search | “Search cancelled. The objects remain mysterious.” |

The error category or actionable diagnostic is always shown before this copy.
Confirmation dialogs for delete, replace, and move remain factual.

### Acceptance criteria

- MinIO integration coverage includes more than 1,000 objects across nested
  prefixes, with matches beyond the first page.
- Tests cover Unicode, spaces, reserved characters, case differences, matches
  in parent path segments, no matches, and an invalid continuation token.
- Results appear page by page; counters remain accurate; cancellation produces
  no late additions.
- A restricted `/bucket/prefix` connection never scans outside that root.
- Refresh and failed refresh keep existing rows visible.
- Quick Look, object actions, and **Reveal in Prefix** work from search results.
- Manual macOS verification covers the 200 ms delay, keyboard operation,
  VoiceOver announcements, cancellation, retry, and non-blocking banners.

## P1 — Small developer shortcuts

After recursive search is proven in real use:

- Copy an object's raw key or `s3://bucket/key` URI.
- Navigate directly to a key or S3 URI within the current connection and access
  root.
- Pin a bucket/prefix location under its connection in the sidebar.

These should remain small additions to existing menus and navigation, not a new
command system.

## P1 — Easy distribution through Homebrew

Make installation and terminal-driven upgrades easy for the developer audience,
without adding an updater inside the app or requiring Apple membership first.

- Publish versioned release assets such as `S3Workbench-0.4.0.dmg` on GitHub
  Releases, with a SHA-256 checksum for each asset.
- Create a small `romainfrezier/homebrew-s3workbench` tap containing a
  `s3-workbench` cask with the version, checksum, release URL, app artifact, and
  homepage.
- Document the first install:

  ```sh
  brew tap romainfrezier/s3workbench
  brew install --cask s3-workbench
  ```

- Document upgrades:

  ```sh
  brew update
  brew upgrade --cask s3-workbench
  ```

- Keep the cask update mechanical and reviewable: one release changes the
  version, URL, and checksum; no install script or custom updater is needed.
- Consider an official `homebrew/cask` submission only after the release naming,
  signing, and maintenance process is stable.
- Homebrew is an installation/update channel, not an in-app update mechanism.
  Developer ID signing, notarization, and later Sparkle remain separate options
  if a seamless in-app updater becomes worth the annual Apple membership cost.

### Acceptance criteria

- A clean Apple Silicon Mac can install the latest release from the personal
  tap with `brew install --cask s3-workbench`.
- A machine with the previous cask version upgrades with
  `brew upgrade --cask s3-workbench` and preserves the existing app data and
  Keychain credentials.
- Homebrew rejects a corrupted or mismatched artifact through the recorded
  checksum.
- The release documentation clearly distinguishes Homebrew updates from
  Sparkle/in-app updates and from Apple signing/notarization.

## P2 — Folder operations, if usage validates them

- Upload a local folder while preserving its relative object-key structure.
- Download a prefix recursively while recreating its local hierarchy.
- Copy objects or prefixes between locations on the same connection using
  server-side copy, including multipart copy above 5 GiB.

Do not add recursive move or delete with this work. Promote these items only
after recursive search and small shortcuts are stable and user demand is clear.

## Not planned for now

- Local-to-S3 synchronization or mirroring; specialized tools already cover it.
- Bucket creation, deletion, policies, lifecycle, replication, or other storage
  administration.
- Regex, glob, saved queries, advanced filters, or a local search index.
- Transfer resumption after application termination.
- Full AWS profile, SSO, or credential-provider-chain support.
- Object-version browsing and restoration.
- Expanded presigned URL workflows.

## Maintaining this roadmap

- A feature pull request may update this file only when the feature's status or
  an explicit product decision changes.
- Do not mark work complete from local code alone. Distinguish unit tests, MinIO
  integration, live-provider checks, packaged-app checks, and manual UI proof.
- Newly proposed work belongs in the smallest fitting priority or in **Not
  planned for now**; do not quietly expand an adjacent item.
