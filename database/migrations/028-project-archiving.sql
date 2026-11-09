-- Make project archiving a reversible operational state. Archived projects
-- remain inspectable, but cannot accept work until they are restored.

BEGIN;

ALTER TABLE api.projects
  ADD COLUMN IF NOT EXISTS archived_at timestamptz,
  ADD COLUMN IF NOT EXISTS status_before_archive text;

DO $$ BEGIN
  ALTER TABLE api.projects
    ADD CONSTRAINT projects_status_before_archive_check
    CHECK (status_before_archive IS NULL OR status_before_archive IN ('draft', 'active', 'paused', 'completed'));
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

CREATE OR REPLACE FUNCTION api.archive_project(
  target_project_id uuid,
  actor_name text DEFAULT 'You'
) RETURNS SETOF api.projects
LANGUAGE plpgsql AS $$
DECLARE project_record api.projects;
BEGIN
  SELECT * INTO project_record
  FROM api.projects
  WHERE id = target_project_id
  FOR UPDATE;

  IF project_record.id IS NULL THEN
    RAISE EXCEPTION 'Project not found.' USING ERRCODE = 'P0002';
  END IF;

  IF project_record.status = 'archived' THEN
    RETURN NEXT project_record;
    RETURN;
  END IF;

  UPDATE api.projects
  SET status_before_archive = project_record.status,
      status = 'archived',
      archived_at = now()
  WHERE id = project_record.id
  RETURNING * INTO project_record;

  INSERT INTO api.activity_events(
    project_id, event_type, actor_type, actor_name, summary, details
  ) VALUES (
    project_record.id,
    'project.archived',
    'human',
    actor_name,
    'Archived project ' || project_record.project_key,
    jsonb_build_object('previous_status', project_record.status_before_archive)
  );

  RETURN NEXT project_record;
END $$;

CREATE OR REPLACE FUNCTION api.restore_project(
  target_project_id uuid,
  actor_name text DEFAULT 'You'
) RETURNS SETOF api.projects
LANGUAGE plpgsql AS $$
DECLARE project_record api.projects;
DECLARE restored_status text;
BEGIN
  SELECT * INTO project_record
  FROM api.projects
  WHERE id = target_project_id
  FOR UPDATE;

  IF project_record.id IS NULL THEN
    RAISE EXCEPTION 'Project not found.' USING ERRCODE = 'P0002';
  END IF;

  IF project_record.status <> 'archived' THEN
    RETURN NEXT project_record;
    RETURN;
  END IF;

  restored_status := COALESCE(project_record.status_before_archive, 'active');

  UPDATE api.projects
  SET status = restored_status,
      status_before_archive = NULL,
      archived_at = NULL
  WHERE id = project_record.id
  RETURNING * INTO project_record;

  INSERT INTO api.activity_events(
    project_id, event_type, actor_type, actor_name, summary, details
  ) VALUES (
    project_record.id,
    'project.restored',
    'human',
    actor_name,
    'Restored project ' || project_record.project_key,
    jsonb_build_object('restored_status', restored_status)
  );

  RETURN NEXT project_record;
END $$;

CREATE OR REPLACE FUNCTION api.prevent_archived_project_work_changes() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE target_project_id uuid;
DECLARE project_status text;
BEGIN
  target_project_id := CASE WHEN TG_OP = 'DELETE' THEN OLD.project_id ELSE NEW.project_id END;
  SELECT status INTO project_status FROM api.projects WHERE id = target_project_id;

  IF project_status = 'archived' THEN
    RAISE EXCEPTION 'Archived projects are read-only. Restore the project before changing its work.'
      USING ERRCODE = '23514';
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS prevent_archived_project_work_changes ON api.work_items;
CREATE TRIGGER prevent_archived_project_work_changes
  BEFORE INSERT OR UPDATE OR DELETE ON api.work_items
  FOR EACH ROW EXECUTE FUNCTION api.prevent_archived_project_work_changes();

-- Return no work for an archived project instead of letting a later update fail.
CREATE OR REPLACE FUNCTION api.claim_next_ready_work_item(
  target_project_id uuid,
  agent_name text
) RETURNS SETOF api.work_items
LANGUAGE plpgsql AS $$
DECLARE item api.work_items;
BEGIN
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
        AND prerequisite.completed_at IS NULL AND prerequisite.progress <> 'completed'
    )
  ORDER BY CASE w.priority WHEN 'urgent' THEN 0 WHEN 'high' THEN 1 WHEN 'medium' THEN 2 WHEN 'low' THEN 3 ELSE 4 END,
    w.created_at, w.id
  LIMIT 1 FOR UPDATE OF w SKIP LOCKED;

  IF item.id IS NULL THEN RETURN; END IF;

  UPDATE api.work_items
  SET assignee = agent_name, execution_state = 'running', blocked_reason = NULL
  WHERE id = item.id
  RETURNING * INTO item;

  INSERT INTO api.activity_events(project_id, work_item_id, event_type, actor_type, actor_name, summary)
  VALUES (item.project_id, item.id, 'work_item.claimed', 'agent', agent_name,
    'Claimed next ready work item ' || item.item_key);

  RETURN NEXT item;
END $$;

GRANT EXECUTE ON FUNCTION api.archive_project(uuid, text) TO web_anon;
GRANT EXECUTE ON FUNCTION api.restore_project(uuid, text) TO web_anon;

COMMIT;

NOTIFY pgrst, 'reload schema';
