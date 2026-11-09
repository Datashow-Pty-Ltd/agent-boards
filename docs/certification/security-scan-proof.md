# Security and release scan proof

This record is updated for each release candidate. Automated checks are
maintainer evidence, not independent certification.

## Candidate

- Date: 9 November 2026
- Evidence baseline: `3cf3c2ea82e0ea07237268c73f6c85deb84e8319`
- CI: [main run 42541226832](https://github.com/Datashow-Pty-Ltd/agent-boards/actions/runs/42541226832)
- Reviewer: Datashow maintainer
- Intended scope: trusted local or self-hosted v0.1 release

## Current local evidence

| Control | Required result | Status |
| --- | --- | --- |
| ESLint | Zero errors and warnings | Pass |
| TypeScript | All workspaces pass | Pass |
| Unit and contract tests | 21 tests pass | Pass |
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
| Docker Compose integration | Build the full stack; exercise MCP through OpenResty and the browser path | Pass in GitHub-hosted Linux CI |

## Public-repository controls

CodeQL, dependency review, OpenSSF Scorecard, branch protection, secret
scanning, push protection, and provenance attestations must be recorded after
the repository is public. Their workflows are committed but intentionally do
not claim results while the repository remains private.

## Blocking decisions

- Select and add the open-source licence.
- Complete the disposable-project governed mutation and evidence-upload matrix
  for Codex and Claude.
- Complete narrow/mobile visual baselines.
