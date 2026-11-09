import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const [migration, server, instructions, workerSkill, webApi, drawer] = await Promise.all([
  readFile(new URL("../../../database/migrations/033-task-completion-path.sql", import.meta.url), "utf8"),
  readFile(new URL("../src/server.ts", import.meta.url), "utf8"),
  readFile(new URL("../src/serverInstructions.ts", import.meta.url), "utf8"),
  readFile(new URL("../../../skills/agent-boards-worker/SKILL.md", import.meta.url), "utf8"),
  readFile(new URL("../../web/src/api.ts", import.meta.url), "utf8"),
  readFile(new URL("../../web/src/components/ItemDrawer.tsx", import.meta.url), "utf8"),
]);

test("database exposes a narrow idempotent child-task completion path", () => {
  assert.match(migration, /FUNCTION api\.complete_task/);
  assert.match(migration, /task\.kind <> 'task'/);
  assert.match(migration, /progress = 'completed'/);
  assert.match(migration, /execution_state = 'complete'/);
  assert.match(migration, /completed_at = COALESCE\(completed_at, now\(\)\)/);
  assert.match(migration, /'task\.completed'/);
  assert.match(migration, /Repair task records completed through the previously exposed generic/);
  assert.doesNotMatch(migration, /acceptance_criteria/);
});

test("MCP, worker instructions, and human UI use complete_task", () => {
  assert.match(server, /"complete_task"/);
  assert.match(server, /target_task_id: taskId/);
  assert.match(instructions, /use complete_task/);
  assert.match(workerSkill, /call `complete_task`/);
  assert.match(webApi, /completeTask:/);
  assert.match(drawer, /Complete task \$\{task\.title\}/);
});
