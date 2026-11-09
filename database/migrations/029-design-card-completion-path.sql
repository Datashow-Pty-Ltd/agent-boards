-- Design-only cards produce an approved contract consumed by implementation
-- stories. They do not fabricate source, test, review, merge, or regression
-- evidence. Once their governed human approvals are complete they may close
-- directly from Plan with a durable design-contract revision.

CREATE OR REPLACE FUNCTION api.design_card_completion_requirements(target_work_item_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  item api.work_items;
  stage api.board_stages;
  requirements jsonb := '[]'::jsonb;
  design_requirements jsonb;
BEGIN
  SELECT * INTO item FROM api.work_items WHERE id = target_work_item_id;
  IF item.id IS NULL OR item.kind <> 'story' OR item.design_card_type IS NULL THEN RETURN requirements; END IF;
  SELECT * INTO stage FROM api.board_stages WHERE id = item.stage_id;
  requirements := requirements || jsonb_build_array(
    jsonb_build_object('requirement', 'The design-only card is in Plan', 'satisfied', stage.slug = 'plan', 'blocking', true),
    jsonb_build_object('requirement', 'Design analysis is recorded', 'satisfied', EXISTS (
      SELECT 1 FROM api.work_item_evidence evidence WHERE evidence.work_item_id = item.id
        AND evidence.evidence_type = 'analysis' AND evidence.outcome IN ('recorded','passed','approved')
    ), 'blocking', true),
    jsonb_build_object('requirement', 'The design approach is recorded', 'satisfied', EXISTS (
      SELECT 1 FROM api.work_item_evidence evidence WHERE evidence.work_item_id = item.id
        AND evidence.evidence_type = 'plan' AND evidence.outcome IN ('recorded','approved')
    ), 'blocking', true),
    jsonb_build_object('requirement', 'Every task on the design card is complete', 'satisfied', NOT EXISTS (
      SELECT 1 FROM api.work_items child WHERE child.parent_id = item.id AND child.kind = 'task'
        AND child.completed_at IS NULL AND child.progress <> 'completed'
    ), 'blocking', true)
  );
  design_requirements := api.visual_design_gate_requirements(item.id);
  RETURN requirements || design_requirements;
END $$;

CREATE OR REPLACE FUNCTION api.design_card_can_complete(target_work_item_id uuid)
RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT jsonb_array_length(requirements) > 0 AND NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(requirements) requirement
    WHERE COALESCE((requirement->>'blocking')::boolean, true)
      AND NOT COALESCE((requirement->>'satisfied')::boolean, false)
  )
  FROM (SELECT api.design_card_completion_requirements(target_work_item_id) requirements) value;
$$;

CREATE OR REPLACE FUNCTION api.enforce_work_item_stage_transition() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  previous_stage api.board_stages;
  next_stage api.board_stages;
  tested_revision text;
  merged_revision text;
  review_approved boolean;
  regression_policy text;
  post_merge_verified boolean;
