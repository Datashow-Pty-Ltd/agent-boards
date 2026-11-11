# Container build recipes

Agent Boards supports Docker Compose and Apple Container from the same source
tree and Containerfiles. Docker Compose is the portable default. Apple
Container is an additional native macOS path, not a separate distribution.

Both recipes build these local images:

- `agent-boards-postgres:dev`
- `agent-boards-mcp:dev`
- `agent-boards-repo-intelligence:dev`
- `agent-boards-web:dev`
- `agent-boards-gateway:dev`

PostgREST remains a pinned upstream image.

## Docker Compose

Requirements: Docker Engine or Docker Desktop with Compose v2.

```bash
cp .env.example .env
docker compose build
docker compose up -d --wait
```

For the shortest first run, combine those operations with
`docker compose up --build -d --wait`. The stack publishes OpenResty at
<http://127.0.0.1:4747> by default.

```bash
docker compose ps
docker compose logs --tail=100 -f
pnpm test:live
docker compose down
```

To change the bind address or port, edit `.env`:

```dotenv
AGENT_BOARDS_BIND=127.0.0.1
AGENT_BOARDS_PORT=8080
```

Use `docker compose down --volumes` only when intentionally discarding the
database, evidence uploads, and repository mirrors.

## Apple Container

Requirements: macOS with the Apple `container` CLI installed and its system
service available.

```bash
./scripts/stack.sh build
./scripts/stack.sh up
```

`up` rebuilds changed images, applies every database migration, recreates
the six application containers, and preserves data in named volumes.
For the shortest first run, call only `./scripts/stack.sh up` because it builds
the images as part of startup.

```bash
./scripts/stack.sh status
./scripts/stack.sh logs
pnpm test:live
./scripts/stack.sh down
```

Choose another port without changing a file:

```bash
AGENT_BOARDS_PORT=8080 ./scripts/stack.sh up
```

The equivalent `pnpm docker:*` and `pnpm apple:*` shortcuts are available to
contributors who already have Node.js and pnpm installed. They are not required
to run the containerised application. For private GitHub repository indexing,
export `GITHUB_TOKEN` before starting either recipe (the Apple Container recipe
falls back to `gh auth token`). It is passed only to the repository-intelligence
service.

## Verification

With either stack running:

```bash
curl --fail http://127.0.0.1:4747/health
curl --fail http://127.0.0.1:4747/mcp/health
curl --fail http://127.0.0.1:4747/intelligence/health
pnpm test:live
```

`pnpm test:claude` additionally verifies the live MCP endpoint through an
authenticated Claude Code CLI without mutating project data.
