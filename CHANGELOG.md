# Changelog

All notable changes to S3Workbench are documented here. The project follows [Semantic Versioning](https://semver.org/).

## [0.3.0] - 2026-08-12

### Added

- Explicit Keep Both, Replace, or Cancel policies for upload, download, and move collisions.
- Dedicated loading, empty, and permission/error states with in-place retry actions.
- Automated restricted-credential MinIO coverage, including a direct `/bucket/prefix` root.
- Tag-only Release and DMG validation in CI, with dependency caching for normal test runs.

### Changed

- Centralized direct access-root parsing and actionable S3 authentication, region, TLS, network, and authorization errors.
- Hardened connection and custom-CA persistence rollback so failed saves do not leave partial secrets or certificate state.
- Quick Look temporary files are removed when their preview is dismissed or replaced.

## [0.2.0] - 2026-08-12

### Added

- Separate server, HTTPS, and port fields, with port 443 as the default.
- Optional direct `/bucket/prefix` access roots for restricted S3 credentials that cannot list every bucket.
- Native connection colors and one-click connection duplication, including Keychain credentials.
- A roomier native bucket list with clearer names and creation dates.

## [0.1.0] - 2026-08-12

### Added

- Native SwiftUI S3 browser for Apple Silicon Macs.
- Multiple saved connections with UUID-scoped Keychain credentials.
- Arbitrary S3 endpoints, regions, addressing policies, and custom PEM CAs.
- Bucket and prefix browsing, pagination, search, metadata, and Quick Look.
- Upload, streaming download, delete, conditional move, drag and drop, and presigned URLs.
- Progress, retry, cancellation, and bounded-memory multipart uploads.
- Reproducible digest-pinned MinIO integration environment.
- Release and DMG verification scripts.
- A persistent Add Connection action in the connection editor.
- A safe-area-correct app icon designed for the Liquid Glass visual language.

[0.1.0]: https://github.com/romainfrezier/S3Workbench/releases/tag/v0.1.0
[0.2.0]: https://github.com/romainfrezier/S3Workbench/releases/tag/v0.2.0
[0.3.0]: https://github.com/romainfrezier/S3Workbench/releases/tag/v0.3.0
