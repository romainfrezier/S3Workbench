# Contributing to S3Workbench

Thanks for helping make S3-compatible storage easier to use on macOS.

## Before opening an issue

- Use the bug form for reproducible defects and include the provider, endpoint shape, addressing style, macOS version, and app version.
- Never include access keys, secrets, signed headers, presigned URLs, private object names, or internal hostnames.
- Use GitHub Discussions for questions and early ideas.
- Report security issues through a private security advisory as described in [docs/SECURITY.md](docs/SECURITY.md).

## Development setup

You need an Apple Silicon Mac, macOS 15+, Xcode 26+, Swift 6.2+, and Docker Desktop for integration tests.

```sh
git clone https://github.com/romainfrezier/S3Workbench.git
cd S3Workbench
swift test
scripts/integration-test.sh
```

## Pull requests

1. Fork the repository and create a focused branch.
2. Keep the UI, domain, S3 client, credentials, persistence, and transfer boundaries intact.
3. Add the smallest test that proves non-trivial behavior.
4. Run:

   ```sh
   swift test
   swift build -c release
   ```

5. For S3 behavior, also run `scripts/integration-test.sh` and state exactly which providers were tested.
6. Describe user impact, validation, and known limitations in the pull request.

Do not add provider-specific assumptions to generic endpoint handling, log secrets or signed URLs, normalize object keys, or load large files entirely into memory.

By contributing, you agree that your contribution is licensed under the MIT License.

