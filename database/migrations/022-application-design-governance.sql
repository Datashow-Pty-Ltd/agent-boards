-- Application design is governed project work. A visual concept card presents
-- alternatives for human selection; that selection unlocks a project style
-- guide, and every named screen needs an approved mockup before Build.

ALTER TABLE api.work_items
  ADD COLUMN IF NOT EXISTS design_card_type text,
  ADD COLUMN IF NOT EXISTS screen_names jsonb NOT NULL DEFAULT '[]'::jsonb;

ALTER TABLE api.work_items
  DROP CONSTRAINT IF EXISTS work_items_design_card_type_check,
  ADD CONSTRAINT work_items_design_card_type_check CHECK (
    design_card_type IS NULL OR design_card_type IN ('visual_concept', 'screen_mockup')
  ),
  DROP CONSTRAINT IF EXISTS work_items_screen_names_check,
  ADD CONSTRAINT work_items_screen_names_check CHECK (jsonb_typeof(screen_names) = 'array');

ALTER TABLE api.work_item_assets
  ADD COLUMN IF NOT EXISTS screen_name text,
  ADD COLUMN IF NOT EXISTS approval_status text NOT NULL DEFAULT 'candidate',
  ADD COLUMN IF NOT EXISTS approved_by text,
  ADD COLUMN IF NOT EXISTS approved_at timestamptz;

ALTER TABLE api.work_item_assets
  DROP CONSTRAINT IF EXISTS work_item_assets_approval_status_check,
  ADD CONSTRAINT work_item_assets_approval_status_check CHECK (
    approval_status IN ('candidate', 'approved', 'rejected')
  );

