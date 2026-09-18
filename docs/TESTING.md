# Testing

## CI scope

The [Gitflow process](../CONTRIBUTING.md#gitflow) uses `main`, `develop`,
`release/*` and `hotfix/*`. Component workflows validate pushes and PRs for
these branches, including PR retargeting. The lightweight **Gitflow branch
policy** check runs on every PR without path filters, including documentation
changes. Run `ruby .github/check-gitflow.rb --test` to test its routing rules.

Web changes run website validation and CodeQL for JavaScript/TypeScript and
GitHub Actions. Native sources, package dependencies, resources, integration
fixtures and packaging scripts run Swift tests and CodeQL Swift. Each workflow
also runs when its own configuration changes. Documentation-only changes do not
compile the application. Mixed changes run both sets of checks.

Native release tags (`v*`, excluding `*-site`) run native packaging; website
release tags (`v*.*.*-site`) publish only the website image. Website images are
also published for relevant changes merged to `main`.

CodeQL uses the checked-in advanced workflows; GitHub's automatic default setup
must remain disabled to avoid duplicate scans of every language. Both CodeQL
workflows retain weekly full scans and manual dispatch. Validate the path and
tag routing with `ruby .github/test-workflow-triggers.rb`.

## Unit and integration tests

Run unit tests with:

```sh
swift test
```

Run the same integration suite against either pinned local server:

```sh
scripts/integration-test.sh                         # MinIO
S3_TEST_PROVIDER=rustfs scripts/integration-test.sh  # RustFS 1.0.0
```

The script starts an isolated Docker Compose project, creates the test buckets and restricted account, checks the fixture with `mc`, then runs the same Swift tests against the selected endpoint. It removes its containers and volume on exit. Set `KEEP_S3=1` to keep the environment for manual testing (`KEEP_MINIO=1` remains supported). Unknown providers fail before starting containers.

After the S3 suite, the script writes connection metadata and UUID-scoped Keychain credentials in one test process and reads them from a fresh process before cleaning them up. This is the automated restart-persistence check.

The images are pinned by digest: MinIO `RELEASE.2025-09-07T16-13-09Z`, RustFS `1.0.0`, and mc `RELEASE.2025-08-13T08-35-41Z`. The MinIO/mc fixture images target Linux arm64; the RustFS digest is its multi-platform image index. The test endpoint is `http://127.0.0.1:19000`, uses Signature V4 and path-style addressing, and intentionally exercises a custom non-TLS endpoint. The fixture also creates a restricted account that can access only the test bucket, proving both permission errors and direct `/bucket/prefix` navigation. Override the ports or credentials through the existing `MINIO_*` variables for either provider. The RustFS Compose override reuses the fixture service names, disposable volume and initialization script; no app-specific RustFS behavior is introduced. Both exposed ports bind to `127.0.0.1`. These static credentials belong only to the disposable local test environment.

For simultaneous runs, choose different `COMPOSE_PROJECT_NAME`, `MINIO_API_PORT` and `MINIO_CONSOLE_PORT` values. Never reuse a retained MinIO project/volume for RustFS or vice versa.

The integration suite covers:

- authentication and bucket listing;
- prefix navigation and opaque ListObjectsV2 continuation-token pagination;
- recursive search across more than 1,000 objects, atomic local-index publication, and a second indexed query with no additional S3 listing request;
- upload, streaming download, copy/move, and delete;
- spaces, Unicode, and reserved characters in object keys;
- presigned GET URLs;
- a real two-part multipart upload and completion with SHA-256 verification.

Retry policy is provided by the SDK and interactive cancellation aborts multipart uploads, but injected transient-failure retries and abort cleanup are not yet automated in the local suite.

The shell smoke check proves the selected server fixture itself supports path-style SigV4, Unicode keys, download, metadata, delete, and a two-part 10 MiB multipart upload. Compatibility claims for the application must come from the Swift tests, not from the fixture smoke check alone.

## Manual transfer checks

Before release, use the app against the Compose endpoint and verify progress, cancellation, retry, download destination selection, drag and drop, Quick Look, and restart recovery. Inspect Activity Monitor while transferring a file larger than available memory to confirm memory remains bounded.

## Provider validation evidence

| Environment | Reproducible fixture | Application validation |
| --- | --- | --- |
| MinIO | Pinned Compose server and restricted user | Existing Swift integration suite; see the linked issue for current run evidence |
| RustFS 1.0.0 | Pinned Compose server and the same restricted-user setup; fixture smoke passed on 2026-09-17 | Same Swift integration suite; see issue #36 for current run evidence |
| Amazon S3, Cloudflare R2, Wasabi, Backblaze B2 | User-supplied endpoint, region and credentials | No live-provider run recorded by this local suite |

Current RustFS validation is tracked in [issue #36](https://github.com/romainfrezier/S3Workbench/issues/36). A fixture smoke pass is not an application integration pass. Unit checks, server smoke checks, Swift integration, manual UI checks, and packaged-app checks are reported separately.

For RustFS, use the [official container configuration](https://github.com/rustfs/rustfs/blob/1.0.0/docker-compose-simple.yml) as the upstream reference. The local fixture tests S3 protocol behavior; it does not certify every provider feature or production configuration.

Protocol references: [Amazon S3 multipart limits](https://docs.aws.amazon.com/AmazonS3/latest/userguide/qfacts.html), [multipart upload process](https://docs.aws.amazon.com/AmazonS3/latest/userguide/mpuoverview.html), and [MinIO S3 API compatibility](https://docs.min.io/aistor/developers/s3-api-compatibility/).
