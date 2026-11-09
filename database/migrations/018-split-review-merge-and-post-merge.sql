-- Make the visible board match the governed delivery record. Review approval,
-- merge completion, and post-merge verification are separate stages with
-- separate evidence requirements.

BEGIN;

UPDATE api.boards
SET description = 'Backlog → Analyse → Plan → Build → Validate → Review → Merge → Post-merge verification → Done';

-- Free positions 6 and 7 before inserting the new stages.
UPDATE api.board_stages
SET position = 8
WHERE slug = 'done' AND position <> 8;

UPDATE api.board_stages
SET title = 'Review',
    position = 5,
    purpose = 'Review the exact validated revision and resolve every review finding.',
    responsible_actor = 'Reviewer',
    entry_criteria = '["Validation passed for an exact revision"]'::jsonb,
    exit_criteria = '["The validated revision is approved","No review findings remain unresolved"]'::jsonb,
    allowed_transitions = '["validate","merge"]'::jsonb
WHERE slug = 'review';

UPDATE api.board_stages
SET allowed_transitions = '["build","review"]'::jsonb
WHERE slug = 'validate';

INSERT INTO api.board_stages(
  board_id, slug, title, position, purpose, responsible_actor, wip_limit,
  entry_criteria, exit_criteria, allowed_transitions
)
SELECT
  board.id,
  'merge',
  'Merge',
  6,
  'Integrate the exact approved revision into the target branch.',
  'Maintainer',
  2,
  '["The validated revision is approved in review"]'::jsonb,
  '["The approved revision is merged successfully"]'::jsonb,
  '["review","post_merge"]'::jsonb
FROM api.boards board
ON CONFLICT (board_id, slug) DO UPDATE SET
  title = EXCLUDED.title,
  position = EXCLUDED.position,
  purpose = EXCLUDED.purpose,
  responsible_actor = EXCLUDED.responsible_actor,
  wip_limit = EXCLUDED.wip_limit,
  entry_criteria = EXCLUDED.entry_criteria,
  exit_criteria = EXCLUDED.exit_criteria,
  allowed_transitions = EXCLUDED.allowed_transitions;

INSERT INTO api.board_stages(
  board_id, slug, title, position, purpose, responsible_actor, wip_limit,
  entry_criteria, exit_criteria, allowed_transitions
)
SELECT
  board.id,
  'post_merge',
  'Post-merge verification',
  7,
  'Verify the merged revision on the target branch and record required regression evidence or an explicit waiver.',
  'Validation agent',
  3,
  '["The approved revision is merged"]'::jsonb,
  '["Target-branch checks pass","Every required project quality constraint passes or is explicitly waived"]'::jsonb,
  '["merge","done"]'::jsonb
FROM api.boards board
ON CONFLICT (board_id, slug) DO UPDATE SET
  title = EXCLUDED.title,
  position = EXCLUDED.position,
  purpose = EXCLUDED.purpose,
  responsible_actor = EXCLUDED.responsible_actor,
  wip_limit = EXCLUDED.wip_limit,
  entry_criteria = EXCLUDED.entry_criteria,
  exit_criteria = EXCLUDED.exit_criteria,
  allowed_transitions = EXCLUDED.allowed_transitions;

UPDATE api.board_stages
SET title = 'Done',
    position = 8,
    purpose = 'Show increments whose accepted, reviewed, merged and verified revisions reconcile.',
    responsible_actor = 'Product team',
    entry_criteria = '["The merged revision passed post-merge verification or every unavailable check has an explicit waiver"]'::jsonb,
    exit_criteria = '[]'::jsonb,
    allowed_transitions = '[]'::jsonb
WHERE slug = 'done';

