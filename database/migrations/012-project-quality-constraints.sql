-- Testing policy belongs to the project, not to Agent Boards itself. The
-- defaults are recommendations. Agents can make them deterministic and
-- required, while an explicit user decision can waive them with a durable
-- rationale. Promotion gates enforce only constraints recorded as required.

CREATE TABLE IF NOT EXISTS api.project_quality_constraints (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id uuid NOT NULL REFERENCES api.projects(id) ON DELETE CASCADE,
  constraint_key text NOT NULL,
  title text NOT NULL,
  description text NOT NULL DEFAULT '',
  policy text NOT NULL DEFAULT 'recommended' CHECK (policy IN ('recommended', 'required', 'waived')),
  evidence_type text NOT NULL CHECK (evidence_type IN ('unit_test', 'regression')),
  verification_ref text,
  expected_result text,
  waiver_reason text,
  decided_by text NOT NULL DEFAULT 'Agent Boards',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (project_id, constraint_key),
  CHECK (policy <> 'waived' OR btrim(COALESCE(waiver_reason, '')) <> ''),
  CHECK (policy <> 'required' OR (
    btrim(COALESCE(verification_ref, '')) <> '' AND
    btrim(COALESCE(expected_result, '')) <> ''
  ))
);

DROP TRIGGER IF EXISTS project_quality_constraints_updated_at ON api.project_quality_constraints;
CREATE TRIGGER project_quality_constraints_updated_at
  BEFORE UPDATE ON api.project_quality_constraints
  FOR EACH ROW EXECUTE FUNCTION api.set_updated_at();

INSERT INTO api.project_quality_constraints(
  project_id, constraint_key, title, description, evidence_type
)
SELECT id, 'unit_testing', 'Unit tests pass',
  'Add or run focused unit tests when the repository supports them.', 'unit_test'
FROM api.projects
ON CONFLICT (project_id, constraint_key) DO NOTHING;

INSERT INTO api.project_quality_constraints(
  project_id, constraint_key, title, description, evidence_type
)
SELECT id, 'regression_testing', 'Automated regression passes',
  'Run the repository regression suite against the merged revision when one is available.', 'regression'
FROM api.projects
ON CONFLICT (project_id, constraint_key) DO NOTHING;

CREATE OR REPLACE FUNCTION api.seed_project_quality_constraints() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO api.project_quality_constraints(
    project_id, constraint_key, title, description, evidence_type
  ) VALUES
    (NEW.id, 'unit_testing', 'Unit tests pass',
      'Add or run focused unit tests when the repository supports them.', 'unit_test'),
    (NEW.id, 'regression_testing', 'Automated regression passes',
      'Run the repository regression suite against the merged revision when one is available.', 'regression')
  ON CONFLICT (project_id, constraint_key) DO NOTHING;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS seed_project_quality_constraints ON api.projects;
CREATE TRIGGER seed_project_quality_constraints
  AFTER INSERT ON api.projects
  FOR EACH ROW EXECUTE FUNCTION api.seed_project_quality_constraints();

