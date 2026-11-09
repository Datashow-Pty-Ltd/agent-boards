import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const [migration, server, webApi, drawer, relations] = await Promise.all([
  readFile(new URL("../../../database/migrations/040-related-work-item-register-entries.sql", import.meta.url), "utf8"),
  readFile(new URL("../src/server.ts", import.meta.url), "utf8"),
  readFile(new URL("../../web/src/api.ts", import.meta.url), "utf8"),
  readFile(new URL("../../web/src/components/ItemDrawer.tsx", import.meta.url), "utf8"),
  readFile(new URL("../../web/src/components/ItemRelations.tsx", import.meta.url), "utf8"),
]);

test("decisions, issues and risks are durable work-item relations", () => {
  assert.match(migration, /CREATE TABLE IF NOT EXISTS api\.work_item_register_entries/);
  assert.match(migration, /entry_type IN \('decision','issue','risk'\)/);
  assert.match(migration, /FUNCTION api\.upsert_work_item_register_entry/);
  assert.match(migration, /item\.kind NOT IN \('feature', 'story'\)/);
  assert.match(migration, /'work_item\.register_entry_recorded'/);
});

test("related register records are exposed to agents and rendered in the drawer", () => {
  assert.match(server, /"list_work_item_register_entries"/);
  assert.match(server, /"record_work_item_register_entry"/);
  assert.match(webApi, /workItemRegisterEntries:/);
  assert.match(drawer, /api\.workItemRegisterEntries\(item\.id\)/);
  assert.match(relations, /None registered/);
  assert.doesNotMatch(relations, /Open project register/);
});
