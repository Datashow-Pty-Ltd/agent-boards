# Claude Code contributor guide

Follow [AGENTS.md](AGENTS.md) for repository rules. Agent Boards is the durable
project record; the connected coding agent performs implementation and testing.
Do not fabricate evidence, skip governed stages, or self-approve human gates.

Before handing off a change, run:

```bash
pnpm release:check
```

Before a release candidate, run `pnpm certify`. The authenticated live Claude
smoke test is `pnpm test:claude`; it is intentionally read-only.
