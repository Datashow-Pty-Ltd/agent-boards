-- Promotion from Review & Merge to Done requires proof that the reviewed code
-- merged and that automated regression passed on the resulting merged revision.

ALTER TABLE api.work_item_evidence
  DROP CONSTRAINT IF EXISTS work_item_evidence_evidence_type_check;
ALTER TABLE api.work_item_evidence
  ADD CONSTRAINT work_item_evidence_evidence_type_check CHECK (evidence_type IN (
    -- Keep the final-schema evidence types valid when migrations are replayed
    -- against an existing volume. Migration 012 adds unit_test evidence.
    'analysis', 'plan', 'implementation', 'test', 'unit_test', 'review', 'merge', 'regression'
  ));

CREATE OR REPLACE FUNCTION api.record_work_item_evidence(
  target_work_item_id uuid,
  target_evidence_type text,
  target_outcome text,
  evidence_summary text,
  actor_name text,
  target_revision text DEFAULT NULL,
  evidence_url text DEFAULT NULL,
  evidence_details jsonb DEFAULT '{}'::jsonb
) RETURNS SETOF api.work_item_evidence
LANGUAGE plpgsql AS $$
DECLARE item api.work_items; evidence api.work_item_evidence;
BEGIN
  SELECT * INTO item FROM api.work_items WHERE id = target_work_item_id;
  IF item.id IS NULL THEN RAISE EXCEPTION 'Work item not found.'; END IF;
  IF target_evidence_type NOT IN ('analysis', 'plan', 'implementation', 'test', 'review', 'merge', 'regression') THEN
    RAISE EXCEPTION 'Unsupported evidence type: %', target_evidence_type USING ERRCODE = '23514';
  END IF;
  IF target_outcome NOT IN ('recorded', 'passed', 'failed', 'approved', 'rejected', 'merged') THEN
    RAISE EXCEPTION 'Unsupported evidence outcome: %', target_outcome USING ERRCODE = '23514';
  END IF;
  IF btrim(COALESCE(evidence_summary, '')) = '' THEN
    RAISE EXCEPTION 'Evidence requires a summary.' USING ERRCODE = '23514';
  END IF;
  IF target_evidence_type IN ('implementation', 'test', 'review', 'merge', 'regression')
     AND btrim(COALESCE(target_revision, '')) = '' THEN
    RAISE EXCEPTION '% evidence requires the exact revision.', target_evidence_type USING ERRCODE = '23514';
  END IF;
  IF target_evidence_type = 'merge'
     AND btrim(COALESCE(evidence_details->>'reviewed_revision', '')) = '' THEN
    RAISE EXCEPTION 'Merge evidence requires details.reviewed_revision.' USING ERRCODE = '23514';
  END IF;

  INSERT INTO api.work_item_evidence(
    project_id, work_item_id, evidence_type, outcome, revision, summary, url, details, actor_name
  ) VALUES (
    item.project_id, item.id, target_evidence_type, target_outcome, target_revision,
    evidence_summary, evidence_url, COALESCE(evidence_details, '{}'::jsonb), actor_name
  ) RETURNING * INTO evidence;
  INSERT INTO api.activity_events(
    project_id, work_item_id, event_type, actor_type, actor_name, summary, details
  ) VALUES (
    item.project_id, item.id, 'work_item.evidence_recorded', 'agent', actor_name,
    'Recorded ' || target_evidence_type || ' evidence for ' || item.item_key,
    jsonb_build_object('evidence_id', evidence.id, 'evidence_type', evidence.evidence_type,
      'outcome', evidence.outcome, 'revision', evidence.revision)
  );
  RETURN NEXT evidence;
END $$;

