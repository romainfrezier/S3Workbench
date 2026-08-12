<p align="center">
  <img src="Assets/AppIcon-1024.png" width="144" height="144" alt="S3Workbench app icon">
</p>

<h1 align="center">S3Workbench</h1>

<p align="center">
  A native macOS browser for S3-compatible object storage.<br>
  Finder-like navigation with the clarity of a professional database tool.
</p>

<p align="center">
  <a href="https://github.com/romainfrezier/S3Workbench/actions/workflows/ci.yml"><img src="https://github.com/romainfrezier/S3Workbench/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/romainfrezier/S3Workbench/releases/latest"><img src="https://img.shields.io/github/v/release/romainfrezier/S3Workbench?display_name=tag" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-15%2B-000000?logo=apple" alt="macOS 15 or later">
  <img src="https://img.shields.io/badge/Apple%20Silicon-arm64-000000?logo=apple" alt="Apple Silicon arm64">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/romainfrezier/S3Workbench" alt="MIT license"></a>
</p>

> [!IMPORTANT]
> S3Workbench is S3-compatible first, not AWS-specific. Every connection keeps its own endpoint, region, addressing policy, TLS policy, and Keychain-protected credentials.

## Why S3Workbench?

Most desktop S3 tools either assume AWS endpoints or feel like generic file-transfer utilities. S3Workbench is built for people who move between local MinIO, private infrastructure, and hosted object storage every day.

- Save and switch between multiple independent storage connections.
- Color-code and duplicate saved connections.
- Configure arbitrary servers without embedding a protocol, plus HTTPS, port, region, and addressing settings.
- Open an optional `/bucket/prefix` access path directly when credentials cannot list every bucket.
- Browse buckets and prefixes with native macOS tables, navigation, search, inspector, keyboard commands, and Quick Look.
- Upload, stream downloads, delete, move, drag and drop, inspect metadata, and create presigned URLs.
- Choose Keep Both, Replace, or Cancel before a transfer or move can overwrite a destination.
- Track transfers with progress, cancellation, retry, and bounded-memory multipart uploads.
- Keep credentials out of configuration files and logs.

## Compatibility

| Provider | Configuration support | Automated conformance |
| --- | --- | --- |
| MinIO | Custom endpoint, path-style, HTTP/HTTPS | ✅ Tested locally |
| AWS S3 | Regional endpoint, path/virtual addressing | ◻︎ Not yet tested with live credentials |
| Cloudflare R2 | Custom endpoint and `auto` region | ◻︎ Not yet tested with live credentials |
| Wasabi | Regional custom endpoint | ◻︎ Not yet tested with live credentials |
| Backblaze B2 | Regional S3 endpoint | ◻︎ Not yet tested with live credentials |
| Private S3 implementations | Arbitrary HTTP/HTTPS endpoint | Provider-dependent |

Compatibility claims are deliberately conservative: only MinIO is covered by the automated suite today.

## Install

S3Workbench requires macOS 15 or later on Apple Silicon.

1. Download `S3Workbench.dmg` from the [latest release](https://github.com/romainfrezier/S3Workbench/releases/latest).
2. Open the disk image and drag S3Workbench to Applications.
3. Launch the app and add your first connection.

The current community build is ad-hoc signed because no Developer ID identity is available. macOS may require **Control-click → Open** on first launch. See [Packaging and distribution](docs/PACKAGING.md) for the exact Gatekeeper limitation and notarized-build workflow.

## Connection model

Each saved connection contains:

- a display name;
- a server name, HTTPS setting, and port (`443` by default);
- an optional direct access path such as `/etickets` or `/bucket/prefix`;
- a sidebar color;
- a signing region;
- path-style, virtual-hosted-style, or automatic addressing;
- system trust or a connection-scoped custom CA certificate;
- an access key and secret access key stored under an opaque connection UUID in macOS Keychain.

Automatic addressing is compatibility-first and prefers path-style for arbitrary endpoints. Explicit virtual-hosted style remains available when DNS and certificates cover bucket subdomains.

When an access path is configured, S3Workbench tests and opens that bucket/prefix directly instead of requiring `ListAllMyBuckets`. This supports credentials intentionally restricted to one remote root.

## Security

- Credentials are stored in macOS Keychain, never in profile JSON.
- Authorization headers, credentials, signatures, session tokens, and presigned query values are redacted from surfaced errors.
- System TLS verification is the default; a custom PEM CA can be scoped to one connection.
- Disabling TLS verification is intentionally unsupported. Plain HTTP remains available for explicitly configured local/private endpoints and is visibly marked as insecure.
- Presigned URLs are bearer credentials and should be shared carefully.

Please report vulnerabilities privately using the repository's [security advisory form](https://github.com/romainfrezier/S3Workbench/security/advisories/new), not a public issue. Read the full [security policy](docs/SECURITY.md).

## Architecture

```text
SwiftUI views
    ↓
Workbench service + transfer coordinator
    ↓
S3WorkbenchCore domain API
    ↓
AWS SDK for Swift + app-owned SigV4 presigner
    ↓
Any explicitly configured S3-compatible endpoint
```

The UI contains no signing, XML, Keychain, or networking logic. The AWS SDK handles the S3 protocol surface, while the app owns endpoint policy, persistence, TLS configuration, error redaction, transfer orchestration, and custom-endpoint presigning. More detail is available in [Architecture](docs/ARCHITECTURE.md).

## Build and test

Requirements:

- Apple Silicon Mac;
- macOS 15 or later;
- Xcode 26 or later;
- Docker Desktop for the MinIO integration suite.

```sh
swift test
scripts/integration-test.sh
scripts/package-dmg.sh
LAUNCH_TEST=1 scripts/verify-dmg.sh
```

The integration environment is isolated, pinned by container digest, and removed on exit. It covers authentication, restricted bucket permissions, direct access roots, buckets, prefixes, pagination, unusual object names, metadata, upload/download/delete/move, presigned GET, and multipart upload with SHA-256 verification. See [Testing](docs/TESTING.md).

## Project status

S3Workbench is an early public release. The current product priority is fast,
cancellable recursive search with clear, non-blocking loading states. See the
[product roadmap](ROADMAP.md) for priorities, acceptance criteria, and explicit
non-goals.

## Contributing

Issues and pull requests are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md), follow the [Code of Conduct](CODE_OF_CONDUCT.md), and use GitHub Discussions for usage questions and ideas that are not yet actionable bug reports.

## License

S3Workbench is available under the [MIT License](LICENSE).