CREATE TABLE IF NOT EXISTS api.project_design_governance (
  project_id uuid PRIMARY KEY REFERENCES api.projects(id) ON DELETE CASCADE,
  concept_design_card_id uuid REFERENCES api.work_items(id) ON DELETE SET NULL,
  approved_concept_asset_id uuid REFERENCES api.work_item_assets(id) ON DELETE SET NULL,
  design_concept_artifact_id uuid REFERENCES api.project_artifacts(id) ON DELETE SET NULL,
  style_guide_artifact_id uuid REFERENCES api.project_artifacts(id) ON DELETE SET NULL,
  concept_approved_by text,
  concept_approved_at timestamptz,
  design_concept_approved_by text,
  design_concept_approved_at timestamptz,
  style_guide_approved_by text,
  style_guide_approved_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

DROP TRIGGER IF EXISTS project_design_governance_updated_at ON api.project_design_governance;
CREATE TRIGGER project_design_governance_updated_at
  BEFORE UPDATE ON api.project_design_governance
  FOR EACH ROW EXECUTE FUNCTION api.set_updated_at();

CREATE INDEX IF NOT EXISTS work_item_assets_screen_idx
  ON api.work_item_assets(project_id, lower(screen_name))
  WHERE screen_name IS NOT NULL AND approval_status = 'approved';

CREATE OR REPLACE FUNCTION api.seed_project_records() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO api.project_artifacts(
    project_id, artifact_key, artifact_type, title, description, content, status, created_by
  ) VALUES
    (NEW.id, 'project-brief', 'brief', 'Project brief',
      'AI summary of the supplied project brief, its purpose, audience and intended outcomes.',
      NEW.description, 'current', 'Agent Boards'),
    (NEW.id, 'prd', 'prd', 'Product requirements document',
      'Goals, users, requirements and accepted outcomes for the project.',
      '', 'draft', 'Product agent'),
    (NEW.id, 'architecture', 'architecture', 'Architecture document',
      'System shape, components, data contracts and integration boundaries.',
      '', 'draft', 'Architecture agent'),
    (NEW.id, 'design-concept', 'design_concept', 'Application design concept',
      'The selected visual direction, decision rationale, experience principles, journeys, information architecture and interaction language.',
      '', 'draft', 'Design agent'),
    (NEW.id, 'style-guide', 'design_system', 'Design system and style guide',
      'The approved design DNA: colour, typography, spacing, components, states, interaction, motion, responsive behaviour and accessibility.',
      '', 'draft', 'Design agent'),
    (NEW.id, 'risk-register', 'risk_register', 'Risk register',
      'Threats to delivery currently tracked by people and agents.',
      E'| ID | Risk | Likelihood | Impact | Mitigation | Owner | Status |\n| --- | --- | --- | --- | --- | --- | --- |', 'current', 'Delivery agent'),
    (NEW.id, 'issue-register', 'issue_register', 'Issue register',
      'Open problems awaiting resolution or human authority.',
      E'| ID | Issue | Priority | Owner | Status | Resolution |\n| --- | --- | --- | --- | --- | --- |', 'current', 'Delivery agent')
  ON CONFLICT (project_id, artifact_key) DO NOTHING;
  RETURN NEW;
END $$;

INSERT INTO api.project_artifacts(
  project_id, artifact_key, artifact_type, title, description, content, status, created_by
)
SELECT project.id, definition.artifact_key, definition.artifact_type, definition.title,
  definition.description, '', 'draft', 'Design agent'
FROM api.projects project
CROSS JOIN (VALUES
  ('design-concept', 'design_concept', 'Application design concept',
    'The selected visual direction, decision rationale, experience principles, journeys, information architecture and interaction language.'),
  ('style-guide', 'design_system', 'Design system and style guide',
    'The approved design DNA: colour, typography, spacing, components, states, interaction, motion, responsive behaviour and accessibility.')
) AS definition(artifact_key, artifact_type, title, description)
ON CONFLICT (project_id, artifact_key) DO NOTHING;

CREATE OR REPLACE FUNCTION api.set_design_card(
  target_work_item_id uuid,
  target_design_card_type text DEFAULT NULL,
  target_screen_names jsonb DEFAULT '[]'::jsonb,
  actor_name text DEFAULT 'You'
) RETURNS SETOF api.work_items
LANGUAGE plpgsql AS $$
DECLARE
  item api.work_items;
  stage api.board_stages;
  normalized_screens jsonb;
BEGIN
  SELECT * INTO item FROM api.work_items WHERE id = target_work_item_id FOR UPDATE;
  IF item.id IS NULL THEN RAISE EXCEPTION 'Work item not found.'; END IF;
  IF item.kind <> 'story' THEN
    RAISE EXCEPTION 'Only stories can be application design cards or declare screens.' USING ERRCODE = '23514';
  END IF;
  IF target_design_card_type IS NOT NULL AND target_design_card_type NOT IN ('visual_concept', 'screen_mockup') THEN
    RAISE EXCEPTION 'Unsupported design card type: %', target_design_card_type USING ERRCODE = '23514';
  END IF;
  IF jsonb_typeof(COALESCE(target_screen_names, '[]'::jsonb)) <> 'array' THEN
    RAISE EXCEPTION 'Screen names must be a JSON array.' USING ERRCODE = '23514';
  END IF;
  SELECT COALESCE(jsonb_agg(screen ORDER BY screen), '[]'::jsonb)
  INTO normalized_screens
  FROM (
    SELECT DISTINCT btrim(value) AS screen
    FROM jsonb_array_elements_text(COALESCE(target_screen_names, '[]'::jsonb))
    WHERE btrim(value) <> ''
  ) names;
  IF target_design_card_type = 'screen_mockup' AND jsonb_array_length(normalized_screens) = 0 THEN
    RAISE EXCEPTION 'A screen mockup design card must name at least one screen.' USING ERRCODE = '23514';
  END IF;
  SELECT * INTO stage FROM api.board_stages WHERE id = item.stage_id;
  IF stage.slug NOT IN ('backlog', 'analyse', 'plan') THEN
    RAISE EXCEPTION 'Design role and screen inventory cannot change after Build begins.' USING ERRCODE = '23514';
  END IF;
  UPDATE api.work_items
  SET design_card_type = target_design_card_type,
      screen_names = normalized_screens,
      visual_evidence_required = true
  WHERE id = item.id
  RETURNING * INTO item;
  IF target_design_card_type = 'visual_concept' THEN
    INSERT INTO api.project_design_governance(project_id, concept_design_card_id)
    VALUES (item.project_id, item.id)
    ON CONFLICT (project_id) DO UPDATE SET concept_design_card_id = EXCLUDED.concept_design_card_id;
  END IF;
  INSERT INTO api.activity_events(project_id, work_item_id, event_type, actor_type, actor_name, summary, details)
  VALUES (
    item.project_id, item.id, 'work_item.design_role_changed',
    CASE WHEN actor_name = 'You' THEN 'human' ELSE 'agent' END,
    actor_name, 'Updated application design scope for ' || item.item_key,
    jsonb_build_object('design_card_type', target_design_card_type, 'screen_names', normalized_screens)
  );
  RETURN NEXT item;
END $$;

CREATE OR REPLACE FUNCTION api.set_work_item_asset_screen(
  target_asset_id uuid,
  target_screen_name text,
  actor_name text DEFAULT 'You'
) RETURNS SETOF api.work_item_assets
LANGUAGE plpgsql AS $$
DECLARE asset api.work_item_assets; item api.work_items; normalized_name text;
BEGIN
  normalized_name := btrim(COALESCE(target_screen_name, ''));
  SELECT * INTO asset FROM api.work_item_assets WHERE id = target_asset_id FOR UPDATE;
  IF asset.id IS NULL THEN RAISE EXCEPTION 'Visual asset not found.'; END IF;
  SELECT * INTO item FROM api.work_items WHERE id = asset.work_item_id;
  IF asset.asset_type NOT IN ('mockup', 'wireframe') THEN
    RAISE EXCEPTION 'Only mockups and wireframes can be assigned to a screen.' USING ERRCODE = '23514';
  END IF;
  IF normalized_name = '' OR NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements_text(item.screen_names) name
    WHERE lower(name) = lower(normalized_name)
  ) THEN
    RAISE EXCEPTION 'The screen must first be declared on the story or design card.' USING ERRCODE = '23514';
  END IF;
  UPDATE api.work_item_assets
  SET screen_name = normalized_name, approval_status = 'candidate', approved_by = NULL, approved_at = NULL
  WHERE id = asset.id RETURNING * INTO asset;
  INSERT INTO api.activity_events(project_id, work_item_id, event_type, actor_type, actor_name, summary, details)
  VALUES (asset.project_id, asset.work_item_id, 'work_item.mockup_assigned',
    CASE WHEN actor_name = 'You' THEN 'human' ELSE 'agent' END, actor_name,
    'Assigned a mockup to ' || normalized_name,
    jsonb_build_object('asset_id', asset.id, 'screen_name', normalized_name));
  RETURN NEXT asset;
