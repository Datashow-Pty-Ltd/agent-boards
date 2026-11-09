import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const [migration, tools, instructions, workerSkill, webControl] = await Promise.all([
  readFile(new URL("../../../database/migrations/035-idle-claim-takeover.sql", import.meta.url), "utf8"),
  readFile(new URL("../src/claimLeaseTools.ts", import.meta.url), "utf8"),
  readFile(new URL("../src/serverInstructions.ts", import.meta.url), "utf8"),
  readFile(new URL("../../../skills/agent-boards-worker/SKILL.md", import.meta.url), "utf8"),
  readFile(new URL("../../web/src/components/ClaimControl.tsx", import.meta.url), "utf8"),
]);

test("database owns claim freshness, human takeover, and stale-worker fencing", () => {
  assert.match(migration, /claim_heartbeat_at timestamptz/);
  assert.match(migration, /FUNCTION api\.heartbeat_work_item/);
  assert.match(migration, /FUNCTION api\.authorize_idle_claim_takeover/);
  assert.match(migration, /FUNCTION api\.authorize_idle_claim_release/);
  assert.match(migration, /Claim is still active and cannot be taken over/);
  assert.match(migration, /Only the active worker % can move this claimed item/);
  assert.match(migration, /'work_item\.claim_taken_over', 'human'/);
});

test("agents renew leases while takeover remains a human UI operation", () => {
  assert.match(tools, /"heartbeat_work_item"/);
  assert.match(tools, /"get_work_item_claim_status"/);
  assert.doesNotMatch(tools, /authorize_idle_claim_takeover/);
  assert.match(instructions, /at least every five minutes/i);
  assert.match(workerSkill, /heartbeat_work_item/);
  assert.match(webControl, /authorizeIdleClaimTakeover/);
  assert.match(webControl, /authorizeIdleClaimRelease/);
});
