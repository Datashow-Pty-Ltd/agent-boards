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
