-- Keep claimed work focused: the story, its tasks, invariants, acceptance
-- contract, and the requirements for promotion from the current stage.

ALTER TABLE api.work_items
  ADD COLUMN IF NOT EXISTS invariants jsonb NOT NULL DEFAULT '[]'::jsonb;

DROP FUNCTION IF EXISTS api.create_backlog_item(uuid, text, text, text, text, uuid, text, jsonb, text);
CREATE OR REPLACE FUNCTION api.create_backlog_item(
  target_project_id uuid,
  item_title text,
  item_description text DEFAULT '',
  item_kind text DEFAULT 'story',
  item_priority text DEFAULT 'medium',
  parent_work_item_id uuid DEFAULT NULL,
  item_assignee text DEFAULT NULL,
  item_acceptance_criteria jsonb DEFAULT '[]'::jsonb,
  item_invariants jsonb DEFAULT '[]'::jsonb,
  actor_name text DEFAULT 'You'
) RETURNS SETOF api.work_items
LANGUAGE plpgsql AS $$
DECLARE item api.work_items; target_board uuid; backlog_stage uuid; normalized_criteria jsonb;
BEGIN
  IF item_kind = 'story' AND NOT api.acceptance_criteria_are_deterministic(item_acceptance_criteria) THEN
    RAISE EXCEPTION 'A story requires deterministic acceptance criteria when it is defined.'
      USING ERRCODE = '23514',
        HINT = 'Each criterion needs a statement, verification_method, verification_ref, and exact expected_result.';
  END IF;
  IF jsonb_typeof(COALESCE(item_invariants, '[]'::jsonb)) <> 'array' OR EXISTS (
    SELECT 1 FROM jsonb_array_elements(COALESCE(item_invariants, '[]'::jsonb)) invariant
    WHERE jsonb_typeof(invariant) <> 'string' OR btrim(trim(both '"' from invariant::text)) = ''
  ) THEN
    RAISE EXCEPTION 'Invariants must be a JSON array of non-empty strings.' USING ERRCODE = '23514';
  END IF;

  normalized_criteria := CASE
    WHEN jsonb_array_length(COALESCE(item_acceptance_criteria, '[]'::jsonb)) > 0
      THEN api.normalize_acceptance_criteria(item_acceptance_criteria)
    ELSE '[]'::jsonb
  END;
  SELECT id INTO target_board FROM api.boards WHERE project_id = target_project_id;
  SELECT id INTO backlog_stage FROM api.board_stages WHERE board_id = target_board AND slug = 'backlog';
  INSERT INTO api.work_items(
    project_id, board_id, parent_id, stage_id, item_key, kind, title, description,
    priority, assignee, acceptance_criteria, invariants, position
  ) VALUES (
    target_project_id, target_board, parent_work_item_id, backlog_stage,
    api.allocate_item_key(target_project_id), item_kind, item_title, item_description,
    item_priority, item_assignee, normalized_criteria, COALESCE(item_invariants, '[]'::jsonb),
    COALESCE((SELECT max(position) + 1 FROM api.work_items WHERE stage_id = backlog_stage), 0)
  ) RETURNING * INTO item;
  INSERT INTO api.activity_events(project_id, work_item_id, event_type, actor_type, actor_name, summary, details)
  VALUES (
    target_project_id, item.id, 'work_item.created',
    CASE WHEN actor_name = 'You' THEN 'human' ELSE 'agent' END,
    actor_name, 'Created ' || item.item_key || ' in Backlog',
    jsonb_build_object(
      'kind', item.kind,
      'acceptance_criteria_count', jsonb_array_length(normalized_criteria),
      'invariant_count', jsonb_array_length(COALESCE(item_invariants, '[]'::jsonb))
    )
  );
  RETURN NEXT item;
END $$;

