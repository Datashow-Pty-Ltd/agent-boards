---
name: agent-boards-repository-intelligence
description: Use Agent Boards repository snapshots, search, symbols, imports, diffs, discovered checks, and cited maps to analyse or plan work against an exact revision. Use when an Agent Boards work package has a linked repository.
---

# Repository intelligence

Agent Boards supplies revision-pinned repository facts and durable maps. The connected agent interprets those facts, edits the linked repository with its own coding tools, and runs checks itself. Repository intelligence is read-only and does not modify, install, build, test, or merge repository code.

## Workflow

1. Read the repository capability descriptor in the claimed work package.
2. Call `get_repository_snapshot` for the required base revision. If no ready snapshot exists, call `request_repository_index`, poll `get_repository_index_job`, then fetch the completed snapshot.
3. Confirm the returned `commit_sha`, `index_version`, `precision`, and status before using any result. Never mix facts from different snapshots.
4. Use the narrowest applicable tools:
   - `search_repository` for exact source occurrences;
   - `read_repository_file` for bounded source content;
   - `list_repository_symbols` for declarations;
   - `get_repository_graph` for syntax-derived imports and exports;
   - `compare_repository_revisions` for changed paths;
   - `get_repository_quality_checks` for repository-defined commands.
5. Cite durable conclusions as `commit:path:line` and distinguish direct facts from agent inference.
6. Persist reusable architecture, domain, dependency, quality, or change-impact interpretations with `upsert_repository_map`. Every map must target the exact snapshot and include source citations.
7. Re-index after the relevant revision changes. Do not carry a prior revision's map or impact conclusion forward without re-evaluation.

## Precision and safety

- `syntax` precision identifies parsed declarations and literal import/export edges; it is not compiler-resolved call or reference analysis.
- A discovered command is not a passing check. The agent or CI must execute it and attach exact-revision evidence through the ordinary Agent Boards evidence tools.
- Never infer that a test covers code unless coverage or another deterministic source establishes it.
- Treat missing language support, parse errors, stale snapshots, and incomplete graphs as explicit limitations.
- Do not request indexing for unrelated repositories or revisions outside the project scope.
- Repository maps are versioned interpretations, not replacements for source code or deterministic promotion evidence.