CREATE OR REPLACE FUNCTION api.set_project_quality_constraint(
  target_project_id uuid,
  target_constraint_key text,
  target_policy text,
  actor_name text,
  target_description text DEFAULT NULL,
  target_verification_ref text DEFAULT NULL,
  target_expected_result text DEFAULT NULL,
  target_waiver_reason text DEFAULT NULL
) RETURNS SETOF api.project_quality_constraints
LANGUAGE plpgsql AS $$
DECLARE constraint_record api.project_quality_constraints;
BEGIN
  IF target_policy NOT IN ('recommended', 'required', 'waived') THEN
    RAISE EXCEPTION 'Quality policy must be recommended, required, or waived.' USING ERRCODE = '23514';
  END IF;
  IF target_policy = 'waived' AND btrim(COALESCE(target_waiver_reason, '')) = '' THEN
    RAISE EXCEPTION 'A waived quality constraint requires the user decision and rationale.' USING ERRCODE = '23514';
  END IF;
  IF target_policy = 'required' AND (
    btrim(COALESCE(target_verification_ref, '')) = '' OR
    btrim(COALESCE(target_expected_result, '')) = ''
  ) THEN
    RAISE EXCEPTION 'A required quality constraint needs a verification reference and exact expected result.' USING ERRCODE = '23514';
  END IF;

  UPDATE api.project_quality_constraints SET
    policy = target_policy,
    description = COALESCE(target_description, description),
    verification_ref = CASE WHEN target_policy = 'waived' THEN NULL ELSE target_verification_ref END,
    expected_result = CASE WHEN target_policy = 'waived' THEN NULL ELSE target_expected_result END,
    waiver_reason = CASE WHEN target_policy = 'waived' THEN target_waiver_reason ELSE NULL END,
    decided_by = actor_name
  WHERE project_id = target_project_id AND constraint_key = target_constraint_key
  RETURNING * INTO constraint_record;

  IF constraint_record.id IS NULL THEN
    RAISE EXCEPTION 'Unknown project quality constraint: %', target_constraint_key USING ERRCODE = '23514';
  END IF;

  INSERT INTO api.activity_events(project_id, event_type, actor_type, actor_name, summary, details)
  VALUES (
    target_project_id, 'project.quality_constraint_set',
    CASE WHEN actor_name = 'You' THEN 'human' ELSE 'agent' END,
    actor_name,
    'Set ' || constraint_record.title || ' to ' || target_policy,
    jsonb_build_object(
      'constraint_key', target_constraint_key,
      'policy', target_policy,
      'waiver_reason', target_waiver_reason,
      'verification_ref', target_verification_ref,
      'expected_result', target_expected_result
    )
  );
  RETURN NEXT constraint_record;
END $$;

ALTER TABLE api.work_item_evidence
  DROP CONSTRAINT IF EXISTS work_item_evidence_evidence_type_check;
