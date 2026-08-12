## Summary

<!-- What changed, why, and what does the user experience differently? -->

## Validation

- [ ] `swift test`
- [ ] `swift build -c release`
- [ ] `scripts/integration-test.sh` for S3 behavior
- [ ] Light and Dark Mode checked for UI changes

Tested providers and endpoint styles:

## Security and compatibility

- [ ] No credentials, signatures, presigned URLs, or private endpoints are present.
- [ ] Large transfers remain file-backed or bounded in memory.
- [ ] The change does not assume AWS hostnames or normalize object keys.

## Known limitations

<!-- State what was deliberately not tested or implemented. -->