END $$;

CREATE OR REPLACE FUNCTION api.approve_visual_concept(
  target_work_item_id uuid,
  target_asset_id uuid,
  actor_name text DEFAULT 'You'
) RETURNS SETOF api.work_item_assets
LANGUAGE plpgsql AS $$
DECLARE item api.work_items; asset api.work_item_assets; option_count integer;
BEGIN
  SELECT * INTO item FROM api.work_items WHERE id = target_work_item_id FOR UPDATE;
  IF item.id IS NULL OR item.design_card_type <> 'visual_concept' THEN
    RAISE EXCEPTION 'The selected work item is not a visual concept design card.' USING ERRCODE = '23514';
  END IF;
  SELECT * INTO asset FROM api.work_item_assets
  WHERE id = target_asset_id AND work_item_id = item.id AND asset_type IN ('mockup', 'wireframe') FOR UPDATE;
  IF asset.id IS NULL THEN RAISE EXCEPTION 'The selected concept option is not attached to this design card.'; END IF;
  SELECT count(*) INTO option_count FROM api.work_item_assets
  WHERE work_item_id = item.id AND asset_type IN ('mockup', 'wireframe');
  IF option_count < 2 THEN
    RAISE EXCEPTION 'Present at least two visual concept options before selecting one.' USING ERRCODE = '23514';
  END IF;
  UPDATE api.work_item_assets
  SET approval_status = CASE WHEN id = asset.id THEN 'approved' ELSE 'rejected' END,
      approved_by = CASE WHEN id = asset.id THEN actor_name ELSE NULL END,
      approved_at = CASE WHEN id = asset.id THEN now() ELSE NULL END,
      is_primary = id = asset.id
  WHERE work_item_id = item.id AND asset_type IN ('mockup', 'wireframe');
  SELECT * INTO asset FROM api.work_item_assets WHERE id = asset.id;
  INSERT INTO api.project_design_governance(
    project_id, concept_design_card_id, approved_concept_asset_id,
    concept_approved_by, concept_approved_at
  ) VALUES (item.project_id, item.id, asset.id, actor_name, now())
  ON CONFLICT (project_id) DO UPDATE SET
    concept_design_card_id = EXCLUDED.concept_design_card_id,
    approved_concept_asset_id = EXCLUDED.approved_concept_asset_id,
    concept_approved_by = EXCLUDED.concept_approved_by,
    concept_approved_at = EXCLUDED.concept_approved_at,
    design_concept_artifact_id = NULL,
    design_concept_approved_by = NULL,
    design_concept_approved_at = NULL,
    style_guide_artifact_id = NULL,
    style_guide_approved_by = NULL,
    style_guide_approved_at = NULL;
  UPDATE api.project_artifacts
  SET status = 'draft', metadata = metadata - 'approved' - 'approved_by' - 'approved_at'
  WHERE project_id = item.project_id AND artifact_key IN ('design-concept', 'style-guide');
  INSERT INTO api.activity_events(project_id, work_item_id, event_type, actor_type, actor_name, summary, details)
  VALUES (item.project_id, item.id, 'work_item.visual_concept_approved', 'human', actor_name,
    'Approved the visual concept for ' || item.item_key,
    jsonb_build_object('asset_id', asset.id, 'option_count', option_count));
  RETURN NEXT asset;
