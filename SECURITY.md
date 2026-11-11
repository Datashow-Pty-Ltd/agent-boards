# Security policy

## Supported versions

Until the first stable release, only the latest commit on the default branch is
supported.

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability. Use the repository
host's private security-advisory feature and include reproduction steps,
affected endpoints, and impact. Maintainers should acknowledge a report within
seven days.

## Deployment warning

The default stack is for trusted local development. Its PostgREST anonymous
role has broad project access. Do not publish port 4747 to an untrusted network
without authentication, authorization, tenant isolation, upload controls, and
rate limiting.

The Apple Container stack forwards a GitHub token to the repository-intelligence
container. When `GITHUB_TOKEN` is unset it falls back to the GitHub CLI's
credential, which is usually broader than indexing needs; export a read-only
fine-grained token or set `AGENT_BOARDS_USE_GH_TOKEN=0`.