CREATE OR REPLACE FUNCTION api.enforce_work_item_stage_transition() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE previous_stage api.board_stages; next_stage api.board_stages; tested_revision text;
BEGIN
  IF NEW.stage_id = OLD.stage_id THEN RETURN NEW; END IF;
  SELECT * INTO previous_stage FROM api.board_stages WHERE id = OLD.stage_id;
  SELECT * INTO next_stage FROM api.board_stages WHERE id = NEW.stage_id;
  IF next_stage.id IS NULL OR next_stage.board_id <> OLD.board_id THEN
    RAISE EXCEPTION 'Target stage does not belong to this board.' USING ERRCODE = '23514';
  END IF;
  IF NOT (previous_stage.allowed_transitions ? next_stage.slug) THEN
    RAISE EXCEPTION 'Cannot move from % to %. Allowed next stages: %', previous_stage.title, next_stage.title,
      COALESCE((SELECT string_agg(value, ', ') FROM jsonb_array_elements_text(previous_stage.allowed_transitions)), 'none')
      USING ERRCODE = '23514';
  END IF;
  IF OLD.kind = 'story' AND next_stage.slug = 'plan' AND NOT EXISTS (
    SELECT 1 FROM api.work_item_evidence e WHERE e.work_item_id = OLD.id
      AND e.evidence_type = 'analysis' AND e.outcome IN ('recorded', 'passed', 'approved')
  ) THEN RAISE EXCEPTION 'Story cannot enter Plan without recorded analysis evidence.' USING ERRCODE = '23514'; END IF;
  IF OLD.kind = 'story' AND next_stage.slug = 'build' AND previous_stage.slug = 'plan' AND NOT EXISTS (
    SELECT 1 FROM api.work_item_evidence e WHERE e.work_item_id = OLD.id
      AND e.evidence_type = 'plan' AND e.outcome IN ('recorded', 'approved')
  ) THEN RAISE EXCEPTION 'Story cannot enter Build without a recorded implementation plan.' USING ERRCODE = '23514'; END IF;
  IF OLD.kind = 'story' AND next_stage.slug = 'validate' AND NOT EXISTS (
    SELECT 1 FROM api.work_item_evidence e WHERE e.work_item_id = OLD.id
      AND e.evidence_type = 'implementation' AND e.outcome IN ('recorded', 'passed') AND e.revision IS NOT NULL
  ) THEN RAISE EXCEPTION 'Story cannot enter Validate without implementation evidence for an exact revision.' USING ERRCODE = '23514'; END IF;
  IF OLD.kind = 'story' AND next_stage.slug = 'review' AND NOT api.acceptance_criteria_passed_for_one_revision(OLD.acceptance_criteria) THEN
    RAISE EXCEPTION 'Story cannot enter Review until every acceptance criterion passes for the same revision.' USING ERRCODE = '23514';
  END IF;
  IF next_stage.slug = 'done' AND OLD.kind = 'story' AND EXISTS (
    SELECT 1 FROM api.work_items child WHERE child.parent_id = OLD.id AND child.kind = 'task'
      AND child.completed_at IS NULL AND child.progress <> 'completed'
  ) THEN RAISE EXCEPTION 'Story cannot move to Done while it has incomplete tasks.' USING ERRCODE = '23514'; END IF;

  IF OLD.kind = 'story' AND next_stage.slug = 'done' THEN
    SELECT criterion->>'revision' INTO tested_revision
    FROM jsonb_array_elements(OLD.acceptance_criteria) criterion LIMIT 1;
    IF tested_revision IS NULL OR NOT EXISTS (
      SELECT 1
      FROM api.work_item_evidence reviewed
      JOIN api.work_item_evidence merged
        ON merged.work_item_id = reviewed.work_item_id
        AND merged.evidence_type = 'merge' AND merged.outcome = 'merged'
        AND (
          merged.details->>'reviewed_revision' = reviewed.revision
          OR (merged.details->>'reviewed_revision' IS NULL AND merged.revision = reviewed.revision)
        )
      JOIN api.work_item_evidence regression
        ON regression.work_item_id = merged.work_item_id
        AND regression.evidence_type = 'regression' AND regression.outcome = 'passed'
        AND regression.revision = merged.revision
      WHERE reviewed.work_item_id = OLD.id
        AND reviewed.evidence_type = 'review' AND reviewed.outcome = 'approved'
        AND reviewed.revision = tested_revision
    ) THEN
      RAISE EXCEPTION 'Story cannot enter Done until reviewed code is merged and regression passes on the merged revision.'
        USING ERRCODE = '23514';
    END IF;
  END IF;
  RETURN NEW;
END $$;

GRANT EXECUTE ON FUNCTION api.record_work_item_evidence(uuid, text, text, text, text, text, text, jsonb) TO web_anon;
NOTIFY pgrst, 'reload schema';
