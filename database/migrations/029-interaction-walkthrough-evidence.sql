-- Interaction recordings are walkthrough evidence, not decorative media. A
-- material interaction story must carry a continuous, real-time, exact-revision
-- recording with a timestamped action manifest and a human quality review.

ALTER TABLE api.work_items
  ADD COLUMN IF NOT EXISTS interaction_evidence_required boolean NOT NULL DEFAULT false;

ALTER TABLE api.work_item_assets
  ADD COLUMN IF NOT EXISTS recording_manifest jsonb NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS recording_review_status text NOT NULL DEFAULT 'not_required',
  ADD COLUMN IF NOT EXISTS recording_reviewed_by text,
  ADD COLUMN IF NOT EXISTS recording_reviewed_at timestamptz,
  ADD COLUMN IF NOT EXISTS recording_review_notes text;

ALTER TABLE api.work_item_assets
  DROP CONSTRAINT IF EXISTS work_item_assets_recording_manifest_check,
  DROP CONSTRAINT IF EXISTS work_item_assets_recording_review_status_check,
  ADD CONSTRAINT work_item_assets_recording_manifest_check CHECK (jsonb_typeof(recording_manifest) = 'object'),
  ADD CONSTRAINT work_item_assets_recording_review_status_check CHECK (
    recording_review_status IN ('not_required', 'pending', 'approved', 'rejected')
  );

UPDATE api.work_item_assets
SET recording_review_status = 'pending'
WHERE asset_type = 'validation_recording' AND recording_review_status = 'not_required';

-- Existing stories that already carry a validation recording were asserting an
-- interaction proof requirement implicitly. Make that requirement explicit so
-- their old recordings are re-reviewed rather than grandfathered through.
UPDATE api.work_items item
SET interaction_evidence_required = true,
    visual_evidence_required = true
WHERE item.kind = 'story'
  AND EXISTS (SELECT 1 FROM api.projects project WHERE project.id = item.project_id AND project.status <> 'archived')
  AND EXISTS (
  SELECT 1 FROM api.work_item_assets asset
  WHERE asset.work_item_id = item.id AND asset.asset_type = 'validation_recording'
);

CREATE OR REPLACE FUNCTION api.set_interaction_evidence_requirement(
  target_work_item_id uuid,
  required boolean,
  actor_name text DEFAULT 'You'
) RETURNS SETOF api.work_items
LANGUAGE plpgsql AS $$
DECLARE item api.work_items; stage api.board_stages;
BEGIN
  SELECT * INTO item FROM api.work_items WHERE id = target_work_item_id FOR UPDATE;
  IF item.id IS NULL THEN RAISE EXCEPTION 'Work item not found.'; END IF;
  IF item.kind <> 'story' THEN
    RAISE EXCEPTION 'Interaction evidence requirements can only be set on stories.' USING ERRCODE = '23514';
  END IF;
  SELECT * INTO stage FROM api.board_stages WHERE id = item.stage_id;
  IF stage.slug NOT IN ('backlog', 'analyse', 'plan') THEN
    RAISE EXCEPTION 'The interaction evidence requirement cannot change after Build begins.' USING ERRCODE = '23514';
  END IF;
  UPDATE api.work_items
  SET interaction_evidence_required = required,
      visual_evidence_required = CASE WHEN required THEN true ELSE visual_evidence_required END
  WHERE id = item.id RETURNING * INTO item;
  INSERT INTO api.activity_events(project_id, work_item_id, event_type, actor_type, actor_name, summary, details)
  VALUES (
    item.project_id, item.id, 'work_item.interaction_requirement_changed',
    CASE WHEN actor_name = 'You' THEN 'human' ELSE 'agent' END, actor_name,
    CASE WHEN required THEN 'Interaction walkthrough evidence is required for ' ELSE 'Interaction walkthrough evidence is no longer required for ' END || item.item_key,
    jsonb_build_object('interaction_evidence_required', required)
  );
  RETURN NEXT item;
END $$;

CREATE OR REPLACE FUNCTION api.validate_recording_manifest(manifest jsonb) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  duration numeric;
  previous_time numeric := -1;
  step jsonb;
  step_time numeric;
