# Architecture

S3Workbench is split into two Swift targets:

- `S3Workbench`: SwiftUI presentation, commands, view models, and composition.
- `S3WorkbenchCore`: S3 domain models, validation, Keychain access, connection metadata persistence, AWS SDK adapter, and transfer orchestration.

The UI depends on an app-level service protocol. It never constructs signed requests, parses S3 XML, or handles credentials directly.

## S3 implementation decision

The MVP uses the AWS SDK for Swift behind `S3Service`. The generated S3 client already handles Signature V4, XML edge cases, pagination, retries, presigning, streaming byte streams, and multipart primitives. This is lower-risk than maintaining a second S3 protocol implementation.

Compatibility settings are explicit:

- every profile has its own endpoint and signing region;
- addressing can be path, virtual-hosted, or automatic;
- automatic addressing uses compatibility-first path style for arbitrary endpoints; users can explicitly select virtual-hosted style when their DNS and certificates support it;
- optional request checksums are not forced, avoiding `aws-chunked` on providers that do not accept it;
- credentials are supplied from Keychain, never profile JSON;
- provider-specific APIs and AWS hostname assumptions are excluded.

The adapter is narrow enough to replace its transport or add a compatibility fallback if a tested provider demonstrates a concrete SDK limitation.

## Persistence and security

Connection names, endpoints, region, addressing policy, and TLS policy are JSON metadata in Application Support. Access and secret keys are generic-password Keychain items keyed by an opaque connection UUID. Logging uses redacted domain errors and must never include authorization headers, secrets, or presigned query strings.

System TLS trust is the default. A custom PEM CA can be scoped to one connection. Disabling verification is intentionally unsupported and fails closed. HTTP endpoints are allowed because local and private S3 deployments are a core use case, with a visible warning in the connection editor.

## Transfers

Downloads are file-backed and streamed. Uploads use file-backed SDK streams; large files use multipart upload with bounded part sizes. Rename is copy then delete and is therefore non-atomic. The source is deleted only after a successful copy response.

## UI

Standard SwiftUI `NavigationSplitView`, `Table`, `inspector`, toolbar, sheets, commands, and Quick Look APIs provide native macOS behavior and automatically adopt Liquid Glass on current systems. Glass remains a navigation/control layer; the object table and inspector content remain clear and opaque. The deployment target is macOS 15, with macOS 26 enhancements availability-gated.

## Sources consulted

- [Apple: Adopting Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass)
- [Apple: Keychain items](https://developer.apple.com/documentation/security/keychain-items)
- [Apple: Manual server trust](https://developer.apple.com/documentation/foundation/performing-manual-server-trust-authentication)
- [AWS SDK for Swift](https://docs.aws.amazon.com/sdk-for-swift/latest/developer-guide/home.html)
- [AWS Signature Version 4](https://docs.aws.amazon.com/AmazonS3/latest/developerguide/sig-v4-authenticating-requests.html)
- [AWS S3 multipart limits](https://docs.aws.amazon.com/AmazonS3/latest/userguide/qfacts.html)
- [MinIO S3 compatibility](https://min.io/docs/minio/linux/reference/s3-api-compatibility.html)