BEGIN
  IF NEW.stage_id = OLD.stage_id THEN RETURN NEW; END IF;
  SELECT * INTO previous_stage FROM api.board_stages WHERE id = OLD.stage_id;
  SELECT * INTO next_stage FROM api.board_stages WHERE id = NEW.stage_id;
  IF next_stage.id IS NULL OR next_stage.board_id <> OLD.board_id THEN
    RAISE EXCEPTION 'Target stage does not belong to this board.' USING ERRCODE = '23514';
  END IF;

  IF OLD.kind = 'feature' AND next_stage.slug = 'done'
     AND EXISTS (SELECT 1 FROM api.work_items child WHERE child.parent_id = OLD.id AND child.kind = 'story')
     AND NOT EXISTS (
       SELECT 1 FROM api.work_items child WHERE child.parent_id = OLD.id AND child.kind = 'story'
         AND child.completed_at IS NULL AND child.progress <> 'completed'
     ) THEN RETURN NEW; END IF;

  -- This is the sole non-software completion path. It is deliberately narrow:
  -- a design card, in Plan, with every governed approval and task satisfied.
  IF OLD.kind = 'story' AND OLD.design_card_type IS NOT NULL
    AND previous_stage.slug = 'plan' AND next_stage.slug = 'done'
    AND api.design_card_can_complete(OLD.id) THEN RETURN NEW; END IF;

  IF NOT (previous_stage.allowed_transitions ? next_stage.slug) THEN
    RAISE EXCEPTION 'Cannot move from % to %. Allowed next stages: %', previous_stage.title, next_stage.title,
      COALESCE((SELECT string_agg(value, ', ') FROM jsonb_array_elements_text(previous_stage.allowed_transitions)), 'none')
      USING ERRCODE = '23514', HINT = 'Move software through each governed stage; use complete_design_card for approved design-only work.';
  END IF;
  IF OLD.kind = 'story' AND next_stage.slug = 'plan' AND NOT EXISTS (
    SELECT 1 FROM api.work_item_evidence evidence WHERE evidence.work_item_id = OLD.id
      AND evidence.evidence_type = 'analysis' AND evidence.outcome IN ('recorded','passed','approved')
  ) THEN RAISE EXCEPTION 'Story cannot enter Plan without recorded analysis evidence.' USING ERRCODE = '23514'; END IF;
  IF OLD.kind = 'story' AND next_stage.slug = 'build' AND NOT EXISTS (
    SELECT 1 FROM api.work_item_evidence evidence WHERE evidence.work_item_id = OLD.id
      AND evidence.evidence_type = 'plan' AND evidence.outcome IN ('recorded','approved')
  ) THEN RAISE EXCEPTION 'Story cannot enter Build without a recorded implementation plan.' USING ERRCODE = '23514'; END IF;
  IF OLD.kind = 'story' AND next_stage.slug = 'validate' AND NOT EXISTS (
    SELECT 1 FROM api.work_item_evidence evidence WHERE evidence.work_item_id = OLD.id
      AND evidence.evidence_type = 'implementation' AND evidence.outcome IN ('recorded','passed') AND evidence.revision IS NOT NULL
  ) THEN RAISE EXCEPTION 'Story cannot enter Validate without implementation evidence for an exact revision.' USING ERRCODE = '23514'; END IF;
  IF OLD.kind = 'story' AND next_stage.slug IN ('review','merge','post_merge','done') THEN
    IF NOT api.acceptance_criteria_passed_for_one_revision(OLD.acceptance_criteria) THEN
      RAISE EXCEPTION 'Every acceptance criterion must pass for the same revision before Review.' USING ERRCODE = '23514';
    END IF;
    SELECT criterion->>'revision' INTO tested_revision FROM jsonb_array_elements(OLD.acceptance_criteria) criterion LIMIT 1;
  END IF;
  IF OLD.kind = 'story' AND next_stage.slug = 'merge' THEN
    IF EXISTS (SELECT 1 FROM api.work_items child WHERE child.parent_id = OLD.id AND child.kind = 'task'
      AND child.completed_at IS NULL AND child.progress <> 'completed') THEN
      RAISE EXCEPTION 'Story cannot enter Merge while it has incomplete tasks.' USING ERRCODE = '23514';
    END IF;
    review_approved := EXISTS (
      SELECT 1 FROM api.work_item_evidence evidence WHERE evidence.work_item_id = OLD.id
        AND evidence.evidence_type = 'review' AND evidence.outcome = 'approved'
        AND evidence.revision = tested_revision AND evidence.details->>'unresolved_findings' = '0'
    );
    IF NOT review_approved THEN RAISE EXCEPTION 'Story cannot enter Merge until the validated revision is approved in review.' USING ERRCODE = '23514'; END IF;
  END IF;
  IF OLD.kind = 'story' AND next_stage.slug IN ('post_merge','done') THEN
    SELECT merged.revision INTO merged_revision FROM api.work_item_evidence merged
    WHERE merged.work_item_id = OLD.id AND merged.evidence_type = 'merge' AND merged.outcome = 'merged'
      AND merged.details->>'reviewed_revision' = tested_revision ORDER BY merged.created_at DESC LIMIT 1;
    IF merged_revision IS NULL THEN
      RAISE EXCEPTION 'Story cannot enter Post-merge verification until the exact approved revision is merged.' USING ERRCODE = '23514';
    END IF;
  END IF;
  IF OLD.kind = 'story' AND next_stage.slug = 'done' THEN
    IF EXISTS (SELECT 1 FROM api.work_items child WHERE child.parent_id = OLD.id AND child.kind = 'task'
      AND child.completed_at IS NULL AND child.progress <> 'completed') THEN
      RAISE EXCEPTION 'Story cannot move to Done while it has incomplete tasks.' USING ERRCODE = '23514';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM api.work_item_evidence reviewed WHERE reviewed.work_item_id = OLD.id
      AND reviewed.evidence_type = 'review' AND reviewed.outcome = 'approved'
      AND reviewed.revision = tested_revision AND reviewed.details->>'unresolved_findings' = '0') THEN
      RAISE EXCEPTION 'Story cannot enter Done until the accepted revision is approved.' USING ERRCODE = '23514';
    END IF;
    SELECT constraint_record.policy INTO regression_policy FROM api.project_quality_constraints constraint_record
    WHERE constraint_record.project_id = OLD.project_id AND constraint_record.constraint_key = 'regression_testing';
    post_merge_verified := EXISTS (
      SELECT 1 FROM api.work_item_evidence evidence WHERE evidence.work_item_id = OLD.id
        AND evidence.evidence_type = 'regression' AND evidence.outcome = 'passed' AND evidence.revision = merged_revision
        AND (regression_policy IS DISTINCT FROM 'waived' OR btrim(COALESCE(evidence.details->>'alternative_check', '')) <> '')
    );
    IF NOT post_merge_verified THEN
      RAISE EXCEPTION 'Story cannot enter Done until the merged revision passes a target-branch regression check, or a waived regression suite has passing alternative-check evidence.' USING ERRCODE = '23514';
    END IF;
    IF EXISTS (
      SELECT 1 FROM api.project_quality_constraints constraint_record
      WHERE constraint_record.project_id = OLD.project_id AND constraint_record.policy = 'required'
        AND NOT EXISTS (
          SELECT 1 FROM api.work_item_evidence evidence WHERE evidence.work_item_id = OLD.id
            AND evidence.evidence_type = constraint_record.evidence_type AND evidence.outcome = 'passed'
            AND evidence.revision = CASE WHEN constraint_record.evidence_type = 'regression' THEN merged_revision ELSE tested_revision END
        )
    ) THEN RAISE EXCEPTION 'Story cannot enter Done until every required project quality constraint has passing evidence.' USING ERRCODE = '23514'; END IF;
  END IF;
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION api.complete_design_card(
  target_work_item_id uuid,
  actor_name text DEFAULT 'AI agent'
) RETURNS SETOF api.work_items
LANGUAGE plpgsql AS $$
DECLARE
  item api.work_items;
  done_stage api.board_stages;
  requirements jsonb;
  approval_evidence api.work_item_evidence;
  design_revision text;
  asset_fingerprint text;
