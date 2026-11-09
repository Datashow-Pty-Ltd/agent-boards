-- Product Design workflows are exposed as governed service packages. Agent Boards
-- resolves durable inputs and records outcomes; the connected host performs the
-- image-to-code implementation and design-QA inspection with its native tools.

ALTER TABLE api.work_item_visual_validations
  ADD COLUMN IF NOT EXISTS findings jsonb NOT NULL DEFAULT '[]'::jsonb;

ALTER TABLE api.work_item_visual_validations
  DROP CONSTRAINT IF EXISTS work_item_visual_validations_findings_array;
ALTER TABLE api.work_item_visual_validations
  ADD CONSTRAINT work_item_visual_validations_findings_array
  CHECK (jsonb_typeof(findings) = 'array');

CREATE OR REPLACE FUNCTION api.get_mockup_implementation_package(
  target_work_item_id uuid
) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  item api.work_items;
  repository jsonb;
  governance jsonb;
  design_artifacts jsonb;
  approved_mockups jsonb;
BEGIN
  SELECT * INTO item FROM api.work_items WHERE id = target_work_item_id;
  IF item.id IS NULL THEN RAISE EXCEPTION 'Work item not found.'; END IF;
  IF item.kind <> 'story' OR NOT api.work_item_requires_visual_evidence(item.id) THEN
    RAISE EXCEPTION 'Mockup implementation packages apply only to visual stories.' USING ERRCODE = '23514';
  END IF;

  SELECT to_jsonb(record) INTO repository
  FROM api.project_repositories record WHERE record.project_id = item.project_id;

  SELECT to_jsonb(record) INTO governance
  FROM api.project_design_governance record WHERE record.project_id = item.project_id;

  SELECT COALESCE(jsonb_agg(to_jsonb(artifact) ORDER BY artifact.artifact_key), '[]'::jsonb)
  INTO design_artifacts
  FROM api.project_artifacts artifact
  WHERE artifact.project_id = item.project_id
    AND artifact.id IN (
      SELECT design_concept_artifact_id FROM api.project_design_governance WHERE project_id = item.project_id
      UNION ALL
      SELECT style_guide_artifact_id FROM api.project_design_governance WHERE project_id = item.project_id
    );

  SELECT COALESCE(jsonb_agg(to_jsonb(source) ORDER BY source.screen_name), '[]'::jsonb)
  INTO approved_mockups
  FROM (
    SELECT DISTINCT ON (lower(asset.screen_name)) asset.*
    FROM api.work_item_assets asset
    JOIN api.work_items owner_item ON owner_item.id = asset.work_item_id
    WHERE asset.project_id = item.project_id
      AND asset.asset_type IN ('mockup', 'wireframe')
      AND asset.approval_status = 'approved'
      AND asset.screen_name IS NOT NULL
      AND EXISTS (
        SELECT 1 FROM jsonb_array_elements_text(item.screen_names) declared_screen
        WHERE lower(declared_screen) = lower(asset.screen_name)
      )
      AND (owner_item.id = item.id OR owner_item.design_card_type = 'screen_mockup')
    ORDER BY lower(asset.screen_name), asset.approved_at DESC NULLS LAST, asset.created_at DESC
  ) source;

  IF jsonb_array_length(item.screen_names) = 0 THEN
    RAISE EXCEPTION 'The visual story must declare its screen, state, and viewport variants.' USING ERRCODE = '23514';
  END IF;
  IF jsonb_array_length(approved_mockups) <> jsonb_array_length(item.screen_names) THEN
    RAISE EXCEPTION 'Every declared screen, state, and viewport requires an approved static mockup.' USING ERRCODE = '23514';
  END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(approved_mockups) source
    WHERE (source->>'viewport_width') IS NULL OR (source->>'viewport_height') IS NULL
  ) THEN
    RAISE EXCEPTION 'Every approved mockup must declare its comparison viewport.' USING ERRCODE = '23514';
  END IF;

  RETURN jsonb_build_object(
    'workflow', jsonb_build_object(
      'capability', 'mockup_to_interactive_react_html',
      'product_design_route', 'product-design:image-to-code',
      'execution_owner', 'connected_host_agent',
      'control_plane', 'agent-boards'
    ),
    'work_item', to_jsonb(item),
    'repository', repository,
    'declared_screen_state_viewports', (
      SELECT jsonb_agg(jsonb_build_object(
        'screen_name', source->>'screen_name',
        'viewport_width', (source->>'viewport_width')::integer,
        'viewport_height', (source->>'viewport_height')::integer
      ) ORDER BY source->>'screen_name')
      FROM jsonb_array_elements(approved_mockups) source
    ),
    'approved_static_mockups', approved_mockups,
    'design_governance', governance,
    'design_artifacts', design_artifacts,
    'acceptance_criteria', item.acceptance_criteria,
    'invariants', item.invariants,
    'required_measurements', jsonb_build_object(
      'typography', jsonb_build_array('font-family', 'font-size', 'font-weight', 'line-height', 'letter-spacing'),
      'geometry', jsonb_build_array('x', 'y', 'width', 'height', 'border-radius'),
      'spacing', jsonb_build_array('page-inset', 'section-gap', 'component-gap'),
      'color', jsonb_build_array('color', 'background-color', 'border-color'),
      'controls', 'Measure x, y, width, height, and border-radius for each visible control.',
      'severity_levels', jsonb_build_array('P0', 'P1', 'P2', 'P3')
    ),
    'evidence_destinations', jsonb_build_object(
      'implementation_screenshot', 'api.attach_work_item_asset(asset_type=implementation_screenshot, exact revision and viewport)',
      'visual_comparison', 'api.attach_work_item_asset(asset_type=visual_validation or visual_diff, exact revision and viewport)',
      'measured_critique', 'api.record_visual_critique',
      'promotion_gate', 'api.visual_fidelity_gate_requirements'
    ),
    'source_of_truth', 'The human-approved static mockup is authoritative; live HTML cannot approve itself.'
  );
