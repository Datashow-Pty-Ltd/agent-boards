CREATE INDEX IF NOT EXISTS work_item_dependencies_prerequisite_idx
  ON api.work_item_dependencies(depends_on_work_item_id);
CREATE INDEX IF NOT EXISTS work_items_parent_idx
  ON api.work_items(parent_id, kind);

CREATE OR REPLACE FUNCTION api.validate_work_item_parent() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE parent_item api.work_items;
BEGIN
  IF NEW.kind = 'feature' THEN
    IF NEW.parent_id IS NOT NULL THEN
      RAISE EXCEPTION 'A feature cannot have a parent work item.' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.parent_id IS NULL THEN
    IF NEW.kind = 'task' THEN
      RAISE EXCEPTION 'A task must belong to a story.' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
  END IF;

  SELECT * INTO parent_item FROM api.work_items WHERE id = NEW.parent_id;
  IF parent_item.id IS NULL OR parent_item.project_id <> NEW.project_id THEN
    RAISE EXCEPTION 'Parent work item must exist in the same project.' USING ERRCODE = '23514';
  END IF;
  IF NEW.kind = 'story' AND parent_item.kind <> 'feature' THEN
    RAISE EXCEPTION 'A story parent must be a feature.' USING ERRCODE = '23514';
  END IF;
  IF NEW.kind = 'task' AND parent_item.kind <> 'story' THEN
    RAISE EXCEPTION 'A task parent must be a story.' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS validate_work_item_parent ON api.work_items;
CREATE TRIGGER validate_work_item_parent
  BEFORE INSERT OR UPDATE OF parent_id, kind, project_id ON api.work_items
  FOR EACH ROW EXECUTE FUNCTION api.validate_work_item_parent();

CREATE OR REPLACE FUNCTION api.validate_work_item_dependency() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE item api.work_items; prerequisite api.work_items;
BEGIN
  SELECT * INTO item FROM api.work_items WHERE id = NEW.work_item_id;
  SELECT * INTO prerequisite FROM api.work_items WHERE id = NEW.depends_on_work_item_id;
  IF item.id IS NULL OR prerequisite.id IS NULL OR item.project_id <> prerequisite.project_id THEN
    RAISE EXCEPTION 'A prerequisite must exist in the same project.' USING ERRCODE = '23514';
  END IF;
  IF item.kind NOT IN ('feature', 'story') OR prerequisite.kind <> item.kind THEN
    RAISE EXCEPTION 'Dependencies must connect two stories or two features.' USING ERRCODE = '23514';
  END IF;
  IF EXISTS (
    WITH RECURSIVE chain(id) AS (
      SELECT d.depends_on_work_item_id FROM api.work_item_dependencies d WHERE d.work_item_id = NEW.depends_on_work_item_id
      UNION
      SELECT d.depends_on_work_item_id FROM api.work_item_dependencies d JOIN chain c ON d.work_item_id = c.id
    )
    SELECT 1 FROM chain WHERE id = NEW.work_item_id
  ) THEN
    RAISE EXCEPTION 'Dependency would create a cycle.' USING ERRCODE = '23514';
  END IF;
  IF item.execution_state = 'running' AND prerequisite.completed_at IS NULL AND prerequisite.progress <> 'completed' THEN
    RAISE EXCEPTION 'Cannot add an incomplete prerequisite to work already running.' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS validate_work_item_dependency ON api.work_item_dependencies;
CREATE TRIGGER validate_work_item_dependency
  BEFORE INSERT OR UPDATE ON api.work_item_dependencies
  FOR EACH ROW EXECUTE FUNCTION api.validate_work_item_dependency();

CREATE OR REPLACE FUNCTION api.enforce_ready_before_running() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.execution_state = 'running'
     AND (OLD.execution_state IS DISTINCT FROM 'running' OR NEW.assignee IS DISTINCT FROM OLD.assignee)
     AND EXISTS (
       SELECT 1
       FROM api.work_item_dependencies d
       JOIN api.work_items prerequisite ON prerequisite.id = d.depends_on_work_item_id
       WHERE (d.work_item_id = NEW.id OR (NEW.kind = 'story' AND NEW.parent_id IS NOT NULL AND d.work_item_id = NEW.parent_id))
         AND prerequisite.completed_at IS NULL
         AND prerequisite.progress <> 'completed'
     ) THEN
    RAISE EXCEPTION 'Work item cannot run until every prerequisite is Done.'
      USING ERRCODE = '23514', HINT = 'Complete the prerequisite work or select another ready story.';
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS enforce_ready_before_running ON api.work_items;
CREATE TRIGGER enforce_ready_before_running
  BEFORE UPDATE OF execution_state, assignee ON api.work_items
  FOR EACH ROW EXECUTE FUNCTION api.enforce_ready_before_running();