BEGIN
  SELECT * INTO item FROM api.work_items WHERE id = target_work_item_id FOR UPDATE;
  IF item.id IS NULL OR item.kind <> 'story' OR item.design_card_type IS NULL THEN
    RAISE EXCEPTION 'Only a visual concept or screen-mockup design card can use the design completion path.' USING ERRCODE = '23514';
  END IF;
  requirements := api.design_card_completion_requirements(item.id);
  IF jsonb_array_length(requirements) = 0 OR EXISTS (
    SELECT 1 FROM jsonb_array_elements(requirements) requirement
    WHERE COALESCE((requirement->>'blocking')::boolean, true)
      AND NOT COALESCE((requirement->>'satisfied')::boolean, false)
  ) THEN
    RAISE EXCEPTION 'Design card cannot complete until its analysis, plan, tasks, and governed human design approvals are complete.' USING ERRCODE = '23514';
  END IF;
  SELECT COALESCE(string_agg(asset.id::text || ':' || asset.approval_status, ',' ORDER BY asset.id), '')
  INTO asset_fingerprint FROM api.work_item_assets asset WHERE asset.work_item_id = item.id;
  design_revision := 'design-contract:' || md5(item.id::text || ':' || asset_fingerprint);
  INSERT INTO api.work_item_evidence(project_id, work_item_id, evidence_type, outcome, revision, summary, details, actor_name)
  VALUES (
    item.project_id, item.id, 'plan', 'approved', design_revision,
    'Governed design contract completed from human-approved design assets; no source implementation is asserted.',
    jsonb_build_object('completion_path', 'design_only', 'design_card_type', item.design_card_type, 'requirements', requirements), actor_name
  ) RETURNING * INTO approval_evidence;
  UPDATE api.work_items SET acceptance_criteria = COALESCE((
    SELECT jsonb_agg(criterion || jsonb_build_object(
      'status', 'passed', 'revision', design_revision, 'evidence_id', approval_evidence.id
    )) FROM jsonb_array_elements(item.acceptance_criteria) criterion
  ), '[]'::jsonb) WHERE id = item.id;
  SELECT * INTO done_stage FROM api.board_stages WHERE board_id = item.board_id AND slug = 'done';
  UPDATE api.work_items SET
    stage_id = done_stage.id,
    position = COALESCE((SELECT max(position) + 1 FROM api.work_items WHERE stage_id = done_stage.id AND id <> item.id), 0),
    progress = 'completed', execution_state = 'complete', blocked_reason = NULL, completed_at = now()
  WHERE id = item.id RETURNING * INTO item;
  INSERT INTO api.activity_events(project_id, work_item_id, event_type, actor_type, actor_name, summary, details)
  VALUES (
    item.project_id, item.id, 'work_item.moved', CASE WHEN actor_name = 'You' THEN 'human' ELSE 'agent' END, actor_name,
    'Completed approved design contract ' || item.item_key || ' without asserting software implementation',
    jsonb_build_object('from', 'plan', 'to', 'done', 'completion_path', 'design_only',
      'design_revision', design_revision, 'evidence_id', approval_evidence.id)
  );
  RETURN NEXT item;
END $$;

GRANT EXECUTE ON FUNCTION api.design_card_completion_requirements(uuid) TO web_anon;
GRANT EXECUTE ON FUNCTION api.design_card_can_complete(uuid) TO web_anon;
GRANT EXECUTE ON FUNCTION api.complete_design_card(uuid, text) TO web_anon;

NOTIFY pgrst, 'reload schema';
