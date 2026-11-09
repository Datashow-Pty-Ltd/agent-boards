-- Stories are not eligible for agent work until their acceptance criteria are
-- executable or otherwise mechanically assertable. Results are tied to the
-- exact tested revision and become part of the delivery evidence record.

CREATE OR REPLACE FUNCTION api.acceptance_criteria_are_deterministic(criteria jsonb)
RETURNS boolean
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF jsonb_typeof(criteria) <> 'array' OR jsonb_array_length(criteria) = 0 THEN
    RETURN false;
  END IF;
  RETURN NOT EXISTS (
    SELECT 1
    FROM jsonb_array_elements(criteria) criterion
    WHERE jsonb_typeof(criterion) <> 'object'
      OR btrim(COALESCE(criterion->>'statement', '')) = ''
      OR COALESCE(criterion->>'verification_method', '') NOT IN (
        'automated_test', 'command', 'http_assertion', 'database_assertion', 'visual_baseline'
      )
      OR btrim(COALESCE(criterion->>'verification_ref', '')) = ''
      OR btrim(COALESCE(criterion->>'expected_result', '')) = ''
  );
END $$;

CREATE OR REPLACE FUNCTION api.normalize_acceptance_criteria(criteria jsonb)
RETURNS jsonb
LANGUAGE sql VOLATILE AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', COALESCE(NULLIF(criterion->>'id', ''), gen_random_uuid()::text),
    'statement', criterion->>'statement',
    'verification_method', criterion->>'verification_method',
    'verification_ref', criterion->>'verification_ref',
    'expected_result', criterion->>'expected_result',
    'status', 'pending',
    'revision', NULL,
    'evidence_id', NULL
  )), '[]'::jsonb)
  FROM jsonb_array_elements(COALESCE(criteria, '[]'::jsonb)) criterion
$$;

-- Preserve legacy prose so it remains visible, but mark it as unspecified.
-- It must be replaced by deterministic criteria before the story is eligible.
UPDATE api.work_items
SET acceptance_criteria = (
  SELECT COALESCE(jsonb_agg(
    CASE
      WHEN jsonb_typeof(criterion) = 'object' THEN criterion
      ELSE jsonb_build_object(
        'id', gen_random_uuid()::text,
        'statement', trim(both '"' from criterion::text),
        'verification_method', 'unspecified',
        'verification_ref', '',
        'expected_result', trim(both '"' from criterion::text),
        'status', 'pending',
        'revision', NULL,
        'evidence_id', NULL
      )
    END
  ), '[]'::jsonb)
  FROM jsonb_array_elements(api.work_items.acceptance_criteria) criterion
)
WHERE jsonb_typeof(acceptance_criteria) = 'array'
  AND EXISTS (
    SELECT 1 FROM jsonb_array_elements(acceptance_criteria) criterion
    WHERE jsonb_typeof(criterion) <> 'object'
  );