END $$;

CREATE OR REPLACE FUNCTION api.approve_design_concept(
  target_project_id uuid,
  actor_name text DEFAULT 'You'
) RETURNS SETOF api.project_artifacts
LANGUAGE plpgsql AS $$
DECLARE concept api.project_artifacts; governance api.project_design_governance;
BEGIN
  SELECT * INTO governance FROM api.project_design_governance WHERE project_id = target_project_id FOR UPDATE;
  IF governance.approved_concept_asset_id IS NULL THEN
    RAISE EXCEPTION 'Select a visual concept option before approving the design concept artefact.' USING ERRCODE = '23514';
  END IF;
  SELECT * INTO concept FROM api.project_artifacts
  WHERE project_id = target_project_id AND artifact_key = 'design-concept' FOR UPDATE;
  IF concept.id IS NULL THEN RAISE EXCEPTION 'Design concept record not found.'; END IF;
  IF length(btrim(concept.content)) < 200
    OR concept.content !~* '(rationale|decision)'
    OR concept.content !~* '(principle|direction)'
    OR concept.content !~* '(journey|flow)'
    OR concept.content !~* '(information architecture|navigation)'
    OR concept.content !~* '(screen|state)'
    OR concept.content !~* '(interaction|motion)'
    OR concept.content !~* 'responsive' THEN
    RAISE EXCEPTION 'The design concept must record rationale, design principles, journeys or flows, information architecture, screens and states, interaction language, and responsive intent.' USING ERRCODE = '23514';
  END IF;
  UPDATE api.project_artifacts
  SET status = 'current', metadata = metadata || jsonb_build_object(
    'approved', true, 'approved_by', actor_name, 'approved_at', now(),
    'selected_concept_asset_id', governance.approved_concept_asset_id
  )
  WHERE id = concept.id RETURNING * INTO concept;
  UPDATE api.project_design_governance
  SET design_concept_artifact_id = concept.id,
      design_concept_approved_by = actor_name,
      design_concept_approved_at = now(),
      style_guide_artifact_id = NULL,
      style_guide_approved_by = NULL,
      style_guide_approved_at = NULL
  WHERE project_id = target_project_id;
  INSERT INTO api.activity_events(project_id, event_type, actor_type, actor_name, summary, details)
  VALUES (target_project_id, 'project.design_concept_approved', 'human', actor_name,
    'Approved the application design concept', jsonb_build_object('artifact_id', concept.id, 'version', concept.version));
  RETURN NEXT concept;
END $$;

