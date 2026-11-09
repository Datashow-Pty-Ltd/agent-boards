# Security and release scan proof

This record is updated for each release candidate. Automated checks are
maintainer evidence, not independent certification.

## Candidate

- Date: 9 November 2026
- Commit: pending final certification commit
- Reviewer: Datashow maintainer
- Intended scope: trusted local or self-hosted v0.1 release

## Current local evidence

| Control | Required result | Status |
| --- | --- | --- |
| ESLint | Zero errors and warnings | Pass |
| TypeScript | All workspaces pass | Pass |
| Unit and contract tests | 18 tests pass | Pass |
| Production builds | Web, MCP, and repository intelligence build | Pass |
| Production dependency audit | No high-or-critical findings | Pass; no known production vulnerabilities reported |
| Secret-pattern scan | No tracked or untracked source credential patterns | Pass; 138 text source files scanned |
| CycloneDX SBOM | Valid document generated | Pass; 284 production components |
| Source archive verification | Allowlisted source only | Pass; 29 uniquely ordered migrations and five pinned workflows verified |
| Apple Container stack | Build and start the six-container stack | Pass |
| Packaged web startup | Root document served without development-server compilation | Pass; 26 ms local request |
| Live MCP gateway | Discovery and read operation pass | Pass |
| Claude Code | Authenticated discovery and read pass | Pass; four projects returned |
| Browser smoke test | Portfolio → project → board and drawer keyboard path | Pass; 825 ms Playwright run |

## Public-repository controls

CodeQL, dependency review, OpenSSF Scorecard, branch protection, secret
scanning, push protection, and provenance attestations must be recorded after
the repository is public. Their workflows are committed but intentionally do
not claim results while the repository remains private.

## Blocking decisions

- Select and add the open-source licence.
- Run the Docker Compose integration job on GitHub-hosted Linux; this machine's
  Docker daemon was unavailable, while the equivalent Apple Container stack
  passed locally.
- Complete the disposable-project governed mutation and evidence-upload matrix
  for Codex and Claude.
- Complete narrow/mobile visual baselines.
