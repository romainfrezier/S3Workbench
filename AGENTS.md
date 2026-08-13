# Repository instructions

For planned features, use the linked GitHub issue as the implementation
contract. Maintainer-approved work is listed in the
[roadmap backlog](https://github.com/romainfrezier/S3Workbench/issues?q=is%3Aissue%20state%3Aopen%20label%3Aroadmap).
GitHub Discussions are discovery, not permission to implement. Keep each change
limited to the user's request and its issue; do not expand into neighboring
items.

## Product guardrails

- S3Workbench is a deliberately simple, native macOS object browser for
  developers and operators. Prefer the smallest predictable workflow and native
  SwiftUI behavior; avoid speculative modes, abstractions, dependencies, and
  provider-specific assumptions.
- Keep S3-compatible behavior generic and preserve configured access roots.
  Never normalize object keys, load large objects entirely into memory, or let
  cancellation append stale results.
- For recursive search, preserve complete pagination, bounded memory,
  progressive results and counters, cancellation, restricted access roots,
  reveal-in-prefix behavior, and stale-result rejection.
- Keep object-table sorting local to the currently loaded rows. It must not add
  an S3 request or a second pagination model, and it must preserve selection,
  search, and pagination state.
- Keep existing data visible during refreshes. Use separate loading states and
  non-blocking errors instead of blanking unrelated content or showing modal
  alerts.
- Actionable copy comes first. Geek humor is optional secondary text and is
  never used for destructive actions, conflicts, or sensitive diagnostics.

## Architecture, security, and validation

- Preserve the target and layer boundaries in
  [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): SwiftUI presentation delegates
  through the workbench service to `S3WorkbenchCore`; views do not sign, parse,
  persist credentials, or perform S3 networking.
- Follow [docs/SECURITY.md](docs/SECURITY.md). Never log or surface credentials,
  authorization headers, signatures, session tokens, presigned query strings,
  private endpoints, or object names from real environments.
- Follow [docs/TESTING.md](docs/TESTING.md). Use `swift test` for unit coverage
  and `scripts/integration-test.sh` for S3 behavior. Report unit, MinIO,
  live-provider, packaging, and manual UI validation separately; one does not
  prove another.
- Add the smallest test that proves non-trivial behavior. Search work must cover
  continuation-token pagination, restricted access roots, cancellation, and
  stale-result rejection.

## Working safely

- Check `git status` before editing. Preserve unrelated local changes and do not
  stage, reset, reformat, or rewrite another thread's work.
- Use an isolated worktree when parallel work overlaps the same files or when
  clean validation requires it.
- Keep pull requests focused and state user impact, validation performed, and
  known limitations. Compatibility claims require evidence from the named
  provider.
- Use the repository's existing Swift and shell tooling. Do not add formatting,
  generation, or orchestration machinery solely to enforce prose guidance.
