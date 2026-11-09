import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const [migration, server, instructions, capabilities, workerSkill, readme, drawer] = await Promise.all([
  readFile(new URL('../../../database/migrations/030-design-card-completion-path.sql', import.meta.url), 'utf8'),
  readFile(new URL('../src/server.ts', import.meta.url), 'utf8'),
  readFile(new URL('../src/serverInstructions.ts', import.meta.url), 'utf8'),
  readFile(new URL('../src/serviceCapabilities.ts', import.meta.url), 'utf8'),
  readFile(new URL('../../../skills/agent-boards-worker/SKILL.md', import.meta.url), 'utf8'),
  readFile(new URL('../../../README.md', import.meta.url), 'utf8'),
  readFile(new URL('../../web/src/components/ItemDrawer.tsx', import.meta.url), 'utf8'),
]);

test('database exposes a narrow approved design-only Plan to Done path', () => {
  assert.match(migration, /design_card_completion_requirements/);
  assert.match(migration, /design_card_can_complete/);
  assert.match(migration, /previous_stage\.slug = 'plan' AND next_stage\.slug = 'done'/);
  assert.match(migration, /design_revision := 'design-contract:' \|\| md5/);
  assert.match(migration, /'completion_path', 'design_only'/);
  assert.match(migration, /no source implementation is asserted/i);
  assert.doesNotMatch(migration, /VALUES\s*\([^;]*'implementation'/s);
  assert.doesNotMatch(migration, /VALUES\s*\([^;]*'merge'/s);
  assert.doesNotMatch(migration, /VALUES\s*\([^;]*'regression'/s);
});

test('MCP and UI expose requirements and explicit completion', () => {
  assert.match(server, /"get_design_card_completion_requirements"/);
  assert.match(server, /"complete_design_card"/);
  assert.match(instructions, /never fabricate implementation or test evidence/i);
  assert.match(drawer, /Complete approved design contract/);
  assert.match(drawer, /Design-only completion closes the approved contract/);
});

test('design cards are not advertised implementation and validation capabilities', () => {
  assert.match(capabilities, /const isDesignCard/);
  assert.match(capabilities, /requiresVisualEvidence && !isDesignCard/);
});

test('portable worker instructions and documentation distinguish design from implementation', () => {
  assert.match(workerSkill, /Backlog → Analyse → Plan → Done/);
  assert.match(workerSkill, /complete_design_card/);
  assert.match(workerSkill, /do not claim mockups are implemented application evidence/i);
  assert.match(readme, /Design-only cards do not enter the software implementation pipeline/);
  assert.match(readme, /design-contract:\*/);
});
