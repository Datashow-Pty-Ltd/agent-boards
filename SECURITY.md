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