END $$;

CREATE OR REPLACE FUNCTION api.get_visual_critique_package(
  target_work_item_id uuid,
  target_screen_name text,
  target_revision text
) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  item api.work_items;
  source_asset api.work_item_assets;
  implementation_asset api.work_item_assets;
  normalized_screen text := btrim(COALESCE(target_screen_name, ''));
  normalized_revision text := btrim(COALESCE(target_revision, ''));
BEGIN
  SELECT * INTO item FROM api.work_items WHERE id = target_work_item_id;
  IF item.id IS NULL THEN RAISE EXCEPTION 'Work item not found.'; END IF;
  IF item.kind <> 'story' OR NOT api.work_item_requires_visual_evidence(item.id) THEN
    RAISE EXCEPTION 'Visual critique packages apply only to visual stories.' USING ERRCODE = '23514';
  END IF;
  IF normalized_screen = '' OR NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements_text(item.screen_names) declared_screen
    WHERE lower(declared_screen) = lower(normalized_screen)
  ) THEN
    RAISE EXCEPTION 'The critique screen must be declared on the visual story.' USING ERRCODE = '23514';
  END IF;
  IF normalized_revision = '' THEN
    RAISE EXCEPTION 'The critique package requires an exact implementation revision.' USING ERRCODE = '23514';
  END IF;

  SELECT asset.* INTO source_asset
  FROM api.work_item_assets asset
  JOIN api.work_items owner_item ON owner_item.id = asset.work_item_id
  WHERE asset.project_id = item.project_id
    AND asset.asset_type IN ('mockup', 'wireframe')
    AND asset.approval_status = 'approved'
    AND lower(asset.screen_name) = lower(normalized_screen)
    AND (owner_item.id = item.id OR owner_item.design_card_type = 'screen_mockup')
  ORDER BY asset.approved_at DESC NULLS LAST, asset.created_at DESC
  LIMIT 1;
  IF source_asset.id IS NULL THEN
    RAISE EXCEPTION 'No human-approved static mockup exists for the declared screen.' USING ERRCODE = '23514';
  END IF;
  IF source_asset.viewport_width IS NULL OR source_asset.viewport_height IS NULL THEN
    RAISE EXCEPTION 'The approved source mockup must declare its comparison viewport.' USING ERRCODE = '23514';
  END IF;

  SELECT asset.* INTO implementation_asset
  FROM api.work_item_assets asset
  WHERE asset.work_item_id = item.id
    AND asset.asset_type = 'implementation_screenshot'
    AND asset.revision = normalized_revision
    AND asset.viewport_width = source_asset.viewport_width
    AND asset.viewport_height = source_asset.viewport_height
  ORDER BY asset.created_at DESC
  LIMIT 1;
  IF implementation_asset.id IS NULL THEN
    RAISE EXCEPTION 'An exact-revision implementation screenshot at the approved mockup viewport is required.' USING ERRCODE = '23514';
  END IF;

  RETURN jsonb_build_object(
    'workflow', jsonb_build_object(
      'capability', 'react_html_vs_image_mockup_critique',
      'product_design_route', 'product-design:design-qa',
      'execution_owner', 'connected_host_agent',
      'control_plane', 'agent-boards'
    ),
    'work_item_id', item.id,
    'screen_name', normalized_screen,
    'revision', normalized_revision,
    'viewport', jsonb_build_object('width', source_asset.viewport_width, 'height', source_asset.viewport_height),
    'same_viewport', true,
    'approved_static_mockup', to_jsonb(source_asset),
    'rendered_implementation', to_jsonb(implementation_asset),
    'required_measurements', api.get_mockup_implementation_package(item.id)->'required_measurements',
    'result_destination', 'api.record_visual_critique',
    'comparison_evidence_destination', 'api.attach_work_item_asset(asset_type=visual_validation or visual_diff, same viewport and exact revision)',
    'promotion_gate', api.visual_fidelity_gate_requirements(item.id, normalized_revision),
    'source_of_truth', 'The human-approved static mockup is authoritative; the rendered implementation cannot approve itself.'
  );
END $$;

