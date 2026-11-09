-- Visual evidence is often supplied after an agent has blocked a story at a
-- promotion gate. Re-evaluate that gate as part of the attachment transaction
-- and return the story to the ready queue only when every blocking requirement
-- for its current stage is now satisfied.

CREATE OR REPLACE FUNCTION api.requeue_work_item_when_gate_ready(
  target_work_item_id uuid,
  actor_name text DEFAULT 'Agent Boards'
) RETURNS SETOF api.work_items
LANGUAGE plpgsql AS $$
DECLARE
  item api.work_items;
  context jsonb;
  current_stage text;
  previous_reason text;
BEGIN
  SELECT * INTO item
  FROM api.work_items
  WHERE id = target_work_item_id
  FOR UPDATE;

  IF item.id IS NULL THEN
    RAISE EXCEPTION 'Work item not found.';
  END IF;

  IF item.execution_state NOT IN ('blocked', 'waiting_for_human') THEN
    RETURN NEXT item;
    RETURN;
  END IF;

  context := api.get_work_item_context_with_visuals(item.id);
  IF NOT COALESCE((context #>> '{promotion,ready}')::boolean, false) THEN
    RETURN NEXT item;
    RETURN;
  END IF;

  current_stage := context #>> '{promotion,current_stage,slug}';
  previous_reason := item.blocked_reason;

  UPDATE api.work_items
  SET execution_state = 'queued',
      blocked_reason = NULL,
      assignee = NULL
  WHERE id = item.id
  RETURNING * INTO item;

  INSERT INTO api.activity_events(
    project_id, work_item_id, event_type, actor_type, actor_name, summary, details
  ) VALUES (
    item.project_id,
    item.id,
    'work_item.gate_reopened',
    CASE WHEN actor_name = 'You' THEN 'human' ELSE 'system' END,
    actor_name,
    'Reopened ' || item.item_key || ' after its ' || COALESCE(current_stage, 'current') || ' gate became ready',
    jsonb_build_object(
      'stage', current_stage,
      'previous_reason', previous_reason,
      'execution_state', 'queued'
    )
  );

  RETURN NEXT item;
END $$;

CREATE OR REPLACE FUNCTION api.re_evaluate_visual_gate_after_asset_attachment()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM api.requeue_work_item_when_gate_ready(NEW.work_item_id, NEW.created_by);
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS re_evaluate_visual_gate_after_asset_attachment ON api.work_item_assets;
CREATE CONSTRAINT TRIGGER re_evaluate_visual_gate_after_asset_attachment
  AFTER INSERT ON api.work_item_assets
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION api.re_evaluate_visual_gate_after_asset_attachment();

GRANT EXECUTE ON FUNCTION api.requeue_work_item_when_gate_ready(uuid, text) TO web_anon;

NOTIFY pgrst, 'reload schema';
