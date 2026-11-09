# Claude Code

Agent Boards uses standard Streamable HTTP MCP and does not require a
Claude-specific adapter.

Add this server to a project-level `.mcp.json`:

```json
{
  "mcpServers": {
    "agent-boards": {
      "type": "http",
      "url": "http://127.0.0.1:4173/mcp"
    }
  }
}
```

Start Agent Boards, open Claude Code in the project, and ask it to list Agent
Boards projects. For a deterministic release smoke test run:

```bash
pnpm test:claude
```

The autonomous worker contract is discoverable from the MCP resources and
`get_service_capability`; it is not dependent on a locally installed Claude
skill. Claude and Codex receive the same focused work package and are subject
to the same database gates.

Before claiming work, each Claude or Codex session calls `register_worker` with
a unique lowercase handle, its `clientType`, and only the capabilities actually
available in that session. It retains the returned worker
ID and one-time resume token privately for the session, verifies retained
credentials with `resume_worker`, and supplies them to every claim, movement,
heartbeat, block, release, and usage-report call. The token must never be copied
into chat, source files, comments, evidence, or logs. Separate Claude and Codex
identities can then run against one project concurrently without sharing or
colliding on a display name.

Claimed work time is recorded automatically by Agent Boards. If Claude Code
exposes authoritative cumulative input-token, output-token, or cost values for
the current claim, report them with `report_work_session_usage` before the card
reaches Done, is blocked, or is released. If the host does not expose those
values, do not estimate them; Agent Boards will show the usage as unreported.

Claude does not need native image generation to use Agent Boards. Omit
`image_generation` unless the connected Claude session genuinely has an image
service available. It can still advertise capabilities such as
`browser_automation`, `screenshot_capture`, `screen_recording`, or
`visual_comparison`. PostgreSQL assigns only stories whose declared feature,
story, and task requirements are covered by that worker. If the only ready
stories require unavailable capabilities, Claude receives
`no_compatible_work`; another suitably equipped worker can claim them. A
worker may call `update_worker_capabilities` if its actual tool availability
changes during the session, but must never inflate its declaration merely to
receive a card.

The repository also includes `skills/agent-boards-worker/SKILL.md` for hosts
that support explicit local skills. It mirrors the service contract but is not
required for MCP discovery.

Before a release, test at least these read-only behaviours with both clients:

1. discover tools and resources;
2. list projects and read a board;
3. read a focused work-item context;
4. read a service capability;
5. confirm malformed identifiers return useful tool errors.

Mutation scenarios should run only against a disposable project because they
create durable audit records.