CREATE OR REPLACE FUNCTION api.approve_screen_mockup(
  target_asset_id uuid,
  actor_name text DEFAULT 'You'
) RETURNS SETOF api.work_item_assets
LANGUAGE plpgsql AS $$
DECLARE asset api.work_item_assets; item api.work_items;
BEGIN
  SELECT * INTO asset FROM api.work_item_assets WHERE id = target_asset_id FOR UPDATE;
  IF asset.id IS NULL OR asset.asset_type NOT IN ('mockup', 'wireframe') OR btrim(COALESCE(asset.screen_name, '')) = '' THEN
    RAISE EXCEPTION 'An approved screen mockup must be a mockup or wireframe assigned to a declared screen.' USING ERRCODE = '23514';
  END IF;
  SELECT * INTO item FROM api.work_items WHERE id = asset.work_item_id;
  IF NOT EXISTS (
    SELECT 1 FROM api.project_design_governance governance
    WHERE governance.project_id = item.project_id
      AND governance.approved_concept_asset_id IS NOT NULL
      AND governance.design_concept_artifact_id IS NOT NULL
      AND governance.style_guide_artifact_id IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'Approve the visual concept, design concept artefact, and design system before approving screen mockups.' USING ERRCODE = '23514';
  END IF;
  UPDATE api.work_item_assets
  SET approval_status = 'approved', approved_by = actor_name, approved_at = now()
  WHERE id = asset.id RETURNING * INTO asset;
  INSERT INTO api.activity_events(project_id, work_item_id, event_type, actor_type, actor_name, summary, details)
  VALUES (asset.project_id, asset.work_item_id, 'work_item.screen_mockup_approved', 'human', actor_name,
    'Approved the ' || asset.screen_name || ' screen mockup',
    jsonb_build_object('asset_id', asset.id, 'screen_name', asset.screen_name));
  RETURN NEXT asset;
END $$;

CREATE OR REPLACE FUNCTION api.approve_style_guide(
  target_project_id uuid,
  actor_name text DEFAULT 'You'
) RETURNS SETOF api.project_artifacts
LANGUAGE plpgsql AS $$
DECLARE guide api.project_artifacts; governance api.project_design_governance;
BEGIN
  SELECT * INTO governance FROM api.project_design_governance WHERE project_id = target_project_id FOR UPDATE;
  IF governance.approved_concept_asset_id IS NULL THEN
    RAISE EXCEPTION 'Approve a visual concept before approving the style guide.' USING ERRCODE = '23514';
  END IF;
  IF governance.design_concept_artifact_id IS NULL THEN
    RAISE EXCEPTION 'Approve the design concept artefact before approving the design system.' USING ERRCODE = '23514';
  END IF;
  SELECT * INTO guide FROM api.project_artifacts
  WHERE project_id = target_project_id AND artifact_key = 'style-guide' FOR UPDATE;
  IF guide.id IS NULL THEN RAISE EXCEPTION 'Style guide record not found.'; END IF;
  IF length(btrim(guide.content)) < 200
    OR guide.content !~* '(colour|color)'
    OR guide.content !~* 'typograph'
    OR guide.content !~* 'spacing'
    OR guide.content !~* 'component'
    OR guide.content !~* '(interaction|motion)'
    OR guide.content !~* 'responsive'
    OR guide.content !~* 'accessib' THEN
    RAISE EXCEPTION 'The design system must define colour, typography, spacing, components, interaction or motion, responsive behaviour, and accessibility.' USING ERRCODE = '23514';
  END IF;
  UPDATE api.project_artifacts
  SET status = 'current', metadata = metadata || jsonb_build_object(
    'approved', true, 'approved_by', actor_name, 'approved_at', now()
  )
  WHERE id = guide.id RETURNING * INTO guide;
  UPDATE api.project_design_governance
  SET style_guide_artifact_id = guide.id,
      style_guide_approved_by = actor_name,
      style_guide_approved_at = now()
  WHERE project_id = target_project_id;
  INSERT INTO api.activity_events(project_id, event_type, actor_type, actor_name, summary, details)
  VALUES (target_project_id, 'project.style_guide_approved', 'human', actor_name,
    'Approved the application design system and style guide', jsonb_build_object('artifact_id', guide.id, 'version', guide.version));
  RETURN NEXT guide;
END $$;

CREATE OR REPLACE FUNCTION api.visual_design_gate_requirements(target_work_item_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  item api.work_items;
  governance api.project_design_governance;
  requirements jsonb := '[]'::jsonb;
  screen text;
  option_count integer;
BEGIN
  SELECT * INTO item FROM api.work_items WHERE id = target_work_item_id;
  IF item.id IS NULL OR item.kind <> 'story' OR NOT api.work_item_requires_visual_evidence(item.id) THEN
    RETURN requirements;
  END IF;
  SELECT * INTO governance FROM api.project_design_governance WHERE project_id = item.project_id;
  IF item.design_card_type = 'visual_concept' THEN
    SELECT count(*) INTO option_count FROM api.work_item_assets
    WHERE work_item_id = item.id AND asset_type IN ('mockup', 'wireframe');
    requirements := requirements || jsonb_build_array(
      jsonb_build_object('requirement', 'The visual concept design card presents at least two mockup options', 'satisfied', option_count >= 2, 'blocking', true),
      jsonb_build_object('requirement', 'A person has approved one visual concept option', 'satisfied', governance.approved_concept_asset_id IS NOT NULL AND governance.concept_design_card_id = item.id, 'blocking', true),
      jsonb_build_object('requirement', 'The selected direction is recorded in an approved design concept artefact', 'satisfied', governance.design_concept_artifact_id IS NOT NULL, 'blocking', true),
      jsonb_build_object('requirement', 'The approved concept has an approved design system and style guide', 'satisfied', governance.style_guide_artifact_id IS NOT NULL, 'blocking', true)
    );
    RETURN requirements;
  END IF;
  requirements := requirements || jsonb_build_array(
    jsonb_build_object('requirement', 'A person has approved the project visual concept', 'satisfied', governance.approved_concept_asset_id IS NOT NULL, 'blocking', true),
    jsonb_build_object('requirement', 'The selected direction is recorded in an approved design concept artefact', 'satisfied', governance.design_concept_artifact_id IS NOT NULL, 'blocking', true),
    jsonb_build_object('requirement', 'The project design system and style guide are approved', 'satisfied', governance.style_guide_artifact_id IS NOT NULL, 'blocking', true),
    jsonb_build_object('requirement', 'Every visual implementation story declares its affected screens, important states, and viewport variants', 'satisfied', jsonb_array_length(item.screen_names) > 0, 'blocking', true)
  );
  FOR screen IN SELECT value FROM jsonb_array_elements_text(item.screen_names)
  LOOP
    requirements := requirements || jsonb_build_array(jsonb_build_object(
      'requirement', 'An approved mockup exists for the ' || screen || ' screen',
      'screen_name', screen,
      'satisfied', EXISTS (
        SELECT 1
        FROM api.work_item_assets asset
        JOIN api.work_items owner_item ON owner_item.id = asset.work_item_id
        WHERE asset.project_id = item.project_id
          AND asset.asset_type IN ('mockup', 'wireframe')
          AND asset.approval_status = 'approved'
          AND lower(asset.screen_name) = lower(screen)
          AND (owner_item.id = item.id OR owner_item.design_card_type = 'screen_mockup')
      ),
      'blocking', true
    ));
  END LOOP;
  RETURN requirements;
END $$;

CREATE OR REPLACE FUNCTION api.enforce_visual_evidence_stage_transition() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  previous_stage api.board_stages;
  next_stage api.board_stages;
  implementation_revision text;
  accepted_revision text;
  design_requirements jsonb;
BEGIN
  IF NEW.stage_id = OLD.stage_id OR OLD.kind <> 'story' OR NOT api.work_item_requires_visual_evidence(OLD.id) THEN RETURN NEW; END IF;
  SELECT * INTO previous_stage FROM api.board_stages WHERE id = OLD.stage_id;
  SELECT * INTO next_stage FROM api.board_stages WHERE id = NEW.stage_id;
  IF next_stage.slug = 'build' AND previous_stage.slug = 'plan' THEN
    design_requirements := api.visual_design_gate_requirements(OLD.id);
    IF EXISTS (
      SELECT 1 FROM jsonb_array_elements(design_requirements) requirement
      WHERE NOT COALESCE((requirement->>'satisfied')::boolean, false)
    ) THEN
      RAISE EXCEPTION 'Visual story cannot enter Build until its concept option, design concept artefact, design system, screen inventory, and screen mockups are approved.' USING ERRCODE = '23514';
    END IF;
  END IF;
  IF next_stage.slug = 'validate' THEN
    SELECT evidence.revision INTO implementation_revision FROM api.work_item_evidence evidence
    WHERE evidence.work_item_id = OLD.id AND evidence.evidence_type = 'implementation'
      AND evidence.outcome IN ('recorded','passed') AND evidence.revision IS NOT NULL
    ORDER BY evidence.created_at DESC LIMIT 1;
    IF implementation_revision IS NULL OR NOT EXISTS (
      SELECT 1 FROM api.work_item_assets asset WHERE asset.work_item_id = OLD.id
        AND asset.asset_type = 'implementation_screenshot' AND asset.revision = implementation_revision
    ) THEN
      RAISE EXCEPTION 'Visual story cannot enter Validate without an implementation screenshot for the exact implementation revision.' USING ERRCODE = '23514';
    END IF;
  END IF;
  IF next_stage.slug = 'review' THEN
    SELECT criterion->>'revision' INTO accepted_revision FROM jsonb_array_elements(OLD.acceptance_criteria) criterion LIMIT 1;
    IF accepted_revision IS NULL OR NOT EXISTS (
      SELECT 1 FROM api.work_item_assets asset WHERE asset.work_item_id = OLD.id
        AND asset.asset_type IN ('visual_validation','visual_diff') AND asset.revision = accepted_revision
    ) THEN
      RAISE EXCEPTION 'Visual story cannot enter Review without visual validation for the accepted revision.' USING ERRCODE = '23514';
    END IF;
  END IF;
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION api.get_governed_work_item_context(target_work_item_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  item api.work_items;
  context jsonb;
  requirements jsonb;
  design_requirements jsonb;
  governance jsonb;
BEGIN
  SELECT * INTO item FROM api.work_items WHERE id = target_work_item_id;
  IF item.id IS NULL THEN RAISE EXCEPTION 'Work item not found.'; END IF;
  context := api.get_work_item_context_with_visuals(target_work_item_id);
  SELECT jsonb_build_object(
    'design_card_type', item.design_card_type,
    'screen_names', item.screen_names,
    'concept_design_card_id', record.concept_design_card_id,
    'approved_concept_asset_id', record.approved_concept_asset_id,
    'concept_approved_by', record.concept_approved_by,
    'concept_approved_at', record.concept_approved_at,
    'design_concept_artifact_id', record.design_concept_artifact_id,
    'design_concept_approved_by', record.design_concept_approved_by,
    'design_concept_approved_at', record.design_concept_approved_at,
    'style_guide_artifact_id', record.style_guide_artifact_id,
    'style_guide_approved_by', record.style_guide_approved_by,
    'style_guide_approved_at', record.style_guide_approved_at
  ) INTO governance
  FROM api.project_design_governance record WHERE record.project_id = item.project_id;
  context := context || jsonb_build_object(
    'design_governance', COALESCE(governance, jsonb_build_object(
      'design_card_type', item.design_card_type, 'screen_names', item.screen_names
    ))
  );
  IF context #>> '{promotion,current_stage,slug}' = 'plan' THEN
    requirements := COALESCE(context #> '{promotion,acceptance_criteria}', '[]'::jsonb);
    design_requirements := api.visual_design_gate_requirements(item.id);
    requirements := requirements || design_requirements;
    context := jsonb_set(context, '{promotion,acceptance_criteria}', requirements, true);
    context := jsonb_set(context, '{promotion,ready}', to_jsonb(NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(requirements) requirement
      WHERE COALESCE((requirement->>'blocking')::boolean, true)
        AND NOT COALESCE((requirement->>'satisfied')::boolean, false)
    )), true);
  END IF;
  RETURN context;
END $$;

CREATE OR REPLACE FUNCTION api.claim_next_work_package(
  target_project_id uuid,
  agent_name text
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE item api.work_items;
BEGIN
  SELECT * INTO item FROM api.claim_next_ready_work_item(target_project_id, agent_name);
  IF item.id IS NULL THEN
    RETURN jsonb_build_object('outcome', 'no_ready_work', 'work_package', NULL);
  END IF;
  RETURN jsonb_build_object('outcome', 'claimed', 'work_package', api.get_governed_work_item_context(item.id));
END $$;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.project_design_governance TO web_anon;
GRANT EXECUTE ON FUNCTION api.set_design_card(uuid, text, jsonb, text) TO web_anon;
GRANT EXECUTE ON FUNCTION api.set_work_item_asset_screen(uuid, text, text) TO web_anon;
GRANT EXECUTE ON FUNCTION api.approve_visual_concept(uuid, uuid, text) TO web_anon;
GRANT EXECUTE ON FUNCTION api.approve_design_concept(uuid, text) TO web_anon;
GRANT EXECUTE ON FUNCTION api.approve_screen_mockup(uuid, text) TO web_anon;
GRANT EXECUTE ON FUNCTION api.approve_style_guide(uuid, text) TO web_anon;
GRANT EXECUTE ON FUNCTION api.visual_design_gate_requirements(uuid) TO web_anon;
GRANT EXECUTE ON FUNCTION api.get_governed_work_item_context(uuid) TO web_anon;
GRANT EXECUTE ON FUNCTION api.claim_next_work_package(uuid, text) TO web_anon;

NOTIFY pgrst, 'reload schema';
