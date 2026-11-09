# Contributing

Thank you for helping improve Agent Boards.

1. Read [the architecture](docs/architecture.md) and
   [development guide](docs/development.md).
2. Open an issue before making a large workflow or schema change.
3. Keep durable invariants in PostgreSQL and keep agents/UI as clients of those
   invariants.
4. Add a new migration; never rewrite a released one.
5. Run `pnpm release:check` before opening a pull request.
6. Include live MCP verification for gateway or protocol changes and visual
   evidence for material UI changes.

Pull requests should explain the user problem, the chosen boundary, migration
impact, tests, and any security or compatibility consequences.

Unless explicitly stated otherwise, contributions intentionally submitted for
inclusion in Agent Boards are provided under the Apache License 2.0, consistent
with section 5 of the project [LICENSE](LICENSE).
