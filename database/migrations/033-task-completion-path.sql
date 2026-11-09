-- Child tasks are operational sub-items of a governed story, not independent
-- software stories. Give them one narrow, idempotent completion path that
-- updates every state field consumed by story promotion gates.

BEGIN;

CREATE OR REPLACE FUNCTION api.complete_task(
  target_task_id uuid,
  actor_name text DEFAULT 'AI agent',
  completion_summary text DEFAULT NULL
) RETURNS SETOF api.work_items
LANGUAGE plpgsql AS $$
DECLARE
  task api.work_items;
BEGIN
  SELECT * INTO task FROM api.work_items WHERE id = target_task_id FOR UPDATE;
  IF task.id IS NULL THEN
    RAISE EXCEPTION 'Task not found.' USING ERRCODE = 'P0002';
  END IF;
  IF task.kind <> 'task' OR task.parent_id IS NULL THEN
    RAISE EXCEPTION 'Only a child task can use the task completion path.' USING ERRCODE = '23514';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM api.work_items story
    WHERE story.id = task.parent_id AND story.kind = 'story'
  ) THEN
    RAISE EXCEPTION 'Task parent must be a story.' USING ERRCODE = '23514';
  END IF;

  IF task.progress = 'completed' AND task.completed_at IS NOT NULL
     AND task.execution_state = 'complete' THEN
    RETURN NEXT task;
    RETURN;
  END IF;

  UPDATE api.work_items SET
    progress = 'completed',
    execution_state = 'complete',
    blocked_reason = NULL,
    completed_at = COALESCE(completed_at, now())
  WHERE id = task.id
  RETURNING * INTO task;

  INSERT INTO api.activity_events(
    project_id, work_item_id, event_type, actor_type, actor_name, summary, details
  ) VALUES (
    task.project_id,
    task.id,
    'task.completed',
    CASE WHEN actor_name = 'You' THEN 'human' ELSE 'agent' END,
    actor_name,
    COALESCE(completion_summary, 'Completed task ' || task.item_key),
    jsonb_build_object('parent_story_id', task.parent_id)
  );

  RETURN NEXT task;
END $$;

-- Repair task records completed through the previously exposed generic
-- execution-state update. This immediately unblocks their parent stories.
UPDATE api.work_items
SET progress = 'completed',
    blocked_reason = NULL,
    completed_at = COALESCE(completed_at, updated_at, now())
WHERE kind = 'task'
  AND execution_state = 'complete'
  AND (progress <> 'completed' OR completed_at IS NULL);

GRANT EXECUTE ON FUNCTION api.complete_task(uuid, text, text) TO web_anon;

NOTIFY pgrst, 'reload schema';

COMMIT;
