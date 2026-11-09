-- Screenshot existence is not design fidelity. Visual stories may enter Review
-- only after every declared screen has a structured, same-viewport comparison
-- against a human-approved mockup for the exact accepted revision.

CREATE TABLE IF NOT EXISTS api.work_item_visual_validations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id uuid NOT NULL REFERENCES api.projects(id) ON DELETE CASCADE,
  work_item_id uuid NOT NULL REFERENCES api.work_items(id) ON DELETE CASCADE,
  screen_name text NOT NULL CHECK (btrim(screen_name) <> ''),
  source_mockup_asset_id uuid NOT NULL REFERENCES api.work_item_assets(id) ON DELETE RESTRICT,
  validation_asset_id uuid NOT NULL REFERENCES api.work_item_assets(id) ON DELETE RESTRICT,
  revision text NOT NULL CHECK (btrim(revision) <> ''),
  viewport_width integer NOT NULL CHECK (viewport_width > 0),
  viewport_height integer NOT NULL CHECK (viewport_height > 0),
  comparison_method text NOT NULL CHECK (
    comparison_method IN ('side_by_side', 'overlay', 'pixel_diff', 'html_reference')
  ),
  same_viewport boolean NOT NULL,
  represents_approved_design boolean NOT NULL,
  structural_match boolean NOT NULL,
  unresolved_p0 integer NOT NULL DEFAULT 0 CHECK (unresolved_p0 >= 0),
  unresolved_p1 integer NOT NULL DEFAULT 0 CHECK (unresolved_p1 >= 0),
  unresolved_p2 integer NOT NULL DEFAULT 0 CHECK (unresolved_p2 >= 0),
  notes text NOT NULL DEFAULT '',
  actor_name text NOT NULL DEFAULT 'AI agent',
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS work_item_visual_validations_lookup_idx
  ON api.work_item_visual_validations(work_item_id, lower(screen_name), revision, created_at DESC);

CREATE UNIQUE INDEX IF NOT EXISTS work_item_visual_validations_evidence_idx
  ON api.work_item_visual_validations(
    work_item_id,
    lower(screen_name),
    revision,
    validation_asset_id
  );

CREATE OR REPLACE FUNCTION api.record_visual_design_validation(
  target_work_item_id uuid,
  target_screen_name text,
  target_source_mockup_asset_id uuid,
  target_validation_asset_id uuid,
  target_revision text,
  target_viewport_width integer,
  target_viewport_height integer,
  target_comparison_method text,
  target_same_viewport boolean,
  target_represents_approved_design boolean,
  target_structural_match boolean,
  target_unresolved_p0 integer DEFAULT 0,
  target_unresolved_p1 integer DEFAULT 0,
  target_unresolved_p2 integer DEFAULT 0,
  validation_notes text DEFAULT '',
  actor_name text DEFAULT 'AI agent'
) RETURNS SETOF api.work_item_visual_validations
LANGUAGE plpgsql AS $$
DECLARE
  item api.work_items;
  source_asset api.work_item_assets;
  source_owner api.work_items;
  validation_asset api.work_item_assets;
  validation api.work_item_visual_validations;
  normalized_screen text := btrim(COALESCE(target_screen_name, ''));
  normalized_revision text := btrim(COALESCE(target_revision, ''));
