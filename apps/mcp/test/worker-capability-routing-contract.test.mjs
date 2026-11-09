import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const [migration, tools, instructions, workerSkill] = await Promise.all([
  readFile(new URL("../../../database/migrations/037-worker-capability-routing.sql", import.meta.url), "utf8"),
  readFile(new URL("../src/workerIdentityTools.ts", import.meta.url), "utf8"),
  readFile(new URL("../src/serverInstructions.ts", import.meta.url), "utf8"),
  readFile(new URL("../../../skills/agent-boards-worker/SKILL.md", import.meta.url), "utf8"),
]);

test("database routes claims and human takeover by explicit worker capabilities", () => {
  assert.match(migration, /ADD COLUMN IF NOT EXISTS capabilities jsonb/);
  assert.match(migration, /ADD COLUMN IF NOT EXISTS required_worker_capabilities jsonb/);
  assert.match(migration, /FUNCTION api\.effective_required_worker_capabilities/);
  assert.match(migration, /FUNCTION api\.worker_can_claim_item/);
  assert.match(migration, /api\.worker_can_claim_item\(worker\.id, w\.id\)/);
  assert.match(migration, /outcome'.*'no_compatible_work'/s);
  assert.match(migration, /Takeover target @% does not provide every required capability/);
  assert.match(migration, /Capabilities required by an active claim cannot be removed/);
});

test("MCP registration advertises capabilities and the worker contract forbids capability inflation", () => {
  for (const capability of ["browser_automation", "screenshot_capture", "screen_recording", "image_generation", "visual_comparison"]) {
    assert.match(tools, new RegExp(`"${capability}"`));
  }
  assert.match(tools, /"update_worker_capabilities"/);
  assert.match(tools, /"set_work_item_required_capabilities"/);
  assert.match(tools, /requested_capabilities/);
  assert.match(instructions, /only the native capabilities actually available/i);
  assert.match(instructions, /no_compatible_work/);
  assert.match(workerSkill, /never advertise a capability merely to receive a card/i);
  assert.match(workerSkill, /suitably equipped worker/i);
});
