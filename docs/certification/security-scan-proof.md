# Security and release scan proof

This record is updated for each release candidate. Automated checks are
maintainer evidence, not independent certification.

## Candidate

- Date: 9 November 2026
- Candidate: `v0.1.0-alpha.1`
- Evidence baseline: `293bead17d7bcbf4467d0e84f0bfaaeb2aac355b`
- CI: [main run 42558870998](https://github.com/Datashow-Pty-Ltd/agent-boards/actions/runs/42558870998)
- Open-source security: [main run 42558870962](https://github.com/Datashow-Pty-Ltd/agent-boards/actions/runs/42558870962)
- Reviewer: Datashow maintainer
- Intended scope: trusted local or self-hosted `v0.1.0-alpha.1` release

## Current local evidence

| Control | Required result | Status |
| --- | --- | --- |
| ESLint | Zero errors and warnings | Pass |
| TypeScript | All workspaces pass | Pass |
| Unit and contract tests | 25 tests pass | Pass; 18 MCP, three repository-intelligence, and four web tests |
| Production builds | Web, MCP, and repository intelligence build | Pass |
| Production dependency audit | No high-or-critical findings | Pass; no known production vulnerabilities reported |
| Secret-pattern scan | No tracked or untracked source credential patterns | Pass; 159 text source files scanned |
| CycloneDX SBOM | Valid document generated | Pass; 284 production components |
| Source archive verification | Allowlisted source only | Pass; 30 uniquely ordered migrations and six pinned workflows verified |
| Apple Container stack | Build and start the six-container stack | Pass |
| Packaged web startup | Root document served without development-server compilation | Pass; 26 ms local request |
| Live MCP gateway | Discovery and read operation pass | Pass |
| Claude Code | Authenticated discovery and read pass | Pass; four projects returned |
| Browser smoke test | Portfolio → project → board and drawer keyboard path | Pass; 825 ms Playwright run |
| Docker Compose integration | Build the full stack; exercise MCP through OpenResty and the browser path | Pass in GitHub-hosted Linux CI |

## Public-repository controls

CodeQL, dependency review, OpenSSF Scorecard, branch protection, secret
scanning, push protection, and provenance attestations are enabled or recorded
after the repository becomes public. Their workflows are committed but this
pre-publication record does not claim results that do not yet exist.

## Alpha limitations

- Complete the disposable-project governed mutation and evidence-upload matrix
  for Codex and Claude.
- Complete narrow/mobile visual baselines.
- Shared public-Internet hosting is not supported; this alpha is for trusted
  local or self-hosted use.
