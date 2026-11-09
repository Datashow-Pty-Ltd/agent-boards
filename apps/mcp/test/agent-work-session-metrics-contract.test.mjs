import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const [migration, tools, instructions, workerSkill, overview] = await Promise.all([
  readFile(new URL("../../../database/migrations/039-agent-work-session-metrics.sql", import.meta.url), "utf8"),
  readFile(new URL("../src/workerIdentityTools.ts", import.meta.url), "utf8"),
  readFile(new URL("../src/serverInstructions.ts", import.meta.url), "utf8"),
  readFile(new URL("../../../skills/agent-boards-worker/SKILL.md", import.meta.url), "utf8"),
  readFile(new URL("../../web/src/pages/ProjectOverviewPage.tsx", import.meta.url), "utf8"),
]);

test("claim lifecycle is the database-owned source for agent work time", () => {
  assert.match(migration, /CREATE TABLE IF NOT EXISTS api\.agent_work_sessions/);
  assert.match(migration, /CREATE TRIGGER track_agent_work_session_update/);
  assert.match(migration, /end_reason = 'idle_timeout'/);
  assert.match(migration, /LEAST\(now\(\), session\.last_heartbeat_at \+ make_interval/);
  assert.match(migration, /CREATE OR REPLACE VIEW api\.project_agent_metrics/);
  assert.match(migration, /> now\(\) - make_interval/);
  assert.match(migration, /NEW\.assignee_worker_id IS NOT NULL/);
  assert.match(migration, /claim_heartbeat_at, w\.claim_started_at, w\.updated_at/);
  assert.match(migration, /FROM api\.project_agent_metrics metrics/);
});

test("usage is exact, optional, authenticated, and never inferred", () => {
  assert.match(migration, /FUNCTION api\.report_work_session_usage/);
  assert.match(migration, /worker := api\.require_agent_worker/);
  assert.match(tools, /"report_work_session_usage"/);
  assert.match(tools, /Never estimate or invent usage/);
  assert.match(instructions, /never estimate (missing )?usage/i);
  assert.match(workerSkill, /Never infer or estimate missing usage/);
});

test("overview distinguishes automatic time from unavailable host usage", () => {
  assert.match(overview, /api\.agentMetrics/);
  assert.match(overview, /Usage not reported/);
  assert.match(overview, /claimed.*session/);
  assert.doesNotMatch(overview, /runTotals/);
  assert.doesNotMatch(overview, /api\.telemetry/);
});