CREATE OR REPLACE FUNCTION api.create_backlog_item(
  target_project_id uuid,
  item_title text,
  item_description text DEFAULT '',
  item_kind text DEFAULT 'story',
  item_priority text DEFAULT 'medium',
  parent_work_item_id uuid DEFAULT NULL,
  item_assignee text DEFAULT NULL,
  item_acceptance_criteria jsonb DEFAULT '[]'::jsonb,
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

  normalized_criteria := CASE
    WHEN jsonb_array_length(COALESCE(item_acceptance_criteria, '[]'::jsonb)) > 0
      THEN api.normalize_acceptance_criteria(item_acceptance_criteria)
    ELSE '[]'::jsonb
  END;

  SELECT id INTO target_board FROM api.boards WHERE project_id = target_project_id;
  SELECT id INTO backlog_stage FROM api.board_stages WHERE board_id = target_board AND slug = 'backlog';
  INSERT INTO api.work_items(
    project_id, board_id, parent_id, stage_id, item_key, kind, title, description,
    priority, assignee, acceptance_criteria, position
  ) VALUES (
    target_project_id, target_board, parent_work_item_id, backlog_stage,
    api.allocate_item_key(target_project_id), item_kind, item_title, item_description,
    item_priority, item_assignee, normalized_criteria,
    COALESCE((SELECT max(position) + 1 FROM api.work_items WHERE stage_id = backlog_stage), 0)
  ) RETURNING * INTO item;
  INSERT INTO api.activity_events(project_id, work_item_id, event_type, actor_type, actor_name, summary, details)
  VALUES (
    target_project_id, item.id, 'work_item.created',
    CASE WHEN actor_name = 'You' THEN 'human' ELSE 'agent' END,
    actor_name, 'Created ' || item.item_key || ' in Backlog',
    jsonb_build_object('kind', item.kind, 'acceptance_criteria_count', jsonb_array_length(normalized_criteria))
  );
  RETURN NEXT item;
END $$;

CREATE OR REPLACE FUNCTION api.set_work_item_acceptance_criteria(
  target_work_item_id uuid,
  criteria jsonb,
  actor_name text DEFAULT 'You'
) RETURNS SETOF api.work_items
LANGUAGE plpgsql AS $$
DECLARE item api.work_items; stage api.board_stages;
BEGIN
  SELECT * INTO item FROM api.work_items WHERE id = target_work_item_id FOR UPDATE;
  IF item.id IS NULL THEN RAISE EXCEPTION 'Work item not found.'; END IF;
  IF item.kind <> 'story' THEN
    RAISE EXCEPTION 'Deterministic acceptance criteria are defined on stories.' USING ERRCODE = '23514';
  END IF;
  SELECT * INTO stage FROM api.board_stages WHERE id = item.stage_id;
  IF stage.slug NOT IN ('backlog', 'analyse', 'plan') THEN
    RAISE EXCEPTION 'Acceptance criteria cannot change after Build begins.' USING ERRCODE = '23514';
  END IF;
  IF NOT api.acceptance_criteria_are_deterministic(criteria) THEN
    RAISE EXCEPTION 'Every acceptance criterion must be deterministic.'
      USING ERRCODE = '23514',
        HINT = 'Provide statement, verification_method, verification_ref, and exact expected_result.';
  END IF;

  UPDATE api.work_items
  SET acceptance_criteria = api.normalize_acceptance_criteria(criteria)
  WHERE id = item.id
  RETURNING * INTO item;

  INSERT INTO api.activity_events(project_id, work_item_id, event_type, actor_type, actor_name, summary)
  VALUES (item.project_id, item.id, 'work_item.acceptance_defined',
    CASE WHEN actor_name = 'You' THEN 'human' ELSE 'agent' END,
    actor_name, 'Defined deterministic acceptance criteria for ' || item.item_key);
  RETURN NEXT item;
END $$;

CREATE OR REPLACE FUNCTION api.acceptance_criteria_passed_for_one_revision(criteria jsonb)
RETURNS boolean
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE total integer; revision_count integer; all_passed boolean;
BEGIN
  IF NOT api.acceptance_criteria_are_deterministic(criteria) THEN RETURN false; END IF;
  SELECT count(*), count(DISTINCT criterion->>'revision'),
    bool_and(criterion->>'status' = 'passed' AND btrim(COALESCE(criterion->>'revision', '')) <> '')
  INTO total, revision_count, all_passed
  FROM jsonb_array_elements(criteria) criterion;
  RETURN total > 0 AND revision_count = 1 AND all_passed;
END $$;

CREATE OR REPLACE FUNCTION api.record_acceptance_result(
  target_work_item_id uuid,
  criterion_id text,
  passed boolean,
  target_revision text,
  result_summary text,
  actor_name text,
  evidence_url text DEFAULT NULL,
  evidence_details jsonb DEFAULT '{}'::jsonb
) RETURNS SETOF api.work_items
LANGUAGE plpgsql AS $$
DECLARE item api.work_items; evidence api.work_item_evidence; updated_criteria jsonb;
BEGIN
  SELECT * INTO item FROM api.work_items WHERE id = target_work_item_id FOR UPDATE;
  IF item.id IS NULL THEN RAISE EXCEPTION 'Work item not found.'; END IF;
  IF item.kind <> 'story' THEN RAISE EXCEPTION 'Acceptance results belong to stories.' USING ERRCODE = '23514'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(item.acceptance_criteria) criterion
    WHERE criterion->>'id' = criterion_id
  ) THEN
    RAISE EXCEPTION 'Acceptance criterion not found.' USING ERRCODE = '23514';
  END IF;
  IF btrim(COALESCE(target_revision, '')) = '' THEN
    RAISE EXCEPTION 'Acceptance results require the exact tested revision.' USING ERRCODE = '23514';
  END IF;

  SELECT * INTO evidence FROM api.record_work_item_evidence(
    target_work_item_id, 'test', CASE WHEN passed THEN 'passed' ELSE 'failed' END,
    result_summary, actor_name, target_revision, evidence_url, evidence_details
  );

  SELECT jsonb_agg(
    CASE WHEN criterion->>'id' = criterion_id THEN
      criterion || jsonb_build_object(
        'status', CASE WHEN passed THEN 'passed' ELSE 'failed' END,
        'revision', target_revision,
        'evidence_id', evidence.id::text
      )
    ELSE criterion END
  ) INTO updated_criteria
  FROM jsonb_array_elements(item.acceptance_criteria) criterion;

  UPDATE api.work_items SET acceptance_criteria = updated_criteria
  WHERE id = item.id RETURNING * INTO item;
  RETURN NEXT item;