BEGIN
  IF jsonb_typeof(manifest) <> 'object' THEN RETURN false; END IF;
  IF COALESCE((manifest->>'continuous_capture')::boolean, false) IS NOT TRUE THEN RETURN false; END IF;
  IF COALESCE((manifest->>'pointer_visible')::boolean, false) IS NOT TRUE THEN RETURN false; END IF;
  IF COALESCE((manifest->>'playback_speed')::numeric, 0) <> 1 THEN RETURN false; END IF;
  duration := COALESCE((manifest->>'duration_seconds')::numeric, 0);
  IF duration < 8 OR duration > 600 THEN RETURN false; END IF;
  IF jsonb_typeof(manifest->'steps') <> 'array' OR jsonb_array_length(manifest->'steps') < 2 THEN RETURN false; END IF;
  FOR step IN SELECT value FROM jsonb_array_elements(manifest->'steps') LOOP
    IF jsonb_typeof(step) <> 'object'
      OR btrim(COALESCE(step->>'action', '')) = ''
      OR btrim(COALESCE(step->>'expected_result', '')) = '' THEN RETURN false; END IF;
    step_time := COALESCE((step->>'at_seconds')::numeric, -1);
    IF step_time < 0 OR step_time > duration OR (previous_time >= 0 AND step_time - previous_time < 1) THEN RETURN false; END IF;
    previous_time := step_time;
  END LOOP;
  RETURN true;
EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
  RETURN false;
END $$;

CREATE OR REPLACE FUNCTION api.enforce_validation_recording_contract() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.asset_type = 'validation_recording' THEN
    IF NOT api.validate_recording_manifest(NEW.recording_manifest) THEN
      RAISE EXCEPTION 'Validation recording requires an 8-600 second continuous real-time walkthrough, visible pointer/touch indicator, and at least two timestamped actions with expected outcomes.' USING ERRCODE = '23514';
    END IF;
    NEW.recording_review_status := 'pending';
    NEW.is_primary := false;
  ELSE
    NEW.recording_manifest := '{}'::jsonb;
    NEW.recording_review_status := 'not_required';
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS work_item_assets_recording_contract ON api.work_item_assets;
CREATE TRIGGER work_item_assets_recording_contract
BEFORE INSERT OR UPDATE OF asset_type, recording_manifest ON api.work_item_assets
FOR EACH ROW EXECUTE FUNCTION api.enforce_validation_recording_contract();

CREATE OR REPLACE FUNCTION api.attach_validation_recording(
  target_work_item_id uuid,
  asset_source_url text,
  actor_name text,
  target_revision text,
  target_evidence_id uuid,
  recording_caption text,
  recording_mime_type text,
  recording_filename text,
  recording_viewport_width integer,
  recording_viewport_height integer,
  walkthrough_manifest jsonb
) RETURNS SETOF api.work_item_assets
LANGUAGE plpgsql AS $$
DECLARE item api.work_items; evidence api.work_item_evidence; asset api.work_item_assets;
BEGIN
  SELECT * INTO item FROM api.work_items WHERE id = target_work_item_id;
  IF item.id IS NULL OR item.kind <> 'story' THEN RAISE EXCEPTION 'Story not found.'; END IF;
  IF btrim(COALESCE(target_revision, '')) = '' THEN
    RAISE EXCEPTION 'Validation recording requires an exact revision.' USING ERRCODE = '23514';
  END IF;
  IF recording_mime_type !~ '^video/' THEN
    RAISE EXCEPTION 'Validation recording requires a video MIME type.' USING ERRCODE = '23514';
  END IF;
  SELECT * INTO evidence FROM api.work_item_evidence
  WHERE id = target_evidence_id AND work_item_id = item.id;
  IF evidence.id IS NULL OR evidence.evidence_type <> 'test' OR evidence.outcome <> 'passed'
    OR evidence.revision IS DISTINCT FROM target_revision THEN
    RAISE EXCEPTION 'Validation recording must be linked to passing test evidence for the same exact revision.' USING ERRCODE = '23514';
  END IF;
  IF NOT api.validate_recording_manifest(walkthrough_manifest) THEN
    RAISE EXCEPTION 'Recording walkthrough manifest is incomplete or too rapidly paced.' USING ERRCODE = '23514';
  END IF;
  INSERT INTO api.work_item_assets(
    project_id, work_item_id, evidence_id, asset_type, source_url, mime_type,
    filename, caption, viewport_width, viewport_height, revision, is_primary,
    created_by, recording_manifest, recording_review_status
  ) VALUES (
    item.project_id, item.id, evidence.id, 'validation_recording', asset_source_url,
    recording_mime_type, recording_filename, COALESCE(recording_caption, ''),
    recording_viewport_width, recording_viewport_height, target_revision, false,
    actor_name, walkthrough_manifest, 'pending'
  ) RETURNING * INTO asset;
  INSERT INTO api.activity_events(project_id, work_item_id, event_type, actor_type, actor_name, summary, details)
  VALUES (
    item.project_id, item.id, 'work_item.validation_recording_attached',
    CASE WHEN actor_name = 'You' THEN 'human' ELSE 'agent' END, actor_name,
    'Attached interaction walkthrough to ' || item.item_key,
    jsonb_build_object('asset_id', asset.id, 'revision', asset.revision, 'evidence_id', asset.evidence_id,
      'duration_seconds', walkthrough_manifest->'duration_seconds', 'step_count', jsonb_array_length(walkthrough_manifest->'steps'))
  );
  RETURN NEXT asset;
