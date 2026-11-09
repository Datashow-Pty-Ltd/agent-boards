import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import test from 'node:test'

const serverSource = await readFile(new URL('../src/server.ts', import.meta.url), 'utf8')
const upstreamsSource = await readFile(new URL('../src/upstreams.ts', import.meta.url), 'utf8')
const serviceCapabilitiesSource = await readFile(new URL('../src/serviceCapabilities.ts', import.meta.url), 'utf8')
const implementationSkill = await readFile(new URL('../skills/visual-implementation/SKILL.md', import.meta.url), 'utf8')
const validationSkill = await readFile(new URL('../skills/visual-validation/SKILL.md', import.meta.url), 'utf8')
const migrationSource = await readFile(
  new URL('../../../database/migrations/023-visual-fidelity-promotion-gate.sql', import.meta.url),
  'utf8',
)
const productDesignWorkflowMigration = await readFile(
  new URL('../../../database/migrations/025-product-design-service-workflows.sql', import.meta.url),
  'utf8',
)
const legacyComplianceMigration = await readFile(
  new URL('../../../database/migrations/026-legacy-visual-compliance.sql', import.meta.url),
  'utf8',
)

test('MCP exposes structured visual fidelity recording and inspection', () => {
  assert.match(serverSource, /"record_visual_design_validation"/)
  assert.match(serverSource, /"list_visual_design_validations"/)
  for (const field of [
    'sourceMockupAssetId',
    'validationAssetId',
    'viewportWidth',
    'viewportHeight',
    'comparisonMethod',
    'sameViewport',
    'representsApprovedDesign',
    'structuralMatch',
    'controlsPresent',
    'measurements',
    'measurementMethod',
  ]) {
    assert.match(serverSource, new RegExp(`${field}:`), `missing ${field}`)
  }
  assert.doesNotMatch(serverSource, /unresolvedP0:/, 'severity counts must be derived by the service')
})

test('database promotion gate requires one passing exact-revision record per screen', () => {
  assert.match(migrationSource, /CREATE TABLE IF NOT EXISTS api\.work_item_visual_validations/)
  assert.match(migrationSource, /CREATE OR REPLACE FUNCTION api\.visual_fidelity_gate_requirements/)
  assert.match(migrationSource, /FOR screen IN SELECT value FROM jsonb_array_elements_text\(item\.screen_names\)/)
  assert.match(migrationSource, /record\.revision = target_revision/)
  assert.match(migrationSource, /validation\.same_viewport/)
  assert.match(migrationSource, /validation\.represents_approved_design/)
  assert.match(migrationSource, /validation\.structural_match/)
  assert.match(migrationSource, /validation\.unresolved_p0 = 0/)
  assert.match(migrationSource, /validation\.unresolved_p1 = 0/)
  assert.match(migrationSource, /validation\.unresolved_p2 = 0/)
  assert.match(migrationSource, /Visual story cannot enter Review until every declared screen/)
})

test('non-visual stories retain the existing bypass', () => {
  assert.match(
    migrationSource,
    /OLD\.kind <> 'story' OR NOT api\.work_item_requires_visual_evidence\(OLD\.id\) THEN RETURN NEW/,
  )
})

test('MCP distributes portable visual workflows without becoming the execution service', () => {
  assert.match(serverSource, /"list_service_capabilities"/)
  assert.match(serverSource, /"get_service_capability"/)
  assert.match(serverSource, /registerResource/)
  assert.match(serverSource, /service_capabilities/)
  assert.match(serviceCapabilitiesSource, /visual_implementation/)
  assert.match(serviceCapabilitiesSource, /visual_validation/)
  assert.match(implementationSkill, /connected agent performs the implementation/)
  assert.match(implementationSkill, /Agent Boards supplies approved inputs, evidence tools, invariants, and deterministic promotion gates/)
  assert.match(validationSkill, /connected agent performs inspection and measurement/)
  assert.match(validationSkill, /Agent Boards owns the evidence contract and promotion gate/)
  assert.doesNotMatch(implementationSkill, /Agent Boards performs the implementation/)
  assert.doesNotMatch(validationSkill, /Agent Boards operates the browser/)
})

test('visual implementation work packages advertise both built-in capability contracts', () => {
  assert.match(serviceCapabilitiesSource, /if \(requiresVisualEvidence && !isDesignCard\)/)
  assert.match(serviceCapabilitiesSource, /story\?\.design_card_type/)
  assert.match(serviceCapabilitiesSource, /getServiceCapabilityDescriptor\("visual_implementation"\)/)
  assert.match(serviceCapabilitiesSource, /getServiceCapabilityDescriptor\("visual_validation"\)/)
  assert.match(serverSource, /attachRepositoryToContext/)
  assert.match(upstreamsSource, /capabilitiesForWorkPackage\(workPackage, repository !== null\)/)
})

test('Product Design workflows are first-class governed MCP tools', () => {
  for (const tool of [
    'get_mockup_implementation_package',
    'get_visual_critique_package',
    'record_visual_critique',
  ]) {
    assert.match(serverSource, new RegExp(`"${tool}"`), `missing ${tool}`)
  }
  assert.match(serverSource, /product-design:image-to-code/)
  assert.match(serverSource, /product-design:design-qa/)
  assert.match(serverSource, /findings: z\.array\(visualCritiqueFindingSchema\)/)
})

test('database packages bind approved static sources and enforce measured critique failures', () => {
  assert.match(productDesignWorkflowMigration, /FUNCTION api\.get_mockup_implementation_package/)
  assert.match(productDesignWorkflowMigration, /FUNCTION api\.get_visual_critique_package/)
  assert.match(productDesignWorkflowMigration, /FUNCTION api\.record_visual_critique/)
  assert.match(productDesignWorkflowMigration, /approval_status = 'approved'/)
  assert.match(productDesignWorkflowMigration, /asset\.viewport_width = source_asset\.viewport_width/)
  assert.match(productDesignWorkflowMigration, /product-design:image-to-code/)
  assert.match(productDesignWorkflowMigration, /product-design:design-qa/)
  assert.match(productDesignWorkflowMigration, /unresolved_p0 = GREATEST/)
  assert.match(productDesignWorkflowMigration, /unresolved_p1 = GREATEST/)
  assert.match(productDesignWorkflowMigration, /unresolved_p2 = GREATEST/)
  assert.match(productDesignWorkflowMigration, /represents_approved_design = represents_approved_design/)
  assert.match(productDesignWorkflowMigration, /live HTML cannot approve itself/)
})

test('legacy Done visual work is authoritatively re-audited and remediated', () => {
  assert.match(legacyComplianceMigration, /FUNCTION api\.get_visual_story_compliance/)
  assert.match(legacyComplianceMigration, /VIEW api\.visual_story_compliance/)
  assert.match(legacyComplianceMigration, /VIEW api\.work_item_delivery_status/)
  assert.match(legacyComplianceMigration, /noncompliant_visual_story_count/)
  assert.match(legacyComplianceMigration, /visual_compliance_ready/)
  assert.match(legacyComplianceMigration, /FUNCTION api\.ensure_visual_compliance_remediation/)
  assert.match(legacyComplianceMigration, /Historical evidence remains unchanged/)
  assert.match(serverSource, /"get_visual_story_compliance"/)
  assert.match(serverSource, /"list_visual_compliance_failures"/)
  assert.match(serverSource, /"ensure_visual_compliance_remediation"/)
})
