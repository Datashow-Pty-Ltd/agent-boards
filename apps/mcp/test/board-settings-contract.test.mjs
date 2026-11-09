import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const [migration, tool, settingsPage, tour, footer] = await Promise.all([
  readFile(new URL("../../../database/migrations/031-board-stage-settings.sql", import.meta.url), "utf8"),
  readFile(new URL("../src/boardSettingsTool.ts", import.meta.url), "utf8"),
  readFile(new URL("../../web/src/pages/ProjectSettingsPage.tsx", import.meta.url), "utf8"),
  readFile(new URL("../../web/src/components/FirstRunTour.tsx", import.meta.url), "utf8"),
  readFile(new URL("../../web/src/components/AppFooter.tsx", import.meta.url), "utf8"),
]);

test("board settings persist bucket and exit criteria without opening transition invariants", () => {
  assert.match(migration, /ADD COLUMN IF NOT EXISTS bucket_key/);
  assert.match(migration, /CREATE OR REPLACE FUNCTION api\.update_board_stage_settings/);
  assert.match(migration, /Every active workflow stage must retain at least one exit criterion/);
  assert.match(migration, /Archived project settings are read-only/);
  assert.doesNotMatch(migration, /UPDATE api\.board_stages SET[\s\S]*allowed_transitions\s*=/);
  assert.doesNotMatch(migration, /UPDATE api\.board_stages SET[\s\S]*position\s*=/);
});

test("REST-backed settings are available to the UI and MCP", () => {
  assert.match(tool, /"update_board_stage_settings"/);
  assert.match(tool, /Stage order and allowed transitions remain locked/);
  assert.match(settingsPage, /api\.updateBoardStageSettings/);
  assert.match(settingsPage, /One deterministic requirement per line/);
});

test("first connection explains the workflow and Datashow is attributed", () => {
  assert.match(tour, /agent-boards:first-run-tour:v1/);
  assert.match(tour, /Work advances one gate at a time/);
  assert.match(tour, /Evidence closes the loop/);
  assert.match(footer, /Built by Datashow/);
});