END $$;

CREATE OR REPLACE FUNCTION api.review_validation_recording(
  target_asset_id uuid,
  approved boolean,
  human_name text,
  review_notes text DEFAULT ''
) RETURNS SETOF api.work_item_assets
LANGUAGE plpgsql AS $$
DECLARE asset api.work_item_assets; item api.work_items;
BEGIN
  IF btrim(COALESCE(human_name, '')) = '' THEN RAISE EXCEPTION 'Human reviewer name is required.'; END IF;
  SELECT * INTO asset FROM api.work_item_assets WHERE id = target_asset_id FOR UPDATE;
  IF asset.id IS NULL OR asset.asset_type <> 'validation_recording' THEN
    RAISE EXCEPTION 'Validation recording not found.' USING ERRCODE = '23514';
  END IF;
  SELECT * INTO item FROM api.work_items WHERE id = asset.work_item_id;
  UPDATE api.work_item_assets SET
    recording_review_status = CASE WHEN approved THEN 'approved' ELSE 'rejected' END,
    recording_reviewed_by = human_name,
    recording_reviewed_at = now(),
    recording_review_notes = COALESCE(review_notes, '')
  WHERE id = asset.id RETURNING * INTO asset;
  INSERT INTO api.activity_events(project_id, work_item_id, event_type, actor_type, actor_name, summary, details)
  VALUES (
    asset.project_id, asset.work_item_id, 'work_item.validation_recording_reviewed', 'human', human_name,
    CASE WHEN approved THEN 'Approved interaction walkthrough for ' ELSE 'Rejected interaction walkthrough for ' END || item.item_key,
    jsonb_build_object('asset_id', asset.id, 'approved', approved, 'notes', COALESCE(review_notes, ''))
  );
  RETURN NEXT asset;
END $$;

CREATE OR REPLACE FUNCTION api.interaction_recording_gate_requirements(
  target_work_item_id uuid,
  target_revision text
) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE item api.work_items; recording api.work_item_assets; satisfied boolean;
BEGIN
  SELECT * INTO item FROM api.work_items WHERE id = target_work_item_id;
  IF item.id IS NULL OR item.kind <> 'story' OR NOT item.interaction_evidence_required THEN RETURN '[]'::jsonb; END IF;
  SELECT * INTO recording FROM api.work_item_assets asset
  WHERE asset.work_item_id = item.id AND asset.asset_type = 'validation_recording'
    AND asset.revision = target_revision
  ORDER BY asset.created_at DESC LIMIT 1;
  satisfied := recording.id IS NOT NULL
    AND api.validate_recording_manifest(recording.recording_manifest)
    AND recording.recording_review_status = 'approved';
  RETURN jsonb_build_array(jsonb_build_object(
    'requirement', 'A human-approved, continuous real-time interaction walkthrough demonstrates the accepted revision with a visible pointer/touch indicator and deliberate timestamped actions',
    'revision', target_revision,
    'asset_id', recording.id,
    'duration_seconds', recording.recording_manifest->'duration_seconds',
    'step_count', CASE WHEN jsonb_typeof(recording.recording_manifest->'steps') = 'array' THEN jsonb_array_length(recording.recording_manifest->'steps') ELSE 0 END,
    'review_status', COALESCE(recording.recording_review_status, 'missing'),
    'reviewed_by', recording.recording_reviewed_by,
    'satisfied', satisfied,
    'blocking', true
  ));
