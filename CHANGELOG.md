# Changelog

All notable changes to Agent Boards will be documented here. The project uses
semantic version tags after a release candidate passes the published release
gate.

## [Unreleased]

- Added first-class work-item owners, separate active workers, owner-aware
  atomic claims, concurrent MCP worker guidance, and a live three-client claim
  and movement test.
- Added a shared migration ledger so existing installations do not re-run
  historical data repairs when a new release migration is deployed.
- Added renewable claim leases, worker heartbeats, idle-claim visibility,
  human-authorized transfer or release, audit events, and stale-worker fencing.

## [0.1.0-alpha.1] - 2026-11-09

- Prepared the first open-source release candidate.
- Licensed Agent Boards under Apache License 2.0 with Datashow attribution.
- Added a focused first-run overview, replayable project workflow settings,
  an MCP connection explainer with a copyable agent instruction, configurable
  board buckets and deterministic exit criteria, and Datashow attribution in
  the application footer.
- Kept the Kanban board fixed to the viewport, moved vertical scrolling into
  individual lanes, and added collapsible state, feature, and story groups.
- Added governed delivery stages, deterministic acceptance criteria, visual
  design governance, evidence uploads, repository intelligence, and autonomous
  agent work queues.
- Added Docker Compose and Apple Container deployment recipes.
- Added linting, browser smoke tests, cross-platform CI, dependency review,
  CodeQL, OpenSSF Scorecard, SBOM generation, release checksums, and build
  provenance attestations.
- Added pinned Trivy, Gitleaks, OSV-Scanner, Semgrep CE, ShellCheck, Hadolint,
  actionlint, zizmor, and Apache-2.0 dependency-licence gates.

[Unreleased]: https://github.com/Datashow-Pty-Ltd/agent-boards/compare/v0.1.0-alpha.1...HEAD
[0.1.0-alpha.1]: https://github.com/Datashow-Pty-Ltd/agent-boards/releases/tag/v0.1.0-alpha.1