CREATE OR REPLACE FUNCTION api.create_project(
  project_name text,
  project_key text,
  project_description text DEFAULT '',
  project_owner text DEFAULT 'Unassigned'
) RETURNS SETOF api.projects
LANGUAGE plpgsql AS $$
DECLARE project_record api.projects; board_record api.boards;
BEGIN
  INSERT INTO api.projects(name, project_key, description, owner)
  VALUES (project_name, upper(project_key), project_description, project_owner)
  RETURNING * INTO project_record;

  INSERT INTO api.boards(project_id, name, description)
  VALUES (
    project_record.id,
    'Delivery board',
    'Backlog → Analyse → Plan → Build → Validate → Review → Merge → Post-merge verification → Done'
  ) RETURNING * INTO board_record;

  INSERT INTO api.board_stages(
    board_id, slug, title, position, purpose, responsible_actor, wip_limit,
    entry_criteria, exit_criteria, allowed_transitions
  ) VALUES
    (board_record.id, 'backlog', 'Backlog', 0, 'Keep ordered product work ready for refinement.', 'Product owner', NULL,
      '["Desired outcome recorded"]', '["Priority and outcome are clear"]', '["analyse"]'),
    (board_record.id, 'analyse', 'Analyse', 1, 'Understand context, constraints, risks and alternatives.', 'Analysis agent', 4,
      '["Work is authorized"]', '["Acceptance criteria are measurable","Dependencies are known"]', '["backlog","plan"]'),
    (board_record.id, 'plan', 'Plan', 2, 'Define a bounded implementation and verification strategy.', 'Planning agent', 4,
      '["Analysis is complete"]', '["Implementation and test approach are clear"]', '["analyse","build"]'),
    (board_record.id, 'build', 'Build', 3, 'Implement the change in an isolated workspace.', 'Delivery agent', 5,
      '["Plan is ready"]', '["Implementation is complete","Local checks pass"]', '["plan","validate"]'),
    (board_record.id, 'validate', 'Validate', 4, 'Independently verify the exact implementation revision.', 'Validation agent', 3,
      '["Build is complete"]', '["Every deterministic acceptance criterion passes for the same revision"]', '["build","review"]'),
    (board_record.id, 'review', 'Review', 5, 'Review the exact validated revision and resolve every review finding.', 'Reviewer', 3,
      '["Validation passed for an exact revision"]', '["The validated revision is approved","No review findings remain unresolved"]', '["validate","merge"]'),
    (board_record.id, 'merge', 'Merge', 6, 'Integrate the exact approved revision into the target branch.', 'Maintainer', 2,
      '["The validated revision is approved in review"]', '["The approved revision is merged successfully"]', '["review","post_merge"]'),
    (board_record.id, 'post_merge', 'Post-merge verification', 7, 'Verify the merged revision on the target branch.', 'Validation agent', 3,
      '["The approved revision is merged"]', '["Target-branch checks pass or have an explicit waiver"]', '["merge","done"]'),
    (board_record.id, 'done', 'Done', 8, 'Show increments whose accepted, reviewed, merged and verified revisions reconcile.', 'Product team', NULL,
      '["Post-merge verification passed"]', '[]', '[]');

  INSERT INTO api.activity_events(project_id, event_type, actor_type, actor_name, summary)
  VALUES (project_record.id, 'project.created', 'system', 'Agent Boards', 'Project and nine-stage delivery board created');

  RETURN NEXT project_record;