CREATE OR REPLACE FUNCTION api.set_work_item_invariants(
  target_work_item_id uuid,
  target_invariants jsonb,
  actor_name text DEFAULT 'You'
) RETURNS SETOF api.work_items
LANGUAGE plpgsql AS $$
DECLARE item api.work_items; stage api.board_stages;
BEGIN
  SELECT * INTO item FROM api.work_items WHERE id = target_work_item_id FOR UPDATE;
  IF item.id IS NULL THEN RAISE EXCEPTION 'Work item not found.'; END IF;
  SELECT * INTO stage FROM api.board_stages WHERE id = item.stage_id;
  IF stage.slug NOT IN ('backlog', 'analyse', 'plan') THEN
    RAISE EXCEPTION 'Story invariants cannot change after Build begins.' USING ERRCODE = '23514';
  END IF;
  IF jsonb_typeof(COALESCE(target_invariants, '[]'::jsonb)) <> 'array' OR EXISTS (
    SELECT 1 FROM jsonb_array_elements(COALESCE(target_invariants, '[]'::jsonb)) invariant
    WHERE jsonb_typeof(invariant) <> 'string' OR btrim(trim(both '"' from invariant::text)) = ''
  ) THEN
    RAISE EXCEPTION 'Invariants must be a JSON array of non-empty strings.' USING ERRCODE = '23514';
  END IF;
  UPDATE api.work_items SET invariants = COALESCE(target_invariants, '[]'::jsonb)
  WHERE id = item.id RETURNING * INTO item;
  INSERT INTO api.activity_events(project_id, work_item_id, event_type, actor_type, actor_name, summary)
  VALUES (item.project_id, item.id, 'work_item.invariants_defined',
    CASE WHEN actor_name = 'You' THEN 'human' ELSE 'agent' END,
    actor_name, 'Defined invariants for ' || item.item_key);
  RETURN NEXT item;
END $$;

