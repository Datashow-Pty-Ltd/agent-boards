import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const [migration, ownershipTools, instructions, workerSkill, webTypes, boardCard] = await Promise.all([
  readFile(new URL("../../../database/migrations/034-multi-agent-ownership.sql", import.meta.url), "utf8"),
  readFile(new URL("../src/ownershipTools.ts", import.meta.url), "utf8"),
  readFile(new URL("../src/serverInstructions.ts", import.meta.url), "utf8"),
  readFile(new URL("../../../skills/agent-boards-worker/SKILL.md", import.meta.url), "utf8"),
  readFile(new URL("../../web/src/types.ts", import.meta.url), "utf8"),
  readFile(new URL("../../web/src/components/KanbanBoard.tsx", import.meta.url), "utf8"),
]);

test("database owns concurrent claim exclusivity and durable ownership", () => {
  assert.match(migration, /ADD COLUMN IF NOT EXISTS owner text/);
  assert.match(migration, /FUNCTION api\.set_work_item_owner/);
  assert.match(migration, /FOR UPDATE OF w SKIP LOCKED/);
  assert.match(migration, /owner = COALESCE\(owner, normalized_agent\)/);
  assert.match(migration, /assignee = normalized_agent/);
  assert.match(migration, /Only the active worker % can release this item/);
  assert.match(migration, /CREATE OR REPLACE VIEW api\.project_owner_summary/);
});

test("MCP, skill, and UI expose owner separately from active worker", () => {
  assert.match(ownershipTools, /"set_work_item_owner"/);
  assert.match(ownershipTools, /"list_project_owners"/);
  assert.match(instructions, /parallel workers receive different stories/i);
  assert.match(workerSkill, /`owner` as durable accountability/);
  assert.match(webTypes, /owner: string \| null/);
  assert.match(boardCard, /item\.assignee \?\? item\.owner/);
});
