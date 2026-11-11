# Changelog

All notable changes to Agent Boards will be documented here. The project uses
semantic version tags after a release candidate passes the published release
gate.

## [Unreleased]

- Moved the default gateway port from 4173 (Vite's preview default, which
  could silently shadow the gateway for loopback clients) to 4747. The Apple
  Container stack now binds to `AGENT_BOARDS_BIND` (default 127.0.0.1), loads
  `.env` (caller environment wins), and refuses to start when the port is
  already in use. Existing installs: update MCP client URLs to
  `http://127.0.0.1:4747/mcp`, or set `AGENT_BOARDS_PORT=4173` to keep the old
  port.
- The Apple Container stack falls back to `gh auth token` when `GITHUB_TOKEN`
  is unset, so private repositories can be indexed without exporting a token
  (`AGENT_BOARDS_USE_GH_TOKEN=0` disables it).
- `create_backlog_item` now returns the card as saved, including required
  worker capabilities and interaction-evidence flags set after creation.
- `get_board` returns a compact summary by default (card headers, latest
  evidence per type, prerequisites, metrics); `detail: "full"` keeps the
  previous payload. MCP tool results are emitted as compact JSON.
- Replaced optional run telemetry in project KPIs with database-owned claim
  sessions. Agent time now follows claim/heartbeat lifecycle with idle-timeout
  caps, while token and cost totals remain explicitly host-reported and show
  as unavailable rather than zero when no authoritative usage was supplied.
- Added first-class work-item owners, separate active workers, owner-aware
  atomic claims, concurrent MCP worker guidance, and a live three-client claim
  and movement test.
- Added a shared migration ledger so existing installations do not re-run
  historical data repairs when a new release migration is deployed.
- Added renewable claim leases, worker heartbeats, idle-claim visibility,
  human-authorized transfer or release, audit events, and stale-worker fencing.
- Added persistent project-scoped worker identities for Codex, Claude, and
  other MCP clients, with unique handles, immutable IDs, one-time private
  resume tokens, authenticated claim operations, and registered-worker takeover.
- Added capability-aware worker registration and PostgreSQL queue routing.
  Feature, story, and task requirements are inherited into each focused work
  package; incompatible workers receive `no_compatible_work`, and human
  takeover cannot transfer a claim to an unequipped worker.

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
