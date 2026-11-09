import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import test from 'node:test'

const serverSource = await readFile(new URL('../src/server.ts', import.meta.url), 'utf8')
const validationSkill = await readFile(new URL('../skills/visual-validation/SKILL.md', import.meta.url), 'utf8')
const migrationSource = await readFile(
  new URL('../../../database/migrations/028-interaction-walkthrough-evidence.sql', import.meta.url),
  'utf8',
)

test('recording upload requires observable, deliberately paced interaction metadata', () => {
  assert.match(serverSource, /continuousCapture: z\.literal\(true\)/)
  assert.match(serverSource, /pointerVisible: z\.literal\(true\)/)
  assert.match(serverSource, /playbackSpeed: z\.literal\(1\)/)
  assert.match(serverSource, /walkthroughSteps: z\.array/)
  assert.match(serverSource, /probeVideoDuration/)
  assert.match(serverSource, /\/rpc\/attach_validation_recording/)
})

test('database blocks unreviewed or malformed walkthroughs from Review', () => {
  assert.match(migrationSource, /duration < 8 OR duration > 600/)
  assert.match(migrationSource, /step_time - previous_time < 1/)
  assert.match(migrationSource, /recording_review_status = 'approved'/)
  assert.match(migrationSource, /previous_stage\.slug = 'validate' AND next_stage\.slug = 'review'/)
  assert.match(migrationSource, /CREATE TRIGGER work_items_interaction_recording_gate/)
})

test('agent contract rejects montage-style recordings and self-approval', () => {
  assert.match(validationSkill, /show the pointer or an explicit touch indicator/)
  assert.match(validationSkill, /without jump cuts, time compression, or a slideshow/)
  assert.match(validationSkill, /pause deliberately after each action/)
  assert.match(validationSkill, /never self-approve it/)
  assert.match(validationSkill, /rapid flash of screens is failed evidence/)
})
