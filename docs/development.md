# Development

## Requirements

- Node.js 24
- pnpm 10.26.1
- Docker with Compose v2, or Apple Container on macOS
- `ffprobe` is included in the MCP image for validation-video inspection

## Local stack

Docker is the portable default. The container-only quick start is:

```bash
cp .env.example .env
docker compose up --build -d --wait
```

Open <http://127.0.0.1:4173>. Stop it with `docker compose down`.

On macOS, the Apple Container path is available through
`./scripts/stack.sh up`. Both paths use the same images, migrations, gateway, and
`com.datashow.application.stack=agent-boards` labels. See the complete
[container recipes](container-recipes.md) for logs, verification, ports,
persistence, and teardown.

## Checks

Install Node.js 24 and pnpm 10.26.1 before running development or release
checks:

```bash
pnpm install --frozen-lockfile
pnpm release:check     # lint, limits, types, tests, builds, audit, secrets
pnpm certify           # release gate plus SBOM, archive and verification
pnpm test:live         # live MCP request through OpenResty; stack must run
pnpm test:browser      # packaged UI navigation and keyboard smoke test
pnpm test:claude       # real Claude Code MCP call; Claude must be authenticated
pnpm release:verify:public # final public gate; requires the selected licence
```

The Claude check uses `--strict-mcp-config`, permits only `list_projects`, and
does not mutate the board. `AGENT_BOARDS_URL` and `CLAUDE_MODEL` can override
its defaults.

## Database changes

Never edit a released migration. Add the next numbered file under
`database/migrations/`; make it idempotent where practical and enforce durable
workflow rules in PostgreSQL rather than only in the UI or MCP prompt.

## UI conventions

- Use semantic tokens from `datashow.css`; do not introduce route-specific
  fonts, colours, or top-level heading sizes.
- Use Mantine theme controls rather than recreating them in local CSS.
- Page titles use `--fz-page-title`; section titles use `--fz-section-title`.
- Preserve keyboard focus indicators with `:focus-visible`.
- Update or add a contract/component test when a shared visual role changes.

The current screenshot audit baseline is stored in
`artifacts/open-source-audit/`. It covers Portfolio, Overview, Board, drawer,
and Backlog at a wide viewport.