END $$;

-- Recreate because this view selects w.* and later migrations extend
-- api.work_items. CREATE OR REPLACE cannot change existing column ordinals.
DROP VIEW IF EXISTS api.agent_ready_stories;
CREATE VIEW api.agent_ready_stories AS
SELECT w.*,
  count(d.depends_on_work_item_id)::integer AS prerequisite_count,
  count(d.depends_on_work_item_id) FILTER (
    WHERE prerequisite.completed_at IS NULL AND prerequisite.progress <> 'completed'
  )::integer AS incomplete_prerequisite_count
FROM api.work_items w
LEFT JOIN api.work_item_dependencies d
  ON d.work_item_id = w.id OR (w.parent_id IS NOT NULL AND d.work_item_id = w.parent_id)
LEFT JOIN api.work_items prerequisite ON prerequisite.id = d.depends_on_work_item_id
WHERE w.kind = 'story'
  AND w.archived_at IS NULL
  AND w.completed_at IS NULL
  AND w.progress <> 'completed'
  AND COALESCE(w.execution_state, 'queued') = 'queued'
  AND api.acceptance_criteria_are_deterministic(w.acceptance_criteria)
GROUP BY w.id
HAVING count(d.depends_on_work_item_id) FILTER (
  WHERE prerequisite.completed_at IS NULL AND prerequisite.progress <> 'completed'
) = 0;

CREATE OR REPLACE FUNCTION api.claim_next_ready_work_item(
  target_project_id uuid,
  agent_name text
) RETURNS SETOF api.work_items
LANGUAGE plpgsql AS $$
DECLARE item api.work_items;
BEGIN
  SELECT w.* INTO item
  FROM api.work_items w
  WHERE w.project_id = target_project_id
    AND w.kind = 'story'
    AND w.archived_at IS NULL
    AND w.completed_at IS NULL
    AND w.progress <> 'completed'
    AND COALESCE(w.execution_state, 'queued') = 'queued'
    AND api.acceptance_criteria_are_deterministic(w.acceptance_criteria)
    AND NOT EXISTS (
      SELECT 1 FROM api.work_item_dependencies d
      JOIN api.work_items prerequisite ON prerequisite.id = d.depends_on_work_item_id
      WHERE (d.work_item_id = w.id OR (w.parent_id IS NOT NULL AND d.work_item_id = w.parent_id))
        AND prerequisite.completed_at IS NULL AND prerequisite.progress <> 'completed'
    )
  ORDER BY CASE w.priority WHEN 'urgent' THEN 0 WHEN 'high' THEN 1 WHEN 'medium' THEN 2 WHEN 'low' THEN 3 ELSE 4 END,
    w.created_at, w.id
  LIMIT 1 FOR UPDATE OF w SKIP LOCKED;
  IF item.id IS NULL THEN RETURN; END IF;
  UPDATE api.work_items SET assignee = agent_name, execution_state = 'running', blocked_reason = NULL
  WHERE id = item.id RETURNING * INTO item;
  INSERT INTO api.activity_events(project_id, work_item_id, event_type, actor_type, actor_name, summary)
  VALUES (item.project_id, item.id, 'work_item.claimed', 'agent', agent_name,
    'Claimed next ready work item ' || item.item_key);
  RETURN NEXT item;
END $$;