END $$;

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

  -- Features are derived delivery containers and may close when every child
  -- story is Done without imitating the story evidence path.
  IF OLD.kind = 'feature' AND next_stage.slug = 'done'
     AND EXISTS (SELECT 1 FROM api.work_items child WHERE child.parent_id = OLD.id AND child.kind = 'story')
     AND NOT EXISTS (
       SELECT 1 FROM api.work_items child
       WHERE child.parent_id = OLD.id AND child.kind = 'story'
         AND child.completed_at IS NULL AND child.progress <> 'completed'
     ) THEN
    RETURN NEW;
  END IF;

  IF NOT (previous_stage.allowed_transitions ? next_stage.slug) THEN
    RAISE EXCEPTION 'Cannot move from % to %. Allowed next stages: %',
      previous_stage.title,
      next_stage.title,
      COALESCE((SELECT string_agg(value, ', ') FROM jsonb_array_elements_text(previous_stage.allowed_transitions)), 'none')
      USING ERRCODE = '23514',
            HINT = 'Move the card through each governed stage; completed work in Done is terminal.';
  END IF;

  IF OLD.kind = 'story' AND next_stage.slug = 'plan' AND NOT EXISTS (
    SELECT 1 FROM api.work_item_evidence evidence
    WHERE evidence.work_item_id = OLD.id AND evidence.evidence_type = 'analysis'
      AND evidence.outcome IN ('recorded', 'passed', 'approved')
  ) THEN
    RAISE EXCEPTION 'Story cannot enter Plan without recorded analysis evidence.' USING ERRCODE = '23514';
  END IF;

  IF OLD.kind = 'story' AND next_stage.slug = 'build' AND NOT EXISTS (
    SELECT 1 FROM api.work_item_evidence evidence
    WHERE evidence.work_item_id = OLD.id AND evidence.evidence_type = 'plan'
      AND evidence.outcome IN ('recorded', 'approved')
  ) THEN
    RAISE EXCEPTION 'Story cannot enter Build without a recorded implementation plan.' USING ERRCODE = '23514';
  END IF;

  IF OLD.kind = 'story' AND next_stage.slug = 'validate' AND NOT EXISTS (
    SELECT 1 FROM api.work_item_evidence evidence
    WHERE evidence.work_item_id = OLD.id AND evidence.evidence_type = 'implementation'
      AND evidence.outcome IN ('recorded', 'passed') AND evidence.revision IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'Story cannot enter Validate without implementation evidence for an exact revision.' USING ERRCODE = '23514';
  END IF;

  IF OLD.kind = 'story' AND next_stage.slug IN ('review', 'merge', 'post_merge', 'done') THEN
    IF NOT api.acceptance_criteria_passed_for_one_revision(OLD.acceptance_criteria) THEN
      RAISE EXCEPTION 'Every acceptance criterion must pass for the same revision before Review.' USING ERRCODE = '23514';
    END IF;
    SELECT criterion->>'revision' INTO tested_revision
    FROM jsonb_array_elements(OLD.acceptance_criteria) criterion LIMIT 1;
  END IF;

  IF OLD.kind = 'story' AND next_stage.slug = 'merge' THEN
    IF EXISTS (
      SELECT 1 FROM api.work_items child
      WHERE child.parent_id = OLD.id AND child.kind = 'task'
        AND child.completed_at IS NULL AND child.progress <> 'completed'
    ) THEN
      RAISE EXCEPTION 'Story cannot enter Merge while it has incomplete tasks.' USING ERRCODE = '23514';
    END IF;
    review_approved := EXISTS (
      SELECT 1 FROM api.work_item_evidence evidence
      WHERE evidence.work_item_id = OLD.id AND evidence.evidence_type = 'review'
        AND evidence.outcome = 'approved' AND evidence.revision = tested_revision
        AND evidence.details->>'unresolved_findings' = '0'
    );
    IF NOT review_approved THEN
      RAISE EXCEPTION 'Story cannot enter Merge until the validated revision is approved in review.' USING ERRCODE = '23514';
    END IF;
  END IF;

  IF OLD.kind = 'story' AND next_stage.slug IN ('post_merge', 'done') THEN
    SELECT merged.revision INTO merged_revision
    FROM api.work_item_evidence merged
    WHERE merged.work_item_id = OLD.id
      AND merged.evidence_type = 'merge'
      AND merged.outcome = 'merged'
      AND merged.details->>'reviewed_revision' = tested_revision
    ORDER BY merged.created_at DESC LIMIT 1;
    IF merged_revision IS NULL THEN
      RAISE EXCEPTION 'Story cannot enter Post-merge verification until the exact approved revision is merged.' USING ERRCODE = '23514';
    END IF;
  END IF;

  IF OLD.kind = 'story' AND next_stage.slug = 'done' THEN
    IF EXISTS (
      SELECT 1 FROM api.work_items child
      WHERE child.parent_id = OLD.id AND child.kind = 'task'
        AND child.completed_at IS NULL AND child.progress <> 'completed'
    ) THEN
      RAISE EXCEPTION 'Story cannot move to Done while it has incomplete tasks.' USING ERRCODE = '23514';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM api.work_item_evidence reviewed
      WHERE reviewed.work_item_id = OLD.id AND reviewed.evidence_type = 'review'
        AND reviewed.outcome = 'approved' AND reviewed.revision = tested_revision
        AND reviewed.details->>'unresolved_findings' = '0'
    ) THEN
      RAISE EXCEPTION 'Story cannot enter Done until the accepted revision is approved.' USING ERRCODE = '23514';
    END IF;
    SELECT constraint_record.policy INTO regression_policy
    FROM api.project_quality_constraints constraint_record
    WHERE constraint_record.project_id = OLD.project_id
      AND constraint_record.constraint_key = 'regression_testing';
    post_merge_verified := EXISTS (
      SELECT 1 FROM api.work_item_evidence evidence
      WHERE evidence.work_item_id = OLD.id
        AND evidence.evidence_type = 'regression'
        AND evidence.outcome = 'passed'
        AND evidence.revision = merged_revision
        AND (
          regression_policy IS DISTINCT FROM 'waived'
          OR btrim(COALESCE(evidence.details->>'alternative_check', '')) <> ''
        )
    );
    IF NOT post_merge_verified THEN
      RAISE EXCEPTION 'Story cannot enter Done until the merged revision passes a target-branch regression check, or a waived regression suite has passing alternative-check evidence.' USING ERRCODE = '23514';
    END IF;
    IF EXISTS (
      SELECT 1
      FROM api.project_quality_constraints constraint_record
      WHERE constraint_record.project_id = OLD.project_id
        AND constraint_record.policy = 'required'
        AND NOT EXISTS (
          SELECT 1 FROM api.work_item_evidence evidence
          WHERE evidence.work_item_id = OLD.id
            AND evidence.evidence_type = constraint_record.evidence_type
            AND evidence.outcome = 'passed'
            AND evidence.revision = CASE
              WHEN constraint_record.evidence_type = 'regression' THEN merged_revision
              ELSE tested_revision
            END
        )
    ) THEN
      RAISE EXCEPTION 'Story cannot enter Done until every required project quality constraint has passing evidence.' USING ERRCODE = '23514';
    END IF;
  END IF;

  RETURN NEW;
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
  quality_requirements jsonb;
  incomplete_task_count integer;
  analysis_recorded boolean;
  plan_recorded boolean;
  implementation_recorded boolean;
  acceptance_passed boolean;
  tested_revision text;
  review_approved boolean;
  merge_revision text;
  merge_recorded boolean;
  regression_policy text;
  post_merge_verified boolean;
