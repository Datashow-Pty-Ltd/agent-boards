# Release certification checklist

This is a maintainer self-certification checklist, not an independent audit.
Complete it against the exact candidate commit before making the repository
public or creating a version tag.

## Automated gate

- [x] `pnpm certify` passes from the candidate worktree.
- [x] `pnpm test:live` passes through OpenResty.
- [x] Three independent MCP clients atomically claim and move three distinct stories.
- [x] `pnpm test:browser` passes against the complete stack.
- [x] `pnpm test:claude` passes using an authenticated Claude Code client.
- [x] Docker Compose builds and reaches healthy state.
- [x] Apple Container builds and reaches healthy state.
- [x] Production dependency audit reports no high-or-critical findings.
- [x] Trivy, Gitleaks, OSV-Scanner, Semgrep CE, ShellCheck, Hadolint,
      actionlint, zizmor, and licence-compatibility gates are enforced.
- [x] CycloneDX SBOM and source archive are generated.
- [x] Release archive contains no local evidence, builds, credentials, caches,
      editor state, or vendored private packages.

## Repository and governance

- [x] Apache License 2.0 and Datashow `NOTICE` selected and committed.
- [x] Public name, description, maintainer contact, and security-reporting path
      confirmed.
- [x] Secret scanning, push protection, vulnerability alerts, and private
      vulnerability reporting enabled.
- [x] Required branch checks and review protection enabled for `main`.
- [x] CodeQL, dependency review, and OpenSSF Scorecard complete for the exact
      public candidate commit.

## Manual review

- [ ] Architecture and trust-boundary documentation matches implementation.
- [ ] UI typography, responsive behaviour, keyboard navigation, and focus
      treatment reviewed at wide and narrow viewports.
- [ ] Seed data contains no private URLs, credentials, or customer information.
- [ ] Codex and Claude each complete a governed mutation and evidence upload in
      a disposable project.
- [x] Known limitations and future hosted-service controls are explicit.

Record results in `security-scan-proof.md`, including exact commit SHA, command
outputs, CI links, unresolved findings, and reviewer.
