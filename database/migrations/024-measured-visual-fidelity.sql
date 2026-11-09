-- Visual fidelity is a measurement contract, not a subjective screenshot verdict.
-- Store reproducible reference-versus-build measurements and derive failures
-- from their declared tolerances instead of accepting manually entered counts.

ALTER TABLE api.work_item_visual_validations
  ADD COLUMN IF NOT EXISTS controls_present boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS measurements jsonb NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS measurement_complete boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS measurement_method text NOT NULL DEFAULT '';

ALTER TABLE api.work_item_visual_validations
  DROP CONSTRAINT IF EXISTS work_item_visual_validations_measurements_array;
ALTER TABLE api.work_item_visual_validations
  ADD CONSTRAINT work_item_visual_validations_measurements_array
  CHECK (jsonb_typeof(measurements) = 'array');

DROP FUNCTION IF EXISTS api.record_visual_design_validation(
  uuid, text, uuid, uuid, text, integer, integer, text, boolean, boolean,
  boolean, integer, integer, integer, text, text
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
  target_controls_present boolean,
  target_measurements jsonb,
  target_measurement_method text,
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
  normalized_method text := btrim(COALESCE(target_measurement_method, ''));
  normalized_measurements jsonb;
  coverage_complete boolean;
  derived_p0 integer;
  derived_p1 integer;
  derived_p2 integer;
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
  IF normalized_method = '' THEN
    RAISE EXCEPTION 'Visual validation must identify the measurement tools and sampling method.' USING ERRCODE = '23514';
  END IF;
  IF jsonb_typeof(COALESCE(target_measurements, 'null'::jsonb)) <> 'array'
    OR jsonb_array_length(target_measurements) = 0 THEN
    RAISE EXCEPTION 'Visual validation requires a non-empty measurement manifest.' USING ERRCODE = '23514';
  END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(target_measurements) measurement
    WHERE jsonb_typeof(measurement) <> 'object'
      OR measurement->>'surface' NOT IN ('typography', 'geometry', 'spacing', 'color')
      OR btrim(COALESCE(measurement->>'element', '')) = ''
      OR btrim(COALESCE(measurement->>'property', '')) = ''
      OR NOT (measurement ? 'referenceValue')
      OR NOT (measurement ? 'implementationValue')
      OR btrim(COALESCE(measurement->>'unit', '')) = ''
      OR jsonb_typeof(measurement->'tolerance') <> 'number'
      OR jsonb_typeof(measurement->'delta') <> 'number'
      OR (measurement->>'tolerance')::numeric < 0
      OR (measurement->>'delta')::numeric < 0
      OR measurement->>'severity' NOT IN ('P0', 'P1', 'P2', 'P3')
      OR btrim(COALESCE(measurement->>'method', '')) = ''
  ) THEN
    RAISE EXCEPTION 'Every measurement requires surface, element, property, referenceValue, implementationValue, unit, non-negative tolerance and delta, P0-P3 severity, and method.' USING ERRCODE = '23514';
  END IF;

  SELECT jsonb_agg(
    measurement || jsonb_build_object(
      'withinTolerance', (measurement->>'delta')::numeric <= (measurement->>'tolerance')::numeric
    ) ORDER BY ordinal
  ) INTO normalized_measurements
  FROM jsonb_array_elements(target_measurements) WITH ORDINALITY entry(measurement, ordinal);

  SELECT
    count(*) FILTER (WHERE entry->>'severity' = 'P0' AND NOT (entry->>'withinTolerance')::boolean),
    count(*) FILTER (WHERE entry->>'severity' = 'P1' AND NOT (entry->>'withinTolerance')::boolean),
    count(*) FILTER (WHERE entry->>'severity' = 'P2' AND NOT (entry->>'withinTolerance')::boolean)
  INTO derived_p0, derived_p1, derived_p2
  FROM jsonb_array_elements(normalized_measurements) entry;

  coverage_complete :=
    -- Typography values that control font metrics must be explicit.
    NOT EXISTS (
      SELECT required.property FROM (VALUES
        ('font-family'), ('font-size'), ('font-weight'), ('line-height'), ('letter-spacing')
      ) required(property)
      WHERE NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(normalized_measurements) entry
        WHERE entry->>'surface' = 'typography' AND entry->>'property' = required.property
      )
    )
    -- Major element position, size and shape must be measured.
    AND NOT EXISTS (
      SELECT required.property FROM (VALUES
        ('x'), ('y'), ('width'), ('height'), ('border-radius')
      ) required(property)
      WHERE NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(normalized_measurements) entry
        WHERE entry->>'surface' = 'geometry' AND entry->>'property' = required.property
      )
    )
    -- Layout rhythm must include outer inset, section rhythm and component rhythm.
    AND NOT EXISTS (
      SELECT required.property FROM (VALUES
        ('page-inset'), ('section-gap'), ('component-gap')
      ) required(property)
      WHERE NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(normalized_measurements) entry
        WHERE entry->>'surface' = 'spacing' AND entry->>'property' = required.property
      )
    )
    -- Sample the principal foreground, surface and outline tokens.
    AND NOT EXISTS (
      SELECT required.property FROM (VALUES
        ('color'), ('background-color'), ('border-color')
      ) required(property)
      WHERE NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(normalized_measurements) entry
        WHERE entry->>'surface' = 'color' AND entry->>'property' = required.property
      )
    )
    -- Screens with controls must measure each control's position, size and radius.
    AND (
      NOT COALESCE(target_controls_present, false)
      OR NOT EXISTS (
        SELECT required.property FROM (VALUES
          ('x'), ('y'), ('width'), ('height'), ('border-radius')
        ) required(property)
        WHERE NOT EXISTS (
          SELECT 1 FROM jsonb_array_elements(normalized_measurements) entry
          WHERE entry->>'surface' = 'geometry'
            AND entry->>'property' = required.property
            AND lower(entry->>'element') ~ '(button|control|action|cta)'
        )
      )
    );

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
    controls_present, measurements, measurement_complete, measurement_method,
    notes, actor_name
  ) VALUES (
    item.project_id, item.id, normalized_screen, source_asset.id,
    validation_asset.id, normalized_revision, target_viewport_width, target_viewport_height,
    target_comparison_method, COALESCE(target_same_viewport, false),
    COALESCE(target_represents_approved_design, false) AND coverage_complete
      AND derived_p0 = 0 AND derived_p1 = 0 AND derived_p2 = 0,
    COALESCE(target_structural_match, false), derived_p0, derived_p1, derived_p2,
    COALESCE(target_controls_present, false), normalized_measurements,
    coverage_complete, normalized_method, COALESCE(validation_notes, ''), actor_name
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
    controls_present = EXCLUDED.controls_present,
    measurements = EXCLUDED.measurements,
    measurement_complete = EXCLUDED.measurement_complete,
    measurement_method = EXCLUDED.measurement_method,
    notes = EXCLUDED.notes,
    actor_name = EXCLUDED.actor_name,
    created_at = now()
  RETURNING * INTO validation;

  INSERT INTO api.activity_events(
    project_id, work_item_id, event_type, actor_type, actor_name, summary, details
  ) VALUES (
    item.project_id, item.id, 'work_item.visual_fidelity_measured',
    CASE WHEN actor_name = 'You' THEN 'human' ELSE 'agent' END,
    actor_name,
    'Recorded measured visual fidelity validation for ' || normalized_screen,
    jsonb_build_object(
      'validation_id', validation.id,
      'screen_name', normalized_screen,
      'revision', normalized_revision,
      'viewport', jsonb_build_object('width', target_viewport_width, 'height', target_viewport_height),
      'comparison_method', target_comparison_method,
      'measurement_method', normalized_method,
      'measurement_count', jsonb_array_length(normalized_measurements),
      'measurement_complete', coverage_complete,
      'controls_present', validation.controls_present,
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
      AND validation.measurement_complete
      AND jsonb_array_length(validation.measurements) > 0
      AND validation.same_viewport
      AND validation.represents_approved_design
      AND validation.structural_match
      AND validation.unresolved_p0 = 0
      AND validation.unresolved_p1 = 0
      AND validation.unresolved_p2 = 0;

    requirements := requirements || jsonb_build_array(jsonb_build_object(
      'requirement', 'The rendered ' || screen || ' screen has complete measured fidelity against its approved design with every P0/P1/P2 value inside tolerance',
      'screen_name', screen,
      'revision', target_revision,
      'validation_id', validation.id,
      'source_mockup_asset_id', validation.source_mockup_asset_id,
      'validation_asset_id', validation.validation_asset_id,
      'viewport_width', validation.viewport_width,
      'viewport_height', validation.viewport_height,
      'comparison_method', validation.comparison_method,
      'measurement_method', validation.measurement_method,
      'measurement_count', COALESCE(jsonb_array_length(validation.measurements), 0),
      'measurement_complete', COALESCE(validation.measurement_complete, false),
      'controls_present', COALESCE(validation.controls_present, false),
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

COMMENT ON COLUMN api.work_item_visual_validations.measurements IS
  'Server-normalized reference-versus-implementation measurements with derived withinTolerance status.';
COMMENT ON COLUMN api.work_item_visual_validations.measurement_complete IS
  'True only when required typography, geometry, spacing, colour and visible-control coverage is present.';
COMMENT ON FUNCTION api.record_visual_design_validation(
  uuid, text, uuid, uuid, text, integer, integer, text, boolean, boolean,
  boolean, boolean, jsonb, text, text, text
) IS
  'Records measured visual fidelity and derives material failures from declared tolerances.';

GRANT EXECUTE ON FUNCTION api.record_visual_design_validation(
  uuid, text, uuid, uuid, text, integer, integer, text, boolean, boolean,
  boolean, boolean, jsonb, text, text, text
) TO web_anon;
GRANT EXECUTE ON FUNCTION api.visual_fidelity_gate_requirements(uuid, text) TO web_anon;

NOTIFY pgrst, 'reload schema';
