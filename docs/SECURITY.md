# Security policy

## Supported versions

Security fixes are provided for the latest published release.

| Version | Supported |
| --- | --- |
| 0.4.x | ✅ |

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability and do not include real credentials, signed requests, presigned URLs, private endpoints, or object names in reports.

Use GitHub's [private security advisory form](https://github.com/romainfrezier/S3Workbench/security/advisories/new). Include the affected version, impact, reproduction steps with sanitized fixtures, and any suggested mitigation. You should receive an acknowledgement within seven days. Disclosure will be coordinated after a fix is available.

## Security model

- Secrets are stored only in macOS Keychain and are never serialized with connection profiles.
- Keychain attributes contain an opaque UUID rather than endpoint or account details.
- System TLS validation is the safe default. A custom PEM CA can be scoped to an individual connection.
- Disabling TLS verification is intentionally unsupported. Plain HTTP is available only when explicitly configured and exposes credentials and object contents to the network.
- Presigned URLs are bearer credentials. The app does not log their query strings.
- User-facing errors redact authorization headers, credentials, signatures, and session tokens.
- Download destinations and upload sources are user-selected. The app does not crawl unrelated files.
- Delete and move operations require explicit user actions. S3 move is copy-then-delete and is not atomic.

No Developer ID identity is bundled in the repository. Release scripts use Developer ID signing and notarization only when explicitly configured; otherwise they apply ad-hoc signing and document Gatekeeper behavior.
