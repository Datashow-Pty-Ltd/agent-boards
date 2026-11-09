-- Work-item discussion is part of the durable delivery record. Comments are
-- deliberately separate from evidence: a progress note or clarification can
-- explain the work without pretending to satisfy a delivery gate.

CREATE INDEX IF NOT EXISTS work_item_comments_item_idx
  ON api.work_item_comments(work_item_id, created_at ASC);

CREATE OR REPLACE FUNCTION api.add_work_item_comment(
  target_work_item_id uuid,
  comment_body text,
  actor_name text,
  target_actor_type text DEFAULT 'human'
) RETURNS SETOF api.work_item_comments
LANGUAGE plpgsql AS $$
DECLARE item api.work_items; comment_record api.work_item_comments;
BEGIN
  SELECT * INTO item FROM api.work_items WHERE id = target_work_item_id;
  IF item.id IS NULL THEN RAISE EXCEPTION 'Work item not found.'; END IF;
  IF btrim(COALESCE(comment_body, '')) = '' THEN
    RAISE EXCEPTION 'A comment cannot be empty.' USING ERRCODE = '23514';
  END IF;
  IF target_actor_type NOT IN ('human', 'agent', 'system') THEN
    RAISE EXCEPTION 'Unsupported comment actor type: %', target_actor_type USING ERRCODE = '23514';
  END IF;

  INSERT INTO api.work_item_comments(work_item_id, actor_type, actor_name, body)
  VALUES (item.id, target_actor_type, actor_name, btrim(comment_body))
  RETURNING * INTO comment_record;

  INSERT INTO api.activity_events(
    project_id, work_item_id, event_type, actor_type, actor_name, summary, details
  ) VALUES (
    item.project_id, item.id, 'work_item.commented', target_actor_type, actor_name,
    CASE WHEN target_actor_type = 'agent'
      THEN 'Agent added a progress note to ' || item.item_key
      ELSE actor_name || ' commented on ' || item.item_key
    END,
    jsonb_build_object('comment_id', comment_record.id)
  );

  RETURN NEXT comment_record;
END $$;

GRANT SELECT, INSERT ON api.work_item_comments TO web_anon;
GRANT EXECUTE ON FUNCTION api.add_work_item_comment(uuid, text, text, text) TO web_anon;

NOTIFY pgrst, 'reload schema';