BEGIN
  SELECT * INTO item FROM api.work_items WHERE id = target_work_item_id FOR UPDATE;
  IF item.id IS NULL THEN RAISE EXCEPTION 'Work item not found.'; END IF;
  IF item.kind <> 'story' OR NOT api.work_item_requires_visual_evidence(item.id) THEN
    RAISE EXCEPTION 'Structured visual fidelity validation applies only to visual stories.' USING ERRCODE = '23514';
  END IF;
  IF normalized_screen = '' OR NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements_text(item.screen_names) declared_screen
    WHERE lower(declared_screen) = lower(normalized_screen)
  ) THEN
    RAISE EXCEPTION 'The validation screen must be declared on the visual story.' USING ERRCODE = '23514';
  END IF;
  IF normalized_revision = '' THEN
    RAISE EXCEPTION 'Visual validation must identify the exact implementation revision.' USING ERRCODE = '23514';
  END IF;
  IF target_viewport_width IS NULL OR target_viewport_width <= 0
    OR target_viewport_height IS NULL OR target_viewport_height <= 0 THEN
    RAISE EXCEPTION 'Visual validation requires a positive comparison viewport.' USING ERRCODE = '23514';
  END IF;
  IF target_comparison_method NOT IN ('side_by_side', 'overlay', 'pixel_diff', 'html_reference') THEN
    RAISE EXCEPTION 'Unsupported comparison method: %', target_comparison_method USING ERRCODE = '23514';
  END IF;
  IF COALESCE(target_unresolved_p0, -1) < 0 OR COALESCE(target_unresolved_p1, -1) < 0
    OR COALESCE(target_unresolved_p2, -1) < 0 THEN
    RAISE EXCEPTION 'Unresolved finding counts cannot be negative or null.' USING ERRCODE = '23514';
  END IF;

  SELECT * INTO source_asset FROM api.work_item_assets
  WHERE id = target_source_mockup_asset_id FOR UPDATE;
  IF source_asset.id IS NULL
    OR source_asset.project_id <> item.project_id
    OR source_asset.asset_type NOT IN ('mockup', 'wireframe')
    OR source_asset.approval_status <> 'approved'
    OR lower(COALESCE(source_asset.screen_name, '')) <> lower(normalized_screen) THEN
    RAISE EXCEPTION 'The source must be a human-approved mockup or wireframe for the declared screen.' USING ERRCODE = '23514';
  END IF;
  SELECT * INTO source_owner FROM api.work_items WHERE id = source_asset.work_item_id;
  IF source_owner.id <> item.id AND source_owner.design_card_type IS DISTINCT FROM 'screen_mockup' THEN
    RAISE EXCEPTION 'The approved source must belong to this story or a governed screen-mockup card.' USING ERRCODE = '23514';
  END IF;

  SELECT * INTO validation_asset FROM api.work_item_assets
  WHERE id = target_validation_asset_id FOR UPDATE;
  IF validation_asset.id IS NULL
    OR validation_asset.work_item_id <> item.id
    OR validation_asset.asset_type NOT IN ('visual_validation', 'visual_diff')
    OR validation_asset.revision IS DISTINCT FROM normalized_revision THEN
    RAISE EXCEPTION 'The validation asset must be a visual validation or diff attached to this story at the exact revision.' USING ERRCODE = '23514';
  END IF;
  IF validation_asset.viewport_width IS DISTINCT FROM target_viewport_width
    OR validation_asset.viewport_height IS DISTINCT FROM target_viewport_height THEN
    RAISE EXCEPTION 'The validation asset viewport must equal the recorded comparison viewport.' USING ERRCODE = '23514';
  END IF;

  INSERT INTO api.work_item_visual_validations(
    project_id, work_item_id, screen_name, source_mockup_asset_id,
    validation_asset_id, revision, viewport_width, viewport_height,
    comparison_method, same_viewport, represents_approved_design,
    structural_match, unresolved_p0, unresolved_p1, unresolved_p2,
    notes, actor_name
  ) VALUES (
    item.project_id, item.id, normalized_screen, source_asset.id,
    validation_asset.id, normalized_revision, target_viewport_width, target_viewport_height,
    target_comparison_method, COALESCE(target_same_viewport, false),
    COALESCE(target_represents_approved_design, false),
    COALESCE(target_structural_match, false), target_unresolved_p0,
    target_unresolved_p1, target_unresolved_p2,
    COALESCE(validation_notes, ''), actor_name
  )
  ON CONFLICT (work_item_id, (lower(screen_name)), revision, validation_asset_id)
  DO UPDATE SET
    source_mockup_asset_id = EXCLUDED.source_mockup_asset_id,
    viewport_width = EXCLUDED.viewport_width,
    viewport_height = EXCLUDED.viewport_height,
    comparison_method = EXCLUDED.comparison_method,
    same_viewport = EXCLUDED.same_viewport,
    represents_approved_design = EXCLUDED.represents_approved_design,
    structural_match = EXCLUDED.structural_match,
    unresolved_p0 = EXCLUDED.unresolved_p0,
    unresolved_p1 = EXCLUDED.unresolved_p1,
    unresolved_p2 = EXCLUDED.unresolved_p2,
    notes = EXCLUDED.notes,
    actor_name = EXCLUDED.actor_name,
    created_at = now()
  RETURNING * INTO validation;

  INSERT INTO api.activity_events(
    project_id, work_item_id, event_type, actor_type, actor_name, summary, details
  ) VALUES (
    item.project_id, item.id, 'work_item.visual_fidelity_validated',
    CASE WHEN actor_name = 'You' THEN 'human' ELSE 'agent' END,
    actor_name,
    'Recorded visual fidelity validation for ' || normalized_screen,
    jsonb_build_object(
      'validation_id', validation.id,
      'screen_name', normalized_screen,
      'revision', normalized_revision,
      'viewport', jsonb_build_object('width', target_viewport_width, 'height', target_viewport_height),
      'comparison_method', target_comparison_method,
      'same_viewport', validation.same_viewport,
      'represents_approved_design', validation.represents_approved_design,
      'structural_match', validation.structural_match,
      'unresolved_p0', validation.unresolved_p0,
      'unresolved_p1', validation.unresolved_p1,
      'unresolved_p2', validation.unresolved_p2
    )
  );
  RETURN NEXT validation;
