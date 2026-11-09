# Open-source readiness

This document is deliberately candid. Passing the automated checks means the
tree is internally consistent; it does not by itself make the service safe for
public Internet hosting.

## Automated release gate

- [x] TypeScript typecheck
- [x] unit and contract tests
- [x] production builds
- [x] source-size guardrails
- [x] portable Docker Compose configuration
- [x] documented Docker Compose and Apple Container build/start recipes
- [x] first release scoped to trusted local or self-hosted use
- [x] live MCP request through OpenResty
- [x] real Claude Code discovery and tool invocation
- [x] shared page-title and section-title typography contracts
- [x] allowlisted source archive excludes local screenshots, build output,
      caches, editor state, and the obsolete vendored chart package

## Required before publishing the repository

- [ ] Select and add an open-source `LICENSE` (legal/project-owner decision).
- [ ] Confirm the public project and package names.
- [ ] Review seed data and history for private URLs, credentials, and customer
      information.
- [ ] Add at least one browser interaction test for Portfolio → project → Board
      and keyboard operation of the work-item drawer.
- [ ] Add repository-intelligence parser fixtures and MCP error-path tests.
- [ ] Capture narrow/mobile visual baselines; the current audit covers only a
      wide viewport.

## Future enhancements

- Authenticated shared hosting with organisations, human and agent principals,
  project memberships, scoped OAuth access, PostgreSQL row-level security,
  agent claim leases, tenant-isolated event streams, rate limits, object
  storage, and an upload malware/content policy.

## Manual client matrix

| Client | Discovery | Read tool | Governed mutation | Evidence upload |
| --- | --- | --- | --- | --- |
| Codex | required | required | disposable project | disposable project |
| Claude Code | verified | verified | pending disposable project | pending disposable project |

The safe automated Claude smoke test is intentionally read-only. Expand the
matrix on a disposable project before tagging a release.