END $$;

CREATE OR REPLACE FUNCTION api.enforce_interaction_recording_stage_transition() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE previous_stage api.board_stages; next_stage api.board_stages; accepted_revision text; requirements jsonb;
BEGIN
  IF NEW.stage_id = OLD.stage_id OR OLD.kind <> 'story' OR NOT OLD.interaction_evidence_required THEN RETURN NEW; END IF;
  SELECT * INTO previous_stage FROM api.board_stages WHERE id = OLD.stage_id;
  SELECT * INTO next_stage FROM api.board_stages WHERE id = NEW.stage_id;
  IF previous_stage.slug = 'validate' AND next_stage.slug = 'review' THEN
    SELECT criterion->>'revision' INTO accepted_revision
    FROM jsonb_array_elements(OLD.acceptance_criteria) criterion
    WHERE criterion->>'status' = 'passed' AND btrim(COALESCE(criterion->>'revision', '')) <> '' LIMIT 1;
    requirements := api.interaction_recording_gate_requirements(OLD.id, accepted_revision);
    IF jsonb_array_length(requirements) = 0 OR EXISTS (
      SELECT 1 FROM jsonb_array_elements(requirements) requirement
      WHERE NOT COALESCE((requirement->>'satisfied')::boolean, false)
    ) THEN
      RAISE EXCEPTION 'Interactive story cannot enter Review until its exact accepted revision has a human-approved continuous real-time walkthrough with visible pointer/touch indication and deliberate timestamped actions.' USING ERRCODE = '23514';
    END IF;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS work_items_interaction_recording_gate ON api.work_items;
CREATE TRIGGER work_items_interaction_recording_gate
BEFORE UPDATE OF stage_id ON api.work_items
FOR EACH ROW EXECUTE FUNCTION api.enforce_interaction_recording_stage_transition();

CREATE OR REPLACE FUNCTION api.get_governed_work_item_context(target_work_item_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  item api.work_items;
  context jsonb;
  requirements jsonb;
  design_requirements jsonb;
  fidelity_requirements jsonb;
  interaction_requirements jsonb;
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
  INTO validations FROM api.work_item_visual_validations validation WHERE validation.work_item_id = item.id;
  context := context || jsonb_build_object(
    'interaction_evidence_required', item.interaction_evidence_required,
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
    WHERE criterion->>'status' = 'passed' AND btrim(COALESCE(criterion->>'revision', '')) <> '' LIMIT 1;
    requirements := COALESCE(context #> '{promotion,acceptance_criteria}', '[]'::jsonb);
    fidelity_requirements := api.visual_fidelity_gate_requirements(item.id, accepted_revision);
    interaction_requirements := api.interaction_recording_gate_requirements(item.id, accepted_revision);
    requirements := requirements || fidelity_requirements || interaction_requirements;
    context := jsonb_set(context, '{promotion,acceptance_criteria}', requirements, true);
    context := jsonb_set(context, '{promotion,ready}', to_jsonb(NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(requirements) requirement
      WHERE COALESCE((requirement->>'blocking')::boolean, true)
        AND NOT COALESCE((requirement->>'satisfied')::boolean, false)
    )), true);
  END IF;
  RETURN context;
END $$;

GRANT EXECUTE ON FUNCTION api.set_interaction_evidence_requirement(uuid, boolean, text) TO web_anon;
GRANT EXECUTE ON FUNCTION api.attach_validation_recording(uuid, text, text, text, uuid, text, text, text, integer, integer, jsonb) TO web_anon;
GRANT EXECUTE ON FUNCTION api.review_validation_recording(uuid, boolean, text, text) TO web_anon;
GRANT EXECUTE ON FUNCTION api.interaction_recording_gate_requirements(uuid, text) TO web_anon;
GRANT EXECUTE ON FUNCTION api.get_governed_work_item_context(uuid) TO web_anon;

NOTIFY pgrst, 'reload schema';