BEGIN
  SELECT * INTO item FROM api.work_items WHERE id = target_work_item_id;
  IF item.id IS NULL THEN RAISE EXCEPTION 'Work item not found.'; END IF;
  SELECT * INTO current_stage FROM api.board_stages WHERE id = item.stage_id;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', child.id, 'key', child.item_key, 'title', child.title,
    'description', child.description, 'checklist', child.checklist,
    'progress', child.progress, 'execution_state', child.execution_state
  ) ORDER BY child.position, child.created_at), '[]'::jsonb),
  count(*) FILTER (WHERE child.completed_at IS NULL AND child.progress <> 'completed')::integer
  INTO child_tasks, incomplete_task_count
  FROM api.work_items child
  WHERE child.parent_id = item.id AND child.kind = 'task' AND child.archived_at IS NULL;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'slug', stage.slug, 'title', stage.title, 'entry_criteria', stage.entry_criteria
  ) ORDER BY stage.position), '[]'::jsonb)
  INTO next_stages
  FROM api.board_stages stage
  WHERE stage.board_id = item.board_id AND current_stage.allowed_transitions ? stage.slug;

  analysis_recorded := EXISTS (
    SELECT 1 FROM api.work_item_evidence evidence
    WHERE evidence.work_item_id = item.id AND evidence.evidence_type = 'analysis'
      AND evidence.outcome IN ('recorded','passed','approved')
  );
  plan_recorded := EXISTS (
    SELECT 1 FROM api.work_item_evidence evidence
    WHERE evidence.work_item_id = item.id AND evidence.evidence_type = 'plan'
      AND evidence.outcome IN ('recorded','approved')
  );
  implementation_recorded := EXISTS (
    SELECT 1 FROM api.work_item_evidence evidence
    WHERE evidence.work_item_id = item.id AND evidence.evidence_type = 'implementation'
      AND evidence.outcome IN ('recorded','passed') AND evidence.revision IS NOT NULL
  );
  acceptance_passed := api.acceptance_criteria_passed_for_one_revision(item.acceptance_criteria);
  IF acceptance_passed THEN
    SELECT criterion->>'revision' INTO tested_revision
    FROM jsonb_array_elements(item.acceptance_criteria) criterion LIMIT 1;
  END IF;
  review_approved := tested_revision IS NOT NULL AND EXISTS (
    SELECT 1 FROM api.work_item_evidence evidence
    WHERE evidence.work_item_id = item.id AND evidence.evidence_type = 'review'
      AND evidence.outcome = 'approved' AND evidence.revision = tested_revision
      AND evidence.details->>'unresolved_findings' = '0'
  );
  SELECT merged.revision INTO merge_revision
  FROM api.work_item_evidence merged
  WHERE merged.work_item_id = item.id AND merged.evidence_type = 'merge'
    AND merged.outcome = 'merged' AND merged.details->>'reviewed_revision' = tested_revision
  ORDER BY merged.created_at DESC LIMIT 1;
  merge_recorded := merge_revision IS NOT NULL;
  SELECT constraint_record.policy INTO regression_policy
  FROM api.project_quality_constraints constraint_record
  WHERE constraint_record.project_id = item.project_id
    AND constraint_record.constraint_key = 'regression_testing';
  post_merge_verified := merge_revision IS NOT NULL AND EXISTS (
    SELECT 1 FROM api.work_item_evidence evidence
    WHERE evidence.work_item_id = item.id
      AND evidence.evidence_type = 'regression'
      AND evidence.outcome = 'passed'
      AND evidence.revision = merge_revision
      AND (
        regression_policy IS DISTINCT FROM 'waived'
        OR btrim(COALESCE(evidence.details->>'alternative_check', '')) <> ''
      )
  );

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'requirement', CASE
      WHEN constraint_record.constraint_key = 'regression_testing'
        THEN 'The merged revision passes target-branch regression, or a waived suite has a passing alternative check'
      ELSE constraint_record.title
    END,
    'description', constraint_record.description,
    'policy', constraint_record.policy,
    'blocking', constraint_record.policy = 'required' OR constraint_record.constraint_key = 'regression_testing',
    'satisfied', CASE
      WHEN constraint_record.constraint_key = 'regression_testing' THEN post_merge_verified
      WHEN constraint_record.policy = 'waived' THEN true
      ELSE EXISTS (
        SELECT 1 FROM api.work_item_evidence evidence
        WHERE evidence.work_item_id = item.id
          AND evidence.evidence_type = constraint_record.evidence_type
          AND evidence.outcome = 'passed'
          AND evidence.revision = CASE
            WHEN constraint_record.evidence_type = 'regression' THEN merge_revision
            ELSE tested_revision
          END
      )
    END,
    'evidence_type', constraint_record.evidence_type,
    'verification_ref', constraint_record.verification_ref,
    'expected_result', constraint_record.expected_result,
    'waiver_reason', constraint_record.waiver_reason,
    'revision', CASE WHEN constraint_record.evidence_type = 'regression' THEN merge_revision ELSE tested_revision END
  ) ORDER BY constraint_record.constraint_key), '[]'::jsonb)
  INTO quality_requirements
  FROM api.project_quality_constraints constraint_record
  WHERE constraint_record.project_id = item.project_id;

  promotion_requirements := CASE current_stage.slug
    WHEN 'backlog' THEN jsonb_build_array(
      jsonb_build_object('requirement', 'Deterministic acceptance criteria are defined', 'satisfied', api.acceptance_criteria_are_deterministic(item.acceptance_criteria), 'blocking', true),
      jsonb_build_object('requirement', 'Every prerequisite is Done', 'satisfied', true, 'blocking', true)
    )
    WHEN 'analyse' THEN jsonb_build_array(
      jsonb_build_object('requirement', 'Analysis evidence records context, constraints, risks, and dependency findings', 'satisfied', analysis_recorded, 'blocking', true)
    )
    WHEN 'plan' THEN jsonb_build_array(
      jsonb_build_object('requirement', 'A bounded implementation and verification plan is recorded', 'satisfied', plan_recorded, 'blocking', true)
    )
    WHEN 'build' THEN jsonb_build_array(
      jsonb_build_object('requirement', 'Implementation evidence identifies the exact revision to validate', 'satisfied', implementation_recorded, 'blocking', true)
    )
    WHEN 'validate' THEN jsonb_build_array(
      jsonb_build_object('requirement', 'Every story acceptance criterion passes for the same exact revision', 'satisfied', acceptance_passed, 'revision', tested_revision, 'blocking', true)
    )
    WHEN 'review' THEN jsonb_build_array(
      jsonb_build_object('requirement', 'Every child task is Done', 'satisfied', incomplete_task_count = 0, 'remaining', incomplete_task_count, 'blocking', true),
      jsonb_build_object('requirement', 'The accepted revision is approved in review with no unresolved findings', 'satisfied', review_approved, 'revision', tested_revision, 'blocking', true)
    )
    WHEN 'merge' THEN jsonb_build_array(
      jsonb_build_object('requirement', 'The exact reviewed revision is merged successfully', 'satisfied', merge_recorded, 'reviewed_revision', tested_revision, 'revision', merge_revision, 'blocking', true)
    )
    WHEN 'post_merge' THEN jsonb_build_array(
      jsonb_build_object('requirement', 'Accepted, reviewed and merged revisions reconcile', 'satisfied', acceptance_passed AND review_approved AND merge_recorded, 'accepted_revision', tested_revision, 'merged_revision', merge_revision, 'blocking', true)
    ) || quality_requirements
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
        WHERE COALESCE((requirement->>'blocking')::boolean, true)
          AND NOT COALESCE((requirement->>'satisfied')::boolean, false)
      )
    )
  );
END $$;

GRANT EXECUTE ON FUNCTION api.create_project(text, text, text, text) TO web_anon;
GRANT EXECUTE ON FUNCTION api.get_work_item_context(uuid) TO web_anon;

NOTIFY pgrst, 'reload schema';

COMMIT;
