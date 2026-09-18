# Contributing to S3Workbench

Thanks for helping make S3-compatible storage easier to use on macOS.

## Before opening an issue

- Check the existing issues, including the maintainer-approved
  [roadmap backlog](https://github.com/romainfrezier/S3Workbench/issues?q=is%3Aissue%20state%3Aopen%20label%3Aroadmap),
  before proposing overlapping work.
- Use the bug form for reproducible defects and include the provider, endpoint shape, addressing style, macOS version, and app version.
- Never include access keys, secrets, signed headers, presigned URLs, private object names, or internal hostnames.
- Use [GitHub Discussions](https://github.com/romainfrezier/S3Workbench/discussions) for questions and early ideas; an idea becomes implementation work only after it has a scoped issue.
- Report security issues through a private security advisory as described in [docs/SECURITY.md](docs/SECURITY.md).

## Development setup

You need an Apple Silicon Mac, macOS 15+, Xcode 26+, Swift 6.2+, and Docker Desktop for integration tests.

```sh
git clone https://github.com/romainfrezier/S3Workbench.git
cd S3Workbench
git switch develop
swift test
scripts/integration-test.sh
```

## Gitflow

`main` contains released code; `develop` is the default integration branch.
Use standard Git commands and pull requests; the git-flow extension is optional.

| Branch | Start from | Pull request destination |
| --- | --- | --- |
| `feature/<issue>-<name>` | `develop` | `develop` |
| `bugfix/<issue>-<name>` | The branch needing the fix | `develop`, `release/*` or `hotfix/*` |
| `chore/<name>` | `develop` | `develop` |
| `release/<version>` | `develop` | `main`, then `develop` |
| `hotfix/<version>` | `main` | `main`, then `develop` and any open release |

Dependabot and Codex branches (`dependabot/*` and `codex/*`) also target
`develop`. They follow the same validation and release process as feature
branches. Do not merge `develop` or a feature branch directly into `main`.
Release and hotfix PRs into `main` must come from this repository.

1. Fetch and branch from the current remote base, for example
   `git fetch origin` followed by
   `git switch -c feature/123-example origin/develop`.
2. Open a PR into `develop`; wait for every applicable CI and CodeQL check on
   the latest commit and resolve review conversations before merging.
3. Merge with a **merge commit**. Keep merge commits for releases, hotfixes and
   back-merges too; do not squash or rebase shared branch history.
4. To prepare a release, create `release/<version>` from `origin/develop`.
   Freeze features, update the changelog and finish validation on this branch.
   Native and website versions are independent: use `release/0.8.0` for an app
   release or `release/0.2.0-site` for a website-only release. A site-only release
   must not accidentally include unreleased native changes from `develop`.
5. Merge the release PR into `main`, then create the matching `v<version>` tag
   on that exact merge commit and follow [the packaging procedure](docs/PACKAGING.md).
   Website images publish from relevant `main` changes or `v*.*.*-site` tags;
   integration and stabilization branches never publish images.
6. Open the release/hotfix branch's back-merge PR into `develop` before deleting
   it. Back-merge hotfixes into an open release too. If conflicts require a
   separate branch, create `bugfix/<version>-backmerge` from the destination,
   merge the release/hotfix into it, resolve conflicts and open the PR.
   Never reset `develop` or force-push a shared branch.

`main` and `develop` require a PR, the **Gitflow branch policy** check and
resolved conversations; force pushes and deletion are disabled. The policy
checks branch routing, not test results. Component CI and CodeQL remain scoped
by changed paths and must be reviewed before merging. They are not globally
required checks because a path-skipped workflow would block unrelated PRs.
Romain can merge his own PRs without another maintainer's approval, using the
PR-only exception described below; the existing branch protections still apply.
Automatic branch deletion is disabled so release/hotfix branches survive until
their back-merges are complete.

## Pull requests

### Maintainer validation

Romain Frezier (`@romainfrezier`) must personally review the final diff and the
validation evidence before a PR is merged. Passing CI, an automated review or
an agent's summary does not replace that decision. Any later code change needs
another review of the updated diff and its checks.

Only Romain's GitHub account can merge into `main` or `develop`. The
**Maintainer-controlled merges** ruleset restricts branch updates and requires
review, with a PR-only bypass assigned to his account. Romain can use that
exception to merge his own PRs without an impossible self-approval. It does not
bypass the separate protections requiring the Gitflow check, resolved
conversations and a PR, or allow force pushes or branch deletion.

Contributors and Dependabot may open PRs; they do not have to impersonate Romain
or recreate their PRs under his account. `.github/CODEOWNERS` designates him as
the reviewer for all files. He reviews other authors' PRs and decides whether to
merge them. Auto-merge is disabled for the repository.

Agents may prepare changes, run checks and report results, but must wait for
Romain's explicit approval of the final PR before merging. They must not submit
an approval using his authenticated account on his behalf.

GitHub identifies the authenticated account, so a tool using Romain's credentials
has the same permissions. The instruction to wait for his human approval still
applies to agents; the account-level rule cannot distinguish a person from their
token.

Publishing a release/tag or deploying to production also requires Romain's
explicit instruction for that operation. Approval to prepare or merge a PR is
not permission to release or deploy. Publishing a website container image in CI
does not by itself deploy it to the production server.

### Preparing a contribution

1. For planned features, work from a scoped issue and link it from the pull request.
2. Fork the repository if needed and create a focused branch using the Gitflow table above.
3. Keep the UI, domain, S3 client, credentials, persistence, and transfer boundaries intact.
4. Add the smallest test that proves non-trivial behavior.
5. Run:

   ```sh
   swift test
   swift build -c release
   ```

6. For S3 behavior, also run `scripts/integration-test.sh` and state exactly which providers were tested.
7. Describe user impact, validation, and known limitations in the pull request.

Do not add provider-specific assumptions to generic endpoint handling, log secrets or signed URLs, normalize object keys, or load large files entirely into memory.

By contributing, you agree that your contribution is licensed under the MIT License.
