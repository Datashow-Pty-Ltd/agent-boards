import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const [leaseMigration, identityMigration, tools, instructions, workerSkill, webControl] = await Promise.all([
  readFile(new URL("../../../database/migrations/035-idle-claim-takeover.sql", import.meta.url), "utf8"),
  readFile(new URL("../../../database/migrations/036-persistent-worker-identities.sql", import.meta.url), "utf8"),
  readFile(new URL("../src/workerIdentityTools.ts", import.meta.url), "utf8"),
  readFile(new URL("../src/serverInstructions.ts", import.meta.url), "utf8"),
  readFile(new URL("../../../skills/agent-boards-worker/SKILL.md", import.meta.url), "utf8"),
  readFile(new URL("../../web/src/components/ClaimControl.tsx", import.meta.url), "utf8"),
]);

test("database owns claim freshness, human takeover, and stale-worker fencing", () => {
  assert.match(leaseMigration, /claim_heartbeat_at timestamptz/);
  assert.match(identityMigration, /CREATE TABLE IF NOT EXISTS api\.agent_workers/);
  assert.match(identityMigration, /token_hash text NOT NULL/);
  assert.match(identityMigration, /digest\(resume_token, 'sha256'\)/);
  assert.match(identityMigration, /agent_workers_project_handle_unique/);
  assert.match(identityMigration, /assignee_worker_id uuid/);
  assert.match(identityMigration, /FUNCTION api\.heartbeat_work_item_as_worker/);
  assert.match(identityMigration, /FUNCTION api\.authorize_idle_claim_takeover/);
  assert.match(identityMigration, /Claim is still active and cannot be taken over/);
  assert.match(identityMigration, /'work_item\.claim_taken_over', 'human'/);
  assert.match(identityMigration, /REVOKE EXECUTE ON FUNCTION api\.claim_work_item\(uuid, text\)/);
});

test("agents register persistent credentials while takeover remains a human UI operation", () => {
  assert.match(tools, /"register_worker"/);
  assert.match(tools, /"resume_worker"/);
  assert.match(tools, /"list_project_workers"/);
  assert.match(tools, /workerId: z\.string\(\)\.uuid\(\)/);
  assert.match(tools, /resumeToken: z\.string\(\)/);
  assert.match(tools, /"heartbeat_work_item"/);
  assert.match(tools, /"get_work_item_claim_status"/);
  assert.doesNotMatch(tools, /authorize_idle_claim_takeover/);
  assert.match(instructions, /at least every five minutes/i);
  assert.match(instructions, /never put the token/i);
  assert.match(workerSkill, /register_worker/);
  assert.match(workerSkill, /Parallel Codex and Claude workers/);
  assert.match(workerSkill, /heartbeat_work_item/);
  assert.match(webControl, /authorizeIdleClaimTakeover/);
  assert.match(webControl, /authorizeIdleClaimRelease/);
  assert.match(webControl, /Registered worker/);
  assert.doesNotMatch(webControl, /Stable worker name/);
});
