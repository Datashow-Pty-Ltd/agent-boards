# Architecture

Agent Boards is a control plane for governed software delivery. It records work,
evidence, approvals, project artefacts, and repository intelligence; the coding
agent remains responsible for analysis, implementation, inspection, and testing.

## Runtime

```text
Codex / Claude / browser
          |
          v
      OpenResty :4747
       /    |    \
      /     |     \
 React  PostgREST  MCP ---- repository intelligence
  SPA       |       |              |
            +--- PostgreSQL -------+
                    |
             durable project record
```

- **OpenResty** is the single host-facing gateway. It preserves streaming for
  MCP, forwards HMR WebSockets during development, and routes uploads.
- **PostgreSQL** owns workflow invariants. Stage transitions, dependencies,
  promotion gates, design governance, and project records are not trusted to a
  UI or agent prompt.
- **PostgREST** exposes the same database surface to the web application and
  MCP server.
- **MCP** is a stateless Streamable HTTP adapter. Each request creates a server
  and transport; no client session is stored in process memory.
- **Repository intelligence** performs deterministic, revision-pinned parsing
  and search. It does not require an LLM and does not claim semantic certainty
  beyond its reported precision.
- **Web** is a React Router and Mantine application. The shared Datashow tokens
  in `apps/web/src/datashow.css` and `apps/web/src/theme.ts` are authoritative.

## Source boundaries

| Path | Responsibility |
| --- | --- |
| `database/` | schema, migrations, workflow functions and invariants |
| `apps/mcp/` | MCP resources/tools and managed evidence uploads |
| `apps/repo-intelligence/` | repository acquisition, parsing, search and maps |
| `apps/web/` | people-facing portfolio, overview, board and records |
| `docker/` | service images and OpenResty routing |
| `scripts/` | local orchestration and release checks |

The MCP server keeps external HTTP concerns in `upstreams.ts` and binary media
concerns in `media.ts`. `check-source-limits.mjs` prevents the remaining
composition files from growing without an explicit extraction.

## Trust boundary

The default stack is intentionally local and unauthenticated. The database
anonymous role can modify project records. Do not expose it to an untrusted
network. Authentication, tenant isolation, project-scoped authorization, and
rate limiting are prerequisites for a hosted multi-user deployment.

## Workflow authority

The visible board groups adjacent fine-grained database stages into
project-defined action lanes. A project can use one compact lane, nine detailed
lanes, or any adjacent grouping between those extremes, with custom names,
purpose, actors, WIP limits and exit criteria. The database remains
authoritative for the fixed stage identities, order, legal one-hop transitions
and evidence; the current alpha does not support adding, removing or reordering
governed stages.
Design-only cards use the dedicated completion operation after approval rather
than fabricating code, test, review, or merge evidence.
