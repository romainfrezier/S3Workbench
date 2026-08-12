# Testing

## Unit and integration tests

Run unit tests with:

```sh
swift test
```

Run the reproducible MinIO suite with:

```sh
scripts/integration-test.sh
```

The script starts an isolated Docker Compose project, creates the test bucket, exports the `S3_TEST_*` variables used by the Swift integration tests, runs `swift test`, then performs an independent MinIO smoke check. It removes its containers and volume on exit. Set `KEEP_MINIO=1` to leave the environment running for manual testing.

The pinned Linux arm64 images are MinIO `RELEASE.2025-09-07T16-13-09Z` and mc `RELEASE.2025-08-13T08-35-41Z`. The test endpoint is `http://127.0.0.1:19000`, uses Signature V4 and path-style addressing, and intentionally exercises a custom non-TLS endpoint. Override the ports or credentials through `MINIO_*` environment variables.

The integration suite covers:

- authentication and bucket listing;
- prefix navigation and opaque ListObjectsV2 continuation-token pagination;
- upload, streaming download, copy/move, and delete;
- spaces, Unicode, and reserved characters in object keys;
- presigned GET URLs;
- a real two-part multipart upload and completion with SHA-256 verification.

Retry policy is provided by the SDK and interactive cancellation aborts multipart uploads, but injected transient-failure retries and abort cleanup are not yet automated in the local suite.

The shell smoke check proves the MinIO fixture itself supports path-style SigV4, Unicode keys, download, metadata, delete, and a two-part 10 MiB multipart upload. Compatibility claims for the application must come from the Swift tests, not from the fixture smoke check alone.

## Manual transfer checks

Before release, use the app against the Compose endpoint and verify progress, cancellation, retry, download destination selection, drag and drop, Quick Look, and restart recovery. Inspect Activity Monitor while transferring a file larger than available memory to confirm memory remains bounded.

Only MinIO is covered by the local automated environment. AWS S3, R2, Wasabi, Backblaze B2, Infomaniak, and other providers require separate credentials and are not claimed as tested by this suite.

Protocol references: [Amazon S3 multipart limits](https://docs.aws.amazon.com/AmazonS3/latest/userguide/qfacts.html), [multipart upload process](https://docs.aws.amazon.com/AmazonS3/latest/userguide/mpuoverview.html), and [MinIO S3 API compatibility](https://docs.min.io/aistor/developers/s3-api-compatibility/).