CREATE OR REPLACE FUNCTION api.set_work_item_dependencies(
  target_work_item_id uuid,
  prerequisite_ids uuid[] DEFAULT '{}'::uuid[]
) RETURNS SETOF api.work_item_dependencies
LANGUAGE plpgsql AS $$
BEGIN
  DELETE FROM api.work_item_dependencies WHERE work_item_id = target_work_item_id;
  INSERT INTO api.work_item_dependencies(work_item_id, depends_on_work_item_id)
  SELECT target_work_item_id, prerequisite_id
  FROM unnest(COALESCE(prerequisite_ids, '{}'::uuid[])) prerequisite_id;
  RETURN QUERY SELECT * FROM api.work_item_dependencies WHERE work_item_id = target_work_item_id ORDER BY created_at;
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
  IF item.execution_state = 'running' THEN
    RAISE EXCEPTION 'Story is already being worked by %.', COALESCE(item.assignee, 'another agent') USING ERRCODE = '23514';
  END IF;
  IF EXISTS (
    SELECT 1 FROM api.work_item_dependencies d
    JOIN api.work_items prerequisite ON prerequisite.id = d.depends_on_work_item_id
    WHERE (d.work_item_id = item.id OR (item.parent_id IS NOT NULL AND d.work_item_id = item.parent_id))
      AND prerequisite.completed_at IS NULL
      AND prerequisite.progress <> 'completed'
  ) THEN
    RAISE EXCEPTION 'Story has incomplete prerequisites and cannot be claimed.'
      USING ERRCODE = '23514', HINT = 'Use agent_ready_stories to select eligible work.';
  END IF;
  UPDATE api.work_items SET assignee = agent_name, execution_state = 'running'
  WHERE id = item.id RETURNING * INTO item;
  INSERT INTO api.activity_events(project_id, work_item_id, event_type, actor_type, actor_name, summary)
  VALUES (item.project_id, item.id, 'work_item.claimed', 'agent', agent_name, 'Claimed ' || item.item_key || ' for agent work');
  RETURN NEXT item;
END $$;

-- The view selects w.*, so adding a column to api.work_items changes the view's
-- ordinal column layout. PostgreSQL cannot reconcile that with CREATE OR
-- REPLACE VIEW on a subsequent stack start. Recreate the non-materialized view
-- explicitly; this does not remove any project data.
DROP VIEW IF EXISTS api.agent_ready_stories;
CREATE VIEW api.agent_ready_stories AS
SELECT w.*,
  count(d.depends_on_work_item_id)::integer AS prerequisite_count,
  count(d.depends_on_work_item_id) FILTER (
    WHERE prerequisite.completed_at IS NULL AND prerequisite.progress <> 'completed'
  )::integer AS incomplete_prerequisite_count
FROM api.work_items w
LEFT JOIN api.work_item_dependencies d ON d.work_item_id = w.id OR (w.parent_id IS NOT NULL AND d.work_item_id = w.parent_id)
LEFT JOIN api.work_items prerequisite ON prerequisite.id = d.depends_on_work_item_id
WHERE w.kind = 'story'
  AND w.archived_at IS NULL
  AND w.completed_at IS NULL
  AND w.progress <> 'completed'
  AND w.execution_state IS DISTINCT FROM 'running'
GROUP BY w.id
HAVING count(d.depends_on_work_item_id) FILTER (
  WHERE prerequisite.completed_at IS NULL AND prerequisite.progress <> 'completed'
) = 0;

CREATE OR REPLACE FUNCTION api.enforce_work_item_stage_transition() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE previous_stage api.board_stages; next_stage api.board_stages;
BEGIN
  IF NEW.stage_id = OLD.stage_id THEN RETURN NEW; END IF;
  SELECT * INTO previous_stage FROM api.board_stages WHERE id = OLD.stage_id;
  SELECT * INTO next_stage FROM api.board_stages WHERE id = NEW.stage_id;
  IF next_stage.id IS NULL OR next_stage.board_id <> OLD.board_id THEN
    RAISE EXCEPTION 'Target stage does not belong to this board.' USING ERRCODE = '23514';
  END IF;
  IF NOT (previous_stage.allowed_transitions ? next_stage.slug) THEN
    RAISE EXCEPTION 'Cannot move from % to %. Allowed next stages: %', previous_stage.title, next_stage.title,
      COALESCE((SELECT string_agg(value, ', ') FROM jsonb_array_elements_text(previous_stage.allowed_transitions)), 'none')
      USING ERRCODE = '23514', HINT = 'Move the card through each governed stage; completed work in Done is terminal.';
  END IF;
  IF next_stage.slug = 'done' AND OLD.kind = 'story' AND EXISTS (
    SELECT 1 FROM api.work_items child
    WHERE child.parent_id = OLD.id AND child.kind = 'task'
      AND child.completed_at IS NULL AND child.progress <> 'completed'
  ) THEN
    RAISE EXCEPTION 'Story cannot move to Done while it has incomplete tasks.'
      USING ERRCODE = '23514', HINT = 'Complete every task within the story first.';
  END IF;
  RETURN NEW;
END $$;

GRANT SELECT ON api.agent_ready_stories TO web_anon;
GRANT EXECUTE ON FUNCTION api.set_work_item_dependencies(uuid, uuid[]) TO web_anon;
GRANT EXECUTE ON FUNCTION api.claim_work_item(uuid, text) TO web_anon;

NOTIFY pgrst, 'reload schema';
