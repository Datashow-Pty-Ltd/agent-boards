# Security assurance

Agent Boards publishes inspectable evidence about its release process. No
automated scan proves that software is safe, and the project must not describe
itself as independently certified unless a named third party has performed and
published that assessment.

## Continuous controls

- ESLint with TypeScript and React Hooks rules, with zero warnings permitted.
- TypeScript checks, unit and contract tests, production builds, dependency
  audit, tracked-file secret-pattern scan, and source-size limits.
- Browser navigation and keyboard smoke testing against the complete container
  stack.
- Linux, macOS, and Windows CI, including Node.js 22 and 24.
- GitHub dependency review for moderate-or-higher newly introduced
  vulnerabilities once the repository is public.
- CodeQL `security-extended` JavaScript and TypeScript analysis once public.
- OpenSSF Scorecard results uploaded to code scanning once public.
- Weekly Dependabot checks for npm and pinned GitHub Actions dependencies.
- CycloneDX production-dependency SBOM generation.
- Full commit-SHA pinning for third-party GitHub Actions.
- Pinned Trivy, Gitleaks, OSV-Scanner, Semgrep Community Edition, ShellCheck,
  Hadolint, actionlint, and zizmor checks through the Aqua tool manifest.
- Conservative production-dependency licence allowlisting for Apache-2.0
  compatibility; every new licence requires explicit review.
- SHA-256 release checksums and GitHub build-provenance attestations.

Run the local code and release-candidate controls with:

```bash
pnpm install --frozen-lockfile
pnpm certify
aqua install
pnpm security:oss
```

The tagged-release workflow also builds every Compose image and runs
`pnpm security:containers`. Local maintainers can run the same image gate after
starting Docker with `docker compose build && pnpm security:containers`.

With the container stack running, also run:

```bash
pnpm test:live
pnpm test:browser
pnpm test:claude
```

The Claude check requires a locally authenticated Claude CLI. It is not run in
CI and remains read-only.

## Boundaries

The `v0.1.0-alpha.1` release is for trusted local or self-hosted use. Its anonymous
PostgREST role is not suitable for public Internet exposure. Authentication,
tenant isolation, project-scoped authorization, upload scanning, rate limits,
and agent leases remain requirements for a future hosted service.

Repository URLs, Git credentials, uploaded evidence, generated media, and
checked-out source are untrusted inputs. Repository intelligence runs in a
separate container and records revision-pinned deterministic facts. Operators
remain responsible for least-privilege repository tokens and reviewing uploads.
