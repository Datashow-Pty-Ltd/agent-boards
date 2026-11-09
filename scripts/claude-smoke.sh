#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
AGENT_BOARDS_URL=${AGENT_BOARDS_URL:-http://127.0.0.1:4173}
CLAUDE_MODEL=${CLAUDE_MODEL:-sonnet}

if ! command -v claude >/dev/null 2>&1; then
  echo "Claude Code is required. Install it and authenticate before running this smoke test." >&2
  exit 1
fi

MCP_CONFIG=$(printf '{"mcpServers":{"agent-boards":{"type":"http","url":"%s/mcp"}}}' "$AGENT_BOARDS_URL")
PROMPT='Use the Agent Boards list_projects MCP tool exactly once. Do not call any other tool. Return only JSON with keys project_count (number) and first_project_name (string or null).'

cd "$ROOT_DIR"
printf '%s\n' "$PROMPT" | claude --print \
  --model "$CLAUDE_MODEL" \
  --strict-mcp-config \
  --mcp-config "$MCP_CONFIG" \
  --allowedTools mcp__agent-boards__list_projects