CREATE OR REPLACE FUNCTION api.get_work_item_context(target_work_item_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  item api.work_items;
  current_stage api.board_stages;
  child_tasks jsonb;
  next_stages jsonb;
  promotion_requirements jsonb;
  incomplete_task_count integer;
  analysis_recorded boolean;
  plan_recorded boolean;
  implementation_recorded boolean;
  acceptance_passed boolean;
  tested_revision text;
  review_approved boolean;
  merge_revision text;
  merge_recorded boolean;
  regression_passed boolean;
BEGIN
  SELECT * INTO item FROM api.work_items WHERE id = target_work_item_id;
  IF item.id IS NULL THEN RAISE EXCEPTION 'Work item not found.'; END IF;
  SELECT * INTO current_stage FROM api.board_stages WHERE id = item.stage_id;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', child.id,
    'key', child.item_key,
    'title', child.title,
    'description', child.description,
    'checklist', child.checklist,
    'progress', child.progress,
    'execution_state', child.execution_state
  ) ORDER BY child.position, child.created_at), '[]'::jsonb),
  count(*) FILTER (WHERE child.completed_at IS NULL AND child.progress <> 'completed')::integer
  INTO child_tasks, incomplete_task_count
  FROM api.work_items child
  WHERE child.parent_id = item.id AND child.kind = 'task' AND child.archived_at IS NULL;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'slug', stage.slug,
    'title', stage.title,
    'entry_criteria', stage.entry_criteria
  ) ORDER BY stage.position), '[]'::jsonb)
  INTO next_stages
  FROM api.board_stages stage
  WHERE stage.board_id = item.board_id AND current_stage.allowed_transitions ? stage.slug;

  analysis_recorded := EXISTS (
    SELECT 1 FROM api.work_item_evidence record
    WHERE record.work_item_id = item.id AND record.evidence_type = 'analysis'
      AND record.outcome IN ('recorded', 'passed', 'approved')
  );
  plan_recorded := EXISTS (
    SELECT 1 FROM api.work_item_evidence record
    WHERE record.work_item_id = item.id AND record.evidence_type = 'plan'
      AND record.outcome IN ('recorded', 'approved')
  );
  implementation_recorded := EXISTS (
    SELECT 1 FROM api.work_item_evidence record
    WHERE record.work_item_id = item.id AND record.evidence_type = 'implementation'
      AND record.outcome IN ('recorded', 'passed') AND record.revision IS NOT NULL
  );
  acceptance_passed := api.acceptance_criteria_passed_for_one_revision(item.acceptance_criteria);
  IF acceptance_passed THEN
    SELECT criterion->>'revision' INTO tested_revision
    FROM jsonb_array_elements(item.acceptance_criteria) criterion LIMIT 1;
  END IF;
  review_approved := tested_revision IS NOT NULL AND EXISTS (
    SELECT 1 FROM api.work_item_evidence reviewed
    WHERE reviewed.work_item_id = item.id
      AND reviewed.evidence_type = 'review'
      AND reviewed.outcome = 'approved'
      AND reviewed.revision = tested_revision
  );
  SELECT merged.revision INTO merge_revision
  FROM api.work_item_evidence merged
  WHERE merged.work_item_id = item.id
    AND merged.evidence_type = 'merge'
    AND merged.outcome = 'merged'
    AND (
      merged.details->>'reviewed_revision' = tested_revision
      OR (merged.details->>'reviewed_revision' IS NULL AND merged.revision = tested_revision)
    )
  ORDER BY merged.created_at DESC LIMIT 1;
  merge_recorded := merge_revision IS NOT NULL;
  regression_passed := merge_revision IS NOT NULL AND EXISTS (
    SELECT 1 FROM api.work_item_evidence regression
    WHERE regression.work_item_id = item.id
      AND regression.evidence_type = 'regression'
      AND regression.outcome = 'passed'
      AND regression.revision = merge_revision
  );

  promotion_requirements := CASE current_stage.slug
    WHEN 'backlog' THEN jsonb_build_array(
      jsonb_build_object('requirement', 'Deterministic acceptance criteria are defined', 'satisfied', api.acceptance_criteria_are_deterministic(item.acceptance_criteria)),
      jsonb_build_object('requirement', 'Every prerequisite is Done', 'satisfied', true)
    )
    WHEN 'analyse' THEN jsonb_build_array(
      jsonb_build_object('requirement', 'Analysis evidence records context, constraints, risks, and dependency findings', 'satisfied', analysis_recorded)
    )
    WHEN 'plan' THEN jsonb_build_array(
      jsonb_build_object('requirement', 'A bounded implementation and verification plan is recorded', 'satisfied', plan_recorded)
    )
    WHEN 'build' THEN jsonb_build_array(
      jsonb_build_object('requirement', 'Implementation evidence identifies the exact revision to validate', 'satisfied', implementation_recorded)
    )
    WHEN 'validate' THEN jsonb_build_array(
      jsonb_build_object('requirement', 'Every acceptance criterion passes for the same exact revision', 'satisfied', acceptance_passed, 'revision', tested_revision)
    )
    WHEN 'review' THEN jsonb_build_array(
      jsonb_build_object('requirement', 'Every child task is Done', 'satisfied', incomplete_task_count = 0, 'remaining', incomplete_task_count),
      jsonb_build_object('requirement', 'The tested revision is approved in review', 'satisfied', review_approved, 'revision', tested_revision),
      jsonb_build_object('requirement', 'The approved code is merged successfully', 'satisfied', merge_recorded, 'revision', merge_revision),
      jsonb_build_object('requirement', 'Automated regression passes on the merged revision', 'satisfied', regression_passed, 'revision', merge_revision)
    )
    ELSE '[]'::jsonb
  END;

  RETURN jsonb_build_object(
    'story', (to_jsonb(item) - 'acceptance_criteria' - 'invariants'),
    'tasks', child_tasks,
    'invariants', item.invariants,
    'story_acceptance_criteria', item.acceptance_criteria,
    'promotion', jsonb_build_object(
      'current_stage', jsonb_build_object(
        'slug', current_stage.slug,
        'title', current_stage.title,
        'purpose', current_stage.purpose,
        'entry_criteria', current_stage.entry_criteria,
        'exit_criteria', current_stage.exit_criteria
      ),
      'allowed_next_stages', next_stages,
      'acceptance_criteria', promotion_requirements,
      'ready', NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(promotion_requirements) requirement
        WHERE COALESCE((requirement->>'satisfied')::boolean, false) = false
      )
    )
  );
END $$;

GRANT EXECUTE ON FUNCTION api.create_backlog_item(uuid, text, text, text, text, uuid, text, jsonb, jsonb, text) TO web_anon;
GRANT EXECUTE ON FUNCTION api.set_work_item_invariants(uuid, jsonb, text) TO web_anon;
GRANT EXECUTE ON FUNCTION api.get_work_item_context(uuid) TO web_anon;

NOTIFY pgrst, 'reload schema';
