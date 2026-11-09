-- Make durable ownership distinct from the transient worker that currently
-- holds a claim. Multiple MCP clients can claim different ready stories in
-- parallel; PostgreSQL remains the authority for claim exclusivity.

BEGIN;

ALTER TABLE api.work_items
  ADD COLUMN IF NOT EXISTS owner text;

UPDATE api.work_items
SET owner = assignee
WHERE owner IS NULL
  AND NULLIF(btrim(assignee), '') IS NOT NULL
  AND EXISTS (
    SELECT 1 FROM api.projects project
    WHERE project.id = work_items.project_id AND project.status <> 'archived'
  );

DO $$ BEGIN
  ALTER TABLE api.work_items
    ADD CONSTRAINT work_items_owner_check
    CHECK (owner IS NULL OR (length(btrim(owner)) BETWEEN 1 AND 120));
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

CREATE OR REPLACE FUNCTION api.set_work_item_owner(
  target_work_item_id uuid,
  owner_name text,
  actor_name text DEFAULT 'You'
) RETURNS SETOF api.work_items
LANGUAGE plpgsql AS $$
DECLARE
  item api.work_items;
  previous_owner text;
  normalized_owner text := NULLIF(btrim(owner_name), '');
BEGIN
  SELECT * INTO item
  FROM api.work_items
  WHERE id = target_work_item_id
  FOR UPDATE;

  IF item.id IS NULL THEN
    RAISE EXCEPTION 'Work item not found.' USING ERRCODE = 'P0002';
  END IF;
  IF normalized_owner IS NOT NULL AND length(normalized_owner) > 120 THEN
    RAISE EXCEPTION 'Owner must not exceed 120 characters.' USING ERRCODE = '22001';
  END IF;

  previous_owner := item.owner;
  IF previous_owner IS NOT DISTINCT FROM normalized_owner THEN
    RETURN NEXT item;
    RETURN;
  END IF;

  UPDATE api.work_items
  SET owner = normalized_owner,
      updated_at = now()
  WHERE id = item.id
  RETURNING * INTO item;

  INSERT INTO api.activity_events(
    project_id, work_item_id, event_type, actor_type, actor_name, summary, details
  ) VALUES (
    item.project_id,
    item.id,
    'work_item.owner_changed',
    CASE WHEN actor_name = 'You' THEN 'human' ELSE 'agent' END,
    actor_name,
    CASE
      WHEN normalized_owner IS NULL THEN 'Cleared owner for ' || item.item_key
      ELSE 'Assigned ' || item.item_key || ' to ' || normalized_owner
    END,
    jsonb_build_object('previous_owner', previous_owner, 'owner', normalized_owner)
  );

  RETURN NEXT item;
END $$;

-- Recreate the view because SELECT w.* was expanded before owner existed.
DROP VIEW IF EXISTS api.agent_ready_stories;
CREATE VIEW api.agent_ready_stories AS
SELECT w.*,
  count(d.depends_on_work_item_id)::integer AS prerequisite_count,
  count(d.depends_on_work_item_id) FILTER (
    WHERE prerequisite.completed_at IS NULL AND prerequisite.progress <> 'completed'
  )::integer AS incomplete_prerequisite_count
FROM api.work_items w
LEFT JOIN api.work_item_dependencies d
  ON d.work_item_id = w.id
  OR (w.parent_id IS NOT NULL AND d.work_item_id = w.parent_id)
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

CREATE OR REPLACE VIEW api.project_owner_summary AS
SELECT
  project_id,
  owner,
  count(*) FILTER (WHERE archived_at IS NULL)::integer AS owned_items,
  count(*) FILTER (
    WHERE archived_at IS NULL AND execution_state = 'running'
  )::integer AS running_items,
  count(*) FILTER (
    WHERE archived_at IS NULL
      AND execution_state IN ('blocked', 'failed', 'waiting_for_human')
  )::integer AS blocked_items,
  count(*) FILTER (
    WHERE archived_at IS NULL AND progress = 'completed'
  )::integer AS completed_items
FROM api.work_items
WHERE owner IS NOT NULL
GROUP BY project_id, owner;

CREATE OR REPLACE FUNCTION api.claim_next_ready_work_item(
  target_project_id uuid,
  agent_name text
) RETURNS SETOF api.work_items
LANGUAGE plpgsql AS $$
DECLARE
  item api.work_items;
  normalized_agent text := btrim(agent_name);
BEGIN
  IF normalized_agent = '' OR normalized_agent IS NULL THEN
    RAISE EXCEPTION 'A claim requires a worker name.' USING ERRCODE = '23514';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM api.projects
    WHERE id = target_project_id AND status <> 'archived'
  ) THEN
    RETURN;
  END IF;

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
        AND prerequisite.completed_at IS NULL
        AND prerequisite.progress <> 'completed'
    )
  ORDER BY
    CASE
      WHEN lower(COALESCE(w.owner, '')) = lower(normalized_agent) THEN 0
      WHEN w.owner IS NULL THEN 1
      ELSE 2
    END,
    CASE w.priority
      WHEN 'urgent' THEN 0 WHEN 'high' THEN 1
      WHEN 'medium' THEN 2 WHEN 'low' THEN 3 ELSE 4
    END,
    w.created_at,
    w.id
  LIMIT 1
  FOR UPDATE OF w SKIP LOCKED;

  IF item.id IS NULL THEN RETURN; END IF;

  UPDATE api.work_items
  SET owner = COALESCE(owner, normalized_agent),
      assignee = normalized_agent,
      execution_state = 'running',
      blocked_reason = NULL,
      updated_at = now()
  WHERE id = item.id
  RETURNING * INTO item;

  INSERT INTO api.activity_events(
    project_id, work_item_id, event_type, actor_type, actor_name, summary, details
  ) VALUES (
    item.project_id, item.id, 'work_item.claimed', 'agent', normalized_agent,
    'Claimed next ready work item ' || item.item_key,
    jsonb_build_object('owner', item.owner, 'worker', normalized_agent)
  );

  RETURN NEXT item;
