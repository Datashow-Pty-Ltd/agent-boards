-- A claimed card is returned as a complete work package. The worker receives
-- the hierarchy, dependencies, acceptance contract, evidence, and the exact
-- promotion checks for the card's current stage.

CREATE OR REPLACE FUNCTION api.get_work_item_context(target_work_item_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  item api.work_items;
  current_stage api.board_stages;
  feature jsonb;
  child_tasks jsonb;
  prerequisites jsonb;
  evidence jsonb;
  next_stages jsonb;
  project_records jsonb;
  promotion_requirements jsonb;
  incomplete_prerequisite_count integer;
  incomplete_task_count integer;
  analysis_recorded boolean;
  plan_recorded boolean;
  implementation_recorded boolean;
  acceptance_passed boolean;
  tested_revision text;
  reviewed_and_merged boolean;
BEGIN
  SELECT * INTO item FROM api.work_items WHERE id = target_work_item_id;
  IF item.id IS NULL THEN RAISE EXCEPTION 'Work item not found.'; END IF;
  SELECT * INTO current_stage FROM api.board_stages WHERE id = item.stage_id;

  SELECT to_jsonb(parent) INTO feature
  FROM api.work_items parent
  WHERE parent.id = item.parent_id AND parent.kind = 'feature';

  SELECT COALESCE(jsonb_agg(to_jsonb(child) ORDER BY child.position, child.created_at), '[]'::jsonb)
  INTO child_tasks
  FROM api.work_items child
  WHERE child.parent_id = item.id AND child.kind = 'task' AND child.archived_at IS NULL;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'dependency', to_jsonb(dependency),
    'prerequisite', to_jsonb(prerequisite),
    'inherited_from_feature', dependency.work_item_id = item.parent_id,
    'satisfied', prerequisite.completed_at IS NOT NULL OR prerequisite.progress = 'completed'
  ) ORDER BY dependency.created_at), '[]'::jsonb),
  count(*) FILTER (WHERE prerequisite.completed_at IS NULL AND prerequisite.progress <> 'completed')::integer
  INTO prerequisites, incomplete_prerequisite_count
  FROM api.work_item_dependencies dependency
  JOIN api.work_items prerequisite ON prerequisite.id = dependency.depends_on_work_item_id
  WHERE dependency.work_item_id = item.id
     OR (item.parent_id IS NOT NULL AND dependency.work_item_id = item.parent_id);

  SELECT COALESCE(jsonb_agg(to_jsonb(record) ORDER BY record.created_at), '[]'::jsonb)
  INTO evidence
  FROM api.work_item_evidence record
  WHERE record.work_item_id = item.id;

  SELECT COALESCE(jsonb_agg(to_jsonb(stage) ORDER BY stage.position), '[]'::jsonb)
  INTO next_stages
  FROM api.board_stages stage
  WHERE stage.board_id = item.board_id
    AND current_stage.allowed_transitions ? stage.slug;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'key', record.artifact_key,
    'type', record.artifact_type,
    'title', record.title,
    'description', record.description,
    'status', record.status,
    'version', record.version,
    'updated_at', record.updated_at
  ) ORDER BY record.updated_at DESC), '[]'::jsonb)
  INTO project_records
  FROM api.project_artifacts record
  WHERE record.project_id = item.project_id;

  SELECT count(*) FILTER (
    WHERE child.completed_at IS NULL AND child.progress <> 'completed'
  )::integer INTO incomplete_task_count
  FROM api.work_items child
  WHERE child.parent_id = item.id AND child.kind = 'task' AND child.archived_at IS NULL;

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
  reviewed_and_merged := tested_revision IS NOT NULL AND EXISTS (
    SELECT 1
    FROM api.work_item_evidence reviewed
    JOIN api.work_item_evidence merged
      ON merged.work_item_id = reviewed.work_item_id
      AND merged.revision = reviewed.revision
      AND merged.evidence_type = 'merge'
      AND merged.outcome = 'merged'
    WHERE reviewed.work_item_id = item.id
      AND reviewed.evidence_type = 'review'
      AND reviewed.outcome = 'approved'
      AND reviewed.revision = tested_revision
  );

  promotion_requirements := CASE current_stage.slug
    WHEN 'backlog' THEN jsonb_build_array(
      jsonb_build_object(
        'key', 'acceptance_defined',
        'requirement', 'Deterministic acceptance criteria are defined',
        'satisfied', api.acceptance_criteria_are_deterministic(item.acceptance_criteria)
      ),
      jsonb_build_object(
        'key', 'prerequisites_done',
        'requirement', 'Every direct and inherited prerequisite is Done',
        'satisfied', incomplete_prerequisite_count = 0,
        'remaining', incomplete_prerequisite_count
      )
    )
    WHEN 'analyse' THEN jsonb_build_array(
      jsonb_build_object(
        'key', 'analysis_evidence',
        'requirement', 'Analysis evidence records context, constraints, risks, and dependency findings',
        'satisfied', analysis_recorded
      )
    )
    WHEN 'plan' THEN jsonb_build_array(
      jsonb_build_object(
        'key', 'implementation_plan',
        'requirement', 'A bounded implementation and verification plan is recorded',
        'satisfied', plan_recorded
      )
    )
    WHEN 'build' THEN jsonb_build_array(
      jsonb_build_object(
        'key', 'implementation_revision',
        'requirement', 'Implementation evidence identifies the exact revision to validate',
        'satisfied', implementation_recorded
      )
    )
    WHEN 'validate' THEN jsonb_build_array(
      jsonb_build_object(
        'key', 'acceptance_passed',
        'requirement', 'Every deterministic acceptance criterion passes for the same exact revision',
        'satisfied', acceptance_passed,
        'revision', tested_revision
      )
    )
    WHEN 'review' THEN jsonb_build_array(
      jsonb_build_object(
        'key', 'tasks_done',
        'requirement', 'Every child task is Done',
        'satisfied', incomplete_task_count = 0,
        'remaining', incomplete_task_count
      ),
      jsonb_build_object(
        'key', 'tested_revision_approved_and_merged',
        'requirement', 'The same tested revision is approved in review and recorded as merged',
        'satisfied', reviewed_and_merged,
        'revision', tested_revision
      )
    )
    WHEN 'done' THEN '[]'::jsonb
    ELSE '[]'::jsonb
  END;

  RETURN jsonb_build_object(
    'work_item', to_jsonb(item),
    'feature', feature,
    'tasks', child_tasks,
    'prerequisites', prerequisites,
    'current_stage', to_jsonb(current_stage),
    'promotion', jsonb_build_object(
      'terminal', current_stage.slug = 'done',
      'allowed_next_stages', next_stages,
      'stage_exit_criteria', current_stage.exit_criteria,
      'requirements', promotion_requirements,
      'ready', NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(promotion_requirements) requirement
        WHERE COALESCE((requirement->>'satisfied')::boolean, false) = false
      )
    ),
    'evidence', evidence,
    'project_records', project_records
  );
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
  RETURN jsonb_build_object(
    'outcome', 'claimed',
    'work_package', api.get_work_item_context(item.id)
  );
END $$;

GRANT EXECUTE ON FUNCTION api.get_work_item_context(uuid) TO web_anon;
GRANT EXECUTE ON FUNCTION api.claim_next_work_package(uuid, text) TO web_anon;

NOTIFY pgrst, 'reload schema';