CREATE OR REPLACE FUNCTION api.claim_work_item(
  target_work_item_id uuid,
  agent_name text
) RETURNS SETOF api.work_items
LANGUAGE plpgsql AS $$
DECLARE item api.work_items;
BEGIN
  SELECT * INTO item FROM api.work_items WHERE id = target_work_item_id FOR UPDATE;
  IF item.id IS NULL THEN RAISE EXCEPTION 'Work item not found.'; END IF;
  IF item.kind <> 'story' THEN
    RAISE EXCEPTION 'Agents claim stories; tasks remain within their parent story.' USING ERRCODE = '23514';
  END IF;
  IF item.completed_at IS NOT NULL OR item.progress = 'completed' THEN
    RAISE EXCEPTION 'Completed work cannot be claimed.' USING ERRCODE = '23514';
  END IF;
  IF COALESCE(item.execution_state, 'queued') <> 'queued' THEN
    RAISE EXCEPTION 'Only queued work can be claimed; current state is %.', COALESCE(item.execution_state, 'queued')
      USING ERRCODE = '23514';
  END IF;
  IF NOT api.acceptance_criteria_are_deterministic(item.acceptance_criteria) THEN
    RAISE EXCEPTION 'Story cannot be claimed until deterministic acceptance criteria are defined.'
      USING ERRCODE = '23514';
  END IF;
  IF EXISTS (
    SELECT 1 FROM api.work_item_dependencies d
    JOIN api.work_items prerequisite ON prerequisite.id = d.depends_on_work_item_id
    WHERE (d.work_item_id = item.id OR (item.parent_id IS NOT NULL AND d.work_item_id = item.parent_id))
      AND prerequisite.completed_at IS NULL AND prerequisite.progress <> 'completed'
  ) THEN
    RAISE EXCEPTION 'Story has incomplete prerequisites and cannot be claimed.'
      USING ERRCODE = '23514', HINT = 'Use claim_next_ready_work_item to select eligible work.';
  END IF;
  UPDATE api.work_items SET assignee = agent_name, execution_state = 'running', blocked_reason = NULL
  WHERE id = item.id RETURNING * INTO item;
  INSERT INTO api.activity_events(project_id, work_item_id, event_type, actor_type, actor_name, summary)
  VALUES (item.project_id, item.id, 'work_item.claimed', 'agent', agent_name,
    'Claimed ' || item.item_key || ' for agent work');
  RETURN NEXT item;
END $$;

CREATE OR REPLACE FUNCTION api.enforce_ready_before_running() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.execution_state = 'running'
     AND (OLD.execution_state IS DISTINCT FROM 'running' OR NEW.assignee IS DISTINCT FROM OLD.assignee) THEN
    IF NEW.kind = 'story' AND NOT api.acceptance_criteria_are_deterministic(NEW.acceptance_criteria) THEN
      RAISE EXCEPTION 'Story cannot run until deterministic acceptance criteria are defined.'
        USING ERRCODE = '23514';
    END IF;
    IF EXISTS (
      SELECT 1 FROM api.work_item_dependencies d
      JOIN api.work_items prerequisite ON prerequisite.id = d.depends_on_work_item_id
      WHERE (d.work_item_id = NEW.id OR (NEW.kind = 'story' AND NEW.parent_id IS NOT NULL AND d.work_item_id = NEW.parent_id))
        AND prerequisite.completed_at IS NULL AND prerequisite.progress <> 'completed'
    ) THEN
      RAISE EXCEPTION 'Work item cannot run until every prerequisite is Done.'
        USING ERRCODE = '23514', HINT = 'Complete the prerequisite work or select another ready story.';
    END IF;
  END IF;
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION api.enforce_acceptance_criteria_gates() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE next_stage api.board_stages;
BEGIN
  IF NEW.stage_id = OLD.stage_id OR OLD.kind <> 'story' THEN RETURN NEW; END IF;
  SELECT * INTO next_stage FROM api.board_stages WHERE id = NEW.stage_id;
  IF next_stage.slug = 'analyse' AND NOT api.acceptance_criteria_are_deterministic(OLD.acceptance_criteria) THEN
    RAISE EXCEPTION 'Story cannot enter Analyse without deterministic acceptance criteria.' USING ERRCODE = '23514';
  END IF;
  IF next_stage.slug = 'review' AND NOT api.acceptance_criteria_passed_for_one_revision(OLD.acceptance_criteria) THEN
    RAISE EXCEPTION 'Story cannot enter Review until every acceptance criterion passes for the same revision.'
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS enforce_acceptance_criteria_gates ON api.work_items;
CREATE TRIGGER enforce_acceptance_criteria_gates
  BEFORE UPDATE OF stage_id ON api.work_items
  FOR EACH ROW EXECUTE FUNCTION api.enforce_acceptance_criteria_gates();

GRANT EXECUTE ON FUNCTION api.acceptance_criteria_are_deterministic(jsonb) TO web_anon;
GRANT EXECUTE ON FUNCTION api.set_work_item_acceptance_criteria(uuid, jsonb, text) TO web_anon;
GRANT EXECUTE ON FUNCTION api.record_acceptance_result(uuid, text, boolean, text, text, text, text, jsonb) TO web_anon;
GRANT EXECUTE ON FUNCTION api.claim_work_item(uuid, text) TO web_anon;

NOTIFY pgrst, 'reload schema';
