-- Make the agent worker contract a single atomic queue operation. A worker
-- claims one dependency-ready story, advances it through the governed board,
-- then claims again after completing or blocking it.

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
  ON d.work_item_id = w.id
  OR (w.parent_id IS NOT NULL AND d.work_item_id = w.parent_id)
LEFT JOIN api.work_items prerequisite ON prerequisite.id = d.depends_on_work_item_id
WHERE w.kind = 'story'
  AND w.archived_at IS NULL
  AND w.completed_at IS NULL
  AND w.progress <> 'completed'
  AND COALESCE(w.execution_state, 'queued') = 'queued'
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
    AND NOT EXISTS (
      SELECT 1
      FROM api.work_item_dependencies d
      JOIN api.work_items prerequisite ON prerequisite.id = d.depends_on_work_item_id
      WHERE (d.work_item_id = w.id OR (w.parent_id IS NOT NULL AND d.work_item_id = w.parent_id))
        AND prerequisite.completed_at IS NULL
        AND prerequisite.progress <> 'completed'
    )
  ORDER BY
    CASE w.priority
      WHEN 'urgent' THEN 0
      WHEN 'high' THEN 1
      WHEN 'medium' THEN 2
      WHEN 'low' THEN 3
      ELSE 4
    END,
    w.created_at,
    w.id
  LIMIT 1
  FOR UPDATE OF w SKIP LOCKED;

  IF item.id IS NULL THEN
    RETURN;
  END IF;

  UPDATE api.work_items
  SET assignee = agent_name,
      execution_state = 'running',
      blocked_reason = NULL
  WHERE id = item.id
  RETURNING * INTO item;

  INSERT INTO api.activity_events(
    project_id, work_item_id, event_type, actor_type, actor_name, summary
  ) VALUES (
    item.project_id, item.id, 'work_item.claimed', 'agent', agent_name,
    'Claimed next ready work item ' || item.item_key
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
  IF item.id IS NULL THEN RAISE EXCEPTION 'Work item not found.'; END IF;
  IF item.completed_at IS NOT NULL OR item.progress = 'completed' THEN
    RAISE EXCEPTION 'Completed work cannot be blocked.' USING ERRCODE = '23514';
  END IF;

  UPDATE api.work_items
  SET execution_state = 'blocked',
      blocked_reason = reason,
      assignee = NULL
  WHERE id = item.id
  RETURNING * INTO item;

  INSERT INTO api.activity_events(
    project_id, work_item_id, event_type, actor_type, actor_name, summary, details
  ) VALUES (
    item.project_id, item.id, 'work_item.blocked', 'agent', agent_name,
    'Blocked ' || item.item_key || ': ' || reason,
    jsonb_build_object('reason', reason)
  );

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
  IF item.id IS NULL THEN RAISE EXCEPTION 'Work item not found.'; END IF;
  IF item.execution_state IS DISTINCT FROM 'running' THEN
    RAISE EXCEPTION 'Only running work can be released.' USING ERRCODE = '23514';
  END IF;

  UPDATE api.work_items
  SET execution_state = 'queued',
      blocked_reason = NULL,
      assignee = NULL
  WHERE id = item.id
  RETURNING * INTO item;

  INSERT INTO api.activity_events(
    project_id, work_item_id, event_type, actor_type, actor_name, summary, details
  ) VALUES (
    item.project_id, item.id, 'work_item.released', 'agent', agent_name,
    'Released ' || item.item_key || ' back to the ready queue',
    jsonb_build_object('reason', COALESCE(reason, ''))
  );

  RETURN NEXT item;
END $$;

GRANT SELECT ON api.agent_ready_stories TO web_anon;
GRANT EXECUTE ON FUNCTION api.claim_next_ready_work_item(uuid, text) TO web_anon;
GRANT EXECUTE ON FUNCTION api.block_work_item(uuid, text, text) TO web_anon;
GRANT EXECUTE ON FUNCTION api.release_work_item(uuid, text, text) TO web_anon;

NOTIFY pgrst, 'reload schema';