CREATE OR REPLACE FUNCTION api.record_visual_critique(
  target_work_item_id uuid,
  target_screen_name text,
  target_source_mockup_asset_id uuid,
  target_validation_asset_id uuid,
  target_revision text,
  target_viewport_width integer,
  target_viewport_height integer,
  target_comparison_method text,
  target_same_viewport boolean,
  target_structural_match boolean,
  target_controls_present boolean,
  target_measurements jsonb,
  target_findings jsonb,
  target_measurement_method text,
  critique_notes text DEFAULT '',
  actor_name text DEFAULT 'AI agent'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  validation api.work_item_visual_validations;
  material_p0 integer;
  material_p1 integer;
  material_p2 integer;
  passed boolean;
BEGIN
  IF jsonb_typeof(COALESCE(target_findings, 'null'::jsonb)) <> 'array' THEN
    RAISE EXCEPTION 'Visual critique findings must be a JSON array.' USING ERRCODE = '23514';
  END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(target_findings) finding
    WHERE jsonb_typeof(finding) <> 'object'
      OR finding->>'severity' NOT IN ('P0', 'P1', 'P2', 'P3')
      OR btrim(COALESCE(finding->>'summary', '')) = ''
      OR jsonb_typeof(finding->'resolved') <> 'boolean'
  ) THEN
    RAISE EXCEPTION 'Every critique finding requires severity P0-P3, a summary, and a boolean resolved value.' USING ERRCODE = '23514';
  END IF;

  SELECT * INTO validation FROM api.record_visual_design_validation(
    target_work_item_id,
    target_screen_name,
    target_source_mockup_asset_id,
    target_validation_asset_id,
    target_revision,
    target_viewport_width,
    target_viewport_height,
    target_comparison_method,
    target_same_viewport,
    true,
    target_structural_match,
    target_controls_present,
    target_measurements,
    target_measurement_method,
    critique_notes,
    actor_name
  );

  SELECT
    count(*) FILTER (WHERE finding->>'severity' = 'P0' AND NOT (finding->>'resolved')::boolean),
    count(*) FILTER (WHERE finding->>'severity' = 'P1' AND NOT (finding->>'resolved')::boolean),
    count(*) FILTER (WHERE finding->>'severity' = 'P2' AND NOT (finding->>'resolved')::boolean)
  INTO material_p0, material_p1, material_p2
  FROM jsonb_array_elements(target_findings) finding;

  UPDATE api.work_item_visual_validations
  SET findings = target_findings,
      unresolved_p0 = GREATEST(unresolved_p0, material_p0),
      unresolved_p1 = GREATEST(unresolved_p1, material_p1),
      unresolved_p2 = GREATEST(unresolved_p2, material_p2),
      represents_approved_design = represents_approved_design
        AND material_p0 = 0 AND material_p1 = 0 AND material_p2 = 0
  WHERE id = validation.id
  RETURNING * INTO validation;

  passed := validation.measurement_complete
    AND validation.same_viewport
    AND validation.represents_approved_design
    AND validation.structural_match
    AND validation.unresolved_p0 = 0
    AND validation.unresolved_p1 = 0
    AND validation.unresolved_p2 = 0;

  INSERT INTO api.activity_events(
    project_id, work_item_id, event_type, actor_type, actor_name, summary, details
  ) VALUES (
    validation.project_id, validation.work_item_id, 'work_item.visual_critique_recorded',
    CASE WHEN actor_name = 'You' THEN 'human' ELSE 'agent' END,
    actor_name,
    'Recorded Product Design visual critique for ' || validation.screen_name,
    jsonb_build_object(
      'validation_id', validation.id,
      'product_design_route', 'product-design:design-qa',
      'revision', validation.revision,
      'finding_count', jsonb_array_length(target_findings),
      'passed', passed
    )
  );

  RETURN jsonb_build_object(
    'workflow', jsonb_build_object(
      'capability', 'react_html_vs_image_mockup_critique',
      'product_design_route', 'product-design:design-qa'
    ),
    'passed', passed,
    'validation', to_jsonb(validation),
    'promotion_gate', api.visual_fidelity_gate_requirements(validation.work_item_id, validation.revision)
  );
END $$;

COMMENT ON FUNCTION api.get_mockup_implementation_package(uuid) IS
  'Resolves governed, approved inputs for the Product Design image-to-code workflow.';
COMMENT ON FUNCTION api.get_visual_critique_package(uuid, text, text) IS
  'Binds a human-approved static mockup to an exact-revision rendered implementation at the same viewport.';
COMMENT ON FUNCTION api.record_visual_critique(
  uuid, text, uuid, uuid, text, integer, integer, text, boolean, boolean,
  boolean, jsonb, jsonb, text, text, text
) IS
  'Stores Product Design critique findings and measured fidelity; material failures keep the promotion gate unsatisfied.';

GRANT EXECUTE ON FUNCTION api.get_mockup_implementation_package(uuid) TO web_anon;
GRANT EXECUTE ON FUNCTION api.get_visual_critique_package(uuid, text, text) TO web_anon;
GRANT EXECUTE ON FUNCTION api.record_visual_critique(
  uuid, text, uuid, uuid, text, integer, integer, text, boolean, boolean,
  boolean, jsonb, jsonb, text, text, text
) TO web_anon;

NOTIFY pgrst, 'reload schema';
