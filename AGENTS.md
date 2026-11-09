# Agent contributor instructions

- Preserve PostgreSQL as the authority for workflow invariants and promotion
  gates; UI or prompt-only validation is insufficient.
- Add a new ordered, idempotent migration for database changes. Never modify a
  migration from a published release.
- Use the shared Mantine theme and typography tokens. Do not introduce
  route-specific fonts, colours, or page-title sizes.
- Keep MCP operations focused and derive durable facts from the shared API.
- Do not commit generated builds, evidence media, local environment files,
  archives, repository mirrors, or credentials.
- Run `pnpm certify` before proposing a release. Run `pnpm test:live` and
  `pnpm test:browser` with the container stack running for integration changes.
- Do not describe automated checks as independent security certification.