END $$;

CREATE OR REPLACE FUNCTION api.visual_fidelity_gate_requirements(
  target_work_item_id uuid,
  target_revision text
) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  item api.work_items;
  requirements jsonb := '[]'::jsonb;
  screen text;
  validation api.work_item_visual_validations;
  source_is_valid boolean;
  evidence_is_valid boolean;
  satisfied boolean;
BEGIN
  SELECT * INTO item FROM api.work_items WHERE id = target_work_item_id;
  IF item.id IS NULL OR item.kind <> 'story' OR NOT api.work_item_requires_visual_evidence(item.id) THEN
    RETURN requirements;
  END IF;

  FOR screen IN SELECT value FROM jsonb_array_elements_text(item.screen_names)
  LOOP
    validation := NULL;
    SELECT * INTO validation
    FROM api.work_item_visual_validations record
    WHERE record.work_item_id = item.id
      AND lower(record.screen_name) = lower(screen)
      AND record.revision = target_revision
    ORDER BY record.created_at DESC
    LIMIT 1;

    source_is_valid := validation.id IS NOT NULL AND EXISTS (
      SELECT 1
      FROM api.work_item_assets asset
      JOIN api.work_items owner_item ON owner_item.id = asset.work_item_id
      WHERE asset.id = validation.source_mockup_asset_id
        AND asset.project_id = item.project_id
        AND asset.asset_type IN ('mockup', 'wireframe')
        AND asset.approval_status = 'approved'
        AND lower(asset.screen_name) = lower(screen)
        AND (owner_item.id = item.id OR owner_item.design_card_type = 'screen_mockup')
    );
    evidence_is_valid := validation.id IS NOT NULL AND EXISTS (
      SELECT 1 FROM api.work_item_assets asset
      WHERE asset.id = validation.validation_asset_id
        AND asset.work_item_id = item.id
        AND asset.asset_type IN ('visual_validation', 'visual_diff')
        AND asset.revision = target_revision
        AND asset.viewport_width = validation.viewport_width
        AND asset.viewport_height = validation.viewport_height
    );
    satisfied := validation.id IS NOT NULL
      AND source_is_valid
      AND evidence_is_valid
      AND validation.same_viewport
      AND validation.represents_approved_design
      AND validation.structural_match
      AND validation.unresolved_p0 = 0
      AND validation.unresolved_p1 = 0
      AND validation.unresolved_p2 = 0;

    requirements := requirements || jsonb_build_array(jsonb_build_object(
      'requirement', 'The rendered ' || screen || ' screen represents its approved design at the same viewport with zero unresolved P0/P1/P2 findings',
      'screen_name', screen,
      'revision', target_revision,
      'validation_id', validation.id,
      'source_mockup_asset_id', validation.source_mockup_asset_id,
      'validation_asset_id', validation.validation_asset_id,
      'viewport_width', validation.viewport_width,
      'viewport_height', validation.viewport_height,
      'comparison_method', validation.comparison_method,
      'same_viewport', COALESCE(validation.same_viewport, false),
      'represents_approved_design', COALESCE(validation.represents_approved_design, false),
      'structural_match', COALESCE(validation.structural_match, false),
      'unresolved_p0', validation.unresolved_p0,
      'unresolved_p1', validation.unresolved_p1,
      'unresolved_p2', validation.unresolved_p2,
      'source_is_valid', source_is_valid,
      'evidence_is_valid', evidence_is_valid,
      'satisfied', satisfied,
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
  fidelity_requirements jsonb;
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
    SELECT criterion->>'revision' INTO accepted_revision
    FROM jsonb_array_elements(OLD.acceptance_criteria) criterion
    WHERE criterion->>'status' = 'passed' AND btrim(COALESCE(criterion->>'revision', '')) <> ''
    LIMIT 1;
    fidelity_requirements := api.visual_fidelity_gate_requirements(OLD.id, accepted_revision);
    IF jsonb_array_length(fidelity_requirements) = 0 OR EXISTS (
      SELECT 1 FROM jsonb_array_elements(fidelity_requirements) requirement
      WHERE NOT COALESCE((requirement->>'satisfied')::boolean, false)
    ) THEN
      RAISE EXCEPTION 'Visual story cannot enter Review until every declared screen has passing same-viewport fidelity validation against an approved mockup for the exact accepted revision, with structural representation and zero unresolved P0/P1/P2 findings.' USING ERRCODE = '23514';
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
  fidelity_requirements jsonb;
  governance jsonb;
  accepted_revision text;
  validations jsonb;
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
  SELECT COALESCE(jsonb_agg(to_jsonb(validation) ORDER BY validation.created_at), '[]'::jsonb)
  INTO validations
  FROM api.work_item_visual_validations validation
  WHERE validation.work_item_id = item.id;
  context := context || jsonb_build_object(
    'design_governance', COALESCE(governance, jsonb_build_object(
      'design_card_type', item.design_card_type, 'screen_names', item.screen_names
    )),
    'visual_fidelity_validations', validations
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
  ELSIF context #>> '{promotion,current_stage,slug}' = 'validate'
    AND api.work_item_requires_visual_evidence(item.id) THEN
    SELECT criterion->>'revision' INTO accepted_revision
    FROM jsonb_array_elements(item.acceptance_criteria) criterion
    WHERE criterion->>'status' = 'passed' AND btrim(COALESCE(criterion->>'revision', '')) <> ''
    LIMIT 1;
    requirements := COALESCE(context #> '{promotion,acceptance_criteria}', '[]'::jsonb);
    fidelity_requirements := api.visual_fidelity_gate_requirements(item.id, accepted_revision);
    requirements := requirements || fidelity_requirements;
    context := jsonb_set(context, '{promotion,acceptance_criteria}', requirements, true);
    context := jsonb_set(context, '{promotion,ready}', to_jsonb(NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(requirements) requirement
      WHERE COALESCE((requirement->>'blocking')::boolean, true)
        AND NOT COALESCE((requirement->>'satisfied')::boolean, false)
    )), true);
  END IF;
  RETURN context;
END $$;

COMMENT ON TABLE api.work_item_visual_validations IS
  'Structured screen-level fidelity comparisons that bind an approved mockup and validation asset to an exact implementation revision.';
COMMENT ON FUNCTION api.record_visual_design_validation(
  uuid, text, uuid, uuid, text, integer, integer, text, boolean, boolean,
  boolean, integer, integer, integer, text, text
) IS
  'Records, but does not self-approve, whether a rendered screen structurally represents its human-approved design.';

GRANT SELECT, INSERT, UPDATE, DELETE ON api.work_item_visual_validations TO web_anon;
GRANT EXECUTE ON FUNCTION api.record_visual_design_validation(
  uuid, text, uuid, uuid, text, integer, integer, text, boolean, boolean,
  boolean, integer, integer, integer, text, text
) TO web_anon;
GRANT EXECUTE ON FUNCTION api.visual_fidelity_gate_requirements(uuid, text) TO web_anon;
GRANT EXECUTE ON FUNCTION api.get_governed_work_item_context(uuid) TO web_anon;

NOTIFY pgrst, 'reload schema';