END $$;

CREATE OR REPLACE FUNCTION api.claim_work_item(
  target_work_item_id uuid,
  agent_name text
) RETURNS SETOF api.work_items
LANGUAGE plpgsql AS $$
DECLARE
  item api.work_items;
  normalized_agent text := btrim(agent_name);
BEGIN
  IF normalized_agent = '' OR normalized_agent IS NULL THEN
    RAISE EXCEPTION 'A claim requires a worker name.' USING ERRCODE = '23514';
  END IF;

  SELECT * INTO item FROM api.work_items WHERE id = target_work_item_id FOR UPDATE;
  IF item.id IS NULL THEN RAISE EXCEPTION 'Work item not found.' USING ERRCODE = 'P0002'; END IF;
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

  UPDATE api.work_items
  SET owner = COALESCE(owner, normalized_agent),
      assignee = normalized_agent,
      execution_state = 'running',
      blocked_reason = NULL,
      updated_at = now()
  WHERE id = item.id
  RETURNING * INTO item;

  INSERT INTO api.activity_events(
    project_id, work_item_id, event_type, actor_type, actor_name, summary, details
  ) VALUES (
    item.project_id, item.id, 'work_item.claimed', 'agent', normalized_agent,
    'Claimed ' || item.item_key || ' for agent work',
    jsonb_build_object('owner', item.owner, 'worker', normalized_agent)
  );

  RETURN NEXT item;
END $$;

CREATE OR REPLACE FUNCTION api.block_work_item(
  target_work_item_id uuid,
  agent_name text,
  reason text
) RETURNS SETOF api.work_items
LANGUAGE plpgsql AS $$
DECLARE item api.work_items;
BEGIN
  IF btrim(COALESCE(reason, '')) = '' THEN
    RAISE EXCEPTION 'A blocked work item requires a reason.' USING ERRCODE = '23514';
  END IF;
  SELECT * INTO item FROM api.work_items WHERE id = target_work_item_id FOR UPDATE;
  IF item.id IS NULL THEN RAISE EXCEPTION 'Work item not found.' USING ERRCODE = 'P0002'; END IF;
  IF item.execution_state IS DISTINCT FROM 'running'
     OR lower(COALESCE(item.assignee, '')) <> lower(btrim(agent_name)) THEN
    RAISE EXCEPTION 'Only the active worker % can block this item.', COALESCE(item.assignee, '(none)')
      USING ERRCODE = '23514';
  END IF;

  UPDATE api.work_items
  SET execution_state = 'blocked', blocked_reason = reason, assignee = NULL, updated_at = now()
  WHERE id = item.id RETURNING * INTO item;

  INSERT INTO api.activity_events(project_id, work_item_id, event_type, actor_type, actor_name, summary, details)
  VALUES (item.project_id, item.id, 'work_item.blocked', 'agent', btrim(agent_name),
    'Blocked ' || item.item_key || ': ' || reason, jsonb_build_object('reason', reason, 'owner', item.owner));
  RETURN NEXT item;
END $$;

CREATE OR REPLACE FUNCTION api.release_work_item(
  target_work_item_id uuid,
  agent_name text,
  reason text DEFAULT NULL
) RETURNS SETOF api.work_items
LANGUAGE plpgsql AS $$
DECLARE item api.work_items;
BEGIN
  SELECT * INTO item FROM api.work_items WHERE id = target_work_item_id FOR UPDATE;
  IF item.id IS NULL THEN RAISE EXCEPTION 'Work item not found.' USING ERRCODE = 'P0002'; END IF;
  IF item.execution_state IS DISTINCT FROM 'running'
     OR lower(COALESCE(item.assignee, '')) <> lower(btrim(agent_name)) THEN
    RAISE EXCEPTION 'Only the active worker % can release this item.', COALESCE(item.assignee, '(none)')
      USING ERRCODE = '23514';
  END IF;

  UPDATE api.work_items
  SET execution_state = 'queued', blocked_reason = NULL, assignee = NULL, updated_at = now()
  WHERE id = item.id RETURNING * INTO item;

  INSERT INTO api.activity_events(project_id, work_item_id, event_type, actor_type, actor_name, summary, details)
  VALUES (item.project_id, item.id, 'work_item.released', 'agent', btrim(agent_name),
    'Released ' || item.item_key || ' back to the ready queue',
    jsonb_build_object('reason', COALESCE(reason, ''), 'owner', item.owner));
  RETURN NEXT item;
END $$;

GRANT SELECT ON api.agent_ready_stories, api.project_owner_summary TO web_anon;
GRANT EXECUTE ON FUNCTION api.set_work_item_owner(uuid, text, text) TO web_anon;
GRANT EXECUTE ON FUNCTION api.claim_next_ready_work_item(uuid, text) TO web_anon;
GRANT EXECUTE ON FUNCTION api.claim_work_item(uuid, text) TO web_anon;
GRANT EXECUTE ON FUNCTION api.block_work_item(uuid, text, text) TO web_anon;
GRANT EXECUTE ON FUNCTION api.release_work_item(uuid, text, text) TO web_anon;

NOTIFY pgrst, 'reload schema';

COMMIT;