ALTER TABLE api.work_item_evidence
  ADD CONSTRAINT work_item_evidence_evidence_type_check CHECK (evidence_type IN (
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
  IF target_evidence_type NOT IN ('analysis', 'plan', 'implementation', 'test', 'unit_test', 'review', 'merge', 'regression') THEN
    RAISE EXCEPTION 'Unsupported evidence type: %', target_evidence_type USING ERRCODE = '23514';
  END IF;
  IF target_outcome NOT IN ('recorded', 'passed', 'failed', 'approved', 'rejected', 'merged') THEN
    RAISE EXCEPTION 'Unsupported evidence outcome: %', target_outcome USING ERRCODE = '23514';
  END IF;
  IF btrim(COALESCE(evidence_summary, '')) = '' THEN
    RAISE EXCEPTION 'Evidence requires a summary.' USING ERRCODE = '23514';
  END IF;
  IF target_evidence_type IN ('implementation', 'test', 'unit_test', 'review', 'merge', 'regression')
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
DECLARE previous_stage api.board_stages; next_stage api.board_stages; tested_revision text; merged_revision text;
BEGIN
  IF NEW.stage_id = OLD.stage_id THEN RETURN NEW; END IF;
  SELECT * INTO previous_stage FROM api.board_stages WHERE id = OLD.stage_id;
  SELECT * INTO next_stage FROM api.board_stages WHERE id = NEW.stage_id;
  IF next_stage.id IS NULL OR next_stage.board_id <> OLD.board_id THEN
    RAISE EXCEPTION 'Target stage does not belong to this board.' USING ERRCODE = '23514';
  END IF;
  -- Features are delivery containers, not autonomous work. Once every child
  -- story is Done, the feature can be closed as a derived project record.
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
    SELECT merged.revision INTO merged_revision
    FROM api.work_item_evidence reviewed
    JOIN api.work_item_evidence merged
      ON merged.work_item_id = reviewed.work_item_id
      AND merged.evidence_type = 'merge' AND merged.outcome = 'merged'
      AND merged.details->>'reviewed_revision' = reviewed.revision
    WHERE reviewed.work_item_id = OLD.id
      AND reviewed.evidence_type = 'review' AND reviewed.outcome = 'approved'
      AND reviewed.revision = tested_revision
    ORDER BY merged.created_at DESC LIMIT 1;
    IF merged_revision IS NULL THEN
      RAISE EXCEPTION 'Story cannot enter Done until the accepted revision is approved and merged.' USING ERRCODE = '23514';
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

CREATE OR REPLACE FUNCTION api.complete_parent_feature_when_stories_done() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE feature_record api.work_items; done_stage_id uuid;
BEGIN
  IF NEW.kind <> 'story' OR NEW.parent_id IS NULL OR NEW.progress <> 'completed' THEN
    RETURN NEW;
  END IF;
  SELECT * INTO feature_record FROM api.work_items
  WHERE id = NEW.parent_id AND kind = 'feature' FOR UPDATE;
  IF feature_record.id IS NULL OR feature_record.progress = 'completed' OR EXISTS (
    SELECT 1 FROM api.work_items child
    WHERE child.parent_id = feature_record.id AND child.kind = 'story'
      AND child.completed_at IS NULL AND child.progress <> 'completed'
  ) THEN
    RETURN NEW;
  END IF;
  SELECT id INTO done_stage_id FROM api.board_stages
  WHERE board_id = feature_record.board_id AND slug = 'done';
  UPDATE api.work_items SET
    stage_id = done_stage_id,
    progress = 'completed',
    execution_state = 'complete',
    completed_at = now()
  WHERE id = feature_record.id;
  INSERT INTO api.activity_events(project_id, work_item_id, event_type, actor_type, actor_name, summary)
  VALUES (feature_record.project_id, feature_record.id, 'feature.completed', 'system', 'Agent Boards',
    'Completed ' || feature_record.item_key || ' after every child story reached Done');
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS complete_parent_feature_when_stories_done ON api.work_items;
CREATE TRIGGER complete_parent_feature_when_stories_done
  AFTER UPDATE OF progress, completed_at ON api.work_items
  FOR EACH ROW EXECUTE FUNCTION api.complete_parent_feature_when_stories_done();

-- Reconcile features that were already complete when this migration was
-- installed, including projects used to validate the worker loop.
DO $$
DECLARE feature_record api.work_items; done_stage_id uuid;
BEGIN
  FOR feature_record IN
    SELECT feature.* FROM api.work_items feature
    WHERE feature.kind = 'feature' AND feature.progress <> 'completed'
      AND EXISTS (SELECT 1 FROM api.work_items child WHERE child.parent_id = feature.id AND child.kind = 'story')
      AND NOT EXISTS (
        SELECT 1 FROM api.work_items child
        WHERE child.parent_id = feature.id AND child.kind = 'story'
          AND child.completed_at IS NULL AND child.progress <> 'completed'
      )
  LOOP
    SELECT id INTO done_stage_id FROM api.board_stages
    WHERE board_id = feature_record.board_id AND slug = 'done';
    UPDATE api.work_items SET stage_id = done_stage_id, progress = 'completed',
      execution_state = 'complete', completed_at = now()
    WHERE id = feature_record.id;
  END LOOP;
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

  analysis_recorded := EXISTS (SELECT 1 FROM api.work_item_evidence e WHERE e.work_item_id = item.id AND e.evidence_type = 'analysis' AND e.outcome IN ('recorded','passed','approved'));
  plan_recorded := EXISTS (SELECT 1 FROM api.work_item_evidence e WHERE e.work_item_id = item.id AND e.evidence_type = 'plan' AND e.outcome IN ('recorded','approved'));
  implementation_recorded := EXISTS (SELECT 1 FROM api.work_item_evidence e WHERE e.work_item_id = item.id AND e.evidence_type = 'implementation' AND e.outcome IN ('recorded','passed') AND e.revision IS NOT NULL);
  acceptance_passed := api.acceptance_criteria_passed_for_one_revision(item.acceptance_criteria);
  IF acceptance_passed THEN SELECT criterion->>'revision' INTO tested_revision FROM jsonb_array_elements(item.acceptance_criteria) criterion LIMIT 1; END IF;
  review_approved := tested_revision IS NOT NULL AND EXISTS (SELECT 1 FROM api.work_item_evidence e WHERE e.work_item_id = item.id AND e.evidence_type = 'review' AND e.outcome = 'approved' AND e.revision = tested_revision);
  SELECT merged.revision INTO merge_revision FROM api.work_item_evidence merged
  WHERE merged.work_item_id = item.id AND merged.evidence_type = 'merge' AND merged.outcome = 'merged'
    AND merged.details->>'reviewed_revision' = tested_revision ORDER BY merged.created_at DESC LIMIT 1;
  merge_recorded := merge_revision IS NOT NULL;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'requirement', constraint_record.title,
    'description', constraint_record.description,
    'policy', constraint_record.policy,
    'blocking', constraint_record.policy = 'required',
    'satisfied', CASE
      WHEN constraint_record.policy = 'waived' THEN true
      ELSE EXISTS (
        SELECT 1 FROM api.work_item_evidence evidence
        WHERE evidence.work_item_id = item.id
          AND evidence.evidence_type = constraint_record.evidence_type
          AND evidence.outcome = 'passed'
          AND evidence.revision = CASE WHEN constraint_record.evidence_type = 'regression' THEN merge_revision ELSE tested_revision END
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
    WHEN 'analyse' THEN jsonb_build_array(jsonb_build_object('requirement', 'Analysis evidence records context, constraints, risks, and dependency findings', 'satisfied', analysis_recorded, 'blocking', true))
    WHEN 'plan' THEN jsonb_build_array(jsonb_build_object('requirement', 'A bounded implementation and verification plan is recorded', 'satisfied', plan_recorded, 'blocking', true))
    WHEN 'build' THEN jsonb_build_array(jsonb_build_object('requirement', 'Implementation evidence identifies the exact revision to validate', 'satisfied', implementation_recorded, 'blocking', true))
    WHEN 'validate' THEN jsonb_build_array(jsonb_build_object('requirement', 'Every story acceptance criterion passes for the same exact revision', 'satisfied', acceptance_passed, 'revision', tested_revision, 'blocking', true))
    WHEN 'review' THEN jsonb_build_array(
      jsonb_build_object('requirement', 'Every child task is Done', 'satisfied', incomplete_task_count = 0, 'remaining', incomplete_task_count, 'blocking', true),
      jsonb_build_object('requirement', 'The accepted revision is approved in review', 'satisfied', review_approved, 'revision', tested_revision, 'blocking', true),
      jsonb_build_object('requirement', 'The approved code is merged successfully', 'satisfied', merge_recorded, 'revision', merge_revision, 'blocking', true)
    ) || quality_requirements
    ELSE '[]'::jsonb
  END;

  RETURN jsonb_build_object(
    'story', (to_jsonb(item) - 'acceptance_criteria' - 'invariants'),
    'tasks', child_tasks,
    'invariants', item.invariants,
    'story_acceptance_criteria', item.acceptance_criteria,
    'promotion', jsonb_build_object(
      'current_stage', jsonb_build_object('slug', current_stage.slug, 'title', current_stage.title, 'purpose', current_stage.purpose, 'entry_criteria', current_stage.entry_criteria, 'exit_criteria', current_stage.exit_criteria),
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

GRANT SELECT, INSERT, UPDATE, DELETE ON api.project_quality_constraints TO web_anon;
GRANT EXECUTE ON FUNCTION api.set_project_quality_constraint(uuid, text, text, text, text, text, text, text) TO web_anon;
GRANT EXECUTE ON FUNCTION api.record_work_item_evidence(uuid, text, text, text, text, text, text, jsonb) TO web_anon;
GRANT EXECUTE ON FUNCTION api.get_work_item_context(uuid) TO web_anon;

NOTIFY pgrst, 'reload schema';
