-- Treat active claims as renewable leases. Agents keep their lease current with
-- heartbeats; only a human may transfer or release a claim after its project
-- idle threshold has elapsed.

BEGIN;

ALTER TABLE api.projects
  ADD COLUMN IF NOT EXISTS claim_idle_timeout_minutes integer NOT NULL DEFAULT 15;

DO $$ BEGIN
  ALTER TABLE api.projects
    ADD CONSTRAINT projects_claim_idle_timeout_check
    CHECK (claim_idle_timeout_minutes BETWEEN 5 AND 1440);
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

ALTER TABLE api.work_items
  ADD COLUMN IF NOT EXISTS claim_started_at timestamptz,
  ADD COLUMN IF NOT EXISTS claim_heartbeat_at timestamptz;

UPDATE api.work_items
SET claim_started_at = COALESCE(claim_started_at, updated_at),
    claim_heartbeat_at = COALESCE(claim_heartbeat_at, updated_at)
WHERE execution_state = 'running'
  AND NULLIF(btrim(assignee), '') IS NOT NULL;

CREATE OR REPLACE FUNCTION api.maintain_work_item_claim_lease() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.execution_state = 'running' AND NULLIF(btrim(NEW.assignee), '') IS NOT NULL THEN
    IF OLD.execution_state IS DISTINCT FROM 'running'
       OR OLD.assignee IS DISTINCT FROM NEW.assignee
       OR OLD.claim_started_at IS NULL THEN
      NEW.claim_started_at := now();
      NEW.claim_heartbeat_at := now();
    END IF;
  ELSE
    NEW.claim_started_at := NULL;
    NEW.claim_heartbeat_at := NULL;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS maintain_work_item_claim_lease ON api.work_items;
CREATE TRIGGER maintain_work_item_claim_lease
  BEFORE UPDATE OF execution_state, assignee, progress, completed_at ON api.work_items
  FOR EACH ROW EXECUTE FUNCTION api.maintain_work_item_claim_lease();

CREATE OR REPLACE FUNCTION api.heartbeat_work_item(
  target_work_item_id uuid,
  agent_name text
) RETURNS SETOF api.work_items
LANGUAGE plpgsql AS $$
DECLARE
  item api.work_items;
  normalized_agent text := btrim(agent_name);
BEGIN
  IF normalized_agent = '' OR normalized_agent IS NULL THEN
    RAISE EXCEPTION 'A heartbeat requires a worker name.' USING ERRCODE = '23514';
  END IF;

  SELECT * INTO item FROM api.work_items WHERE id = target_work_item_id FOR UPDATE;
  IF item.id IS NULL THEN RAISE EXCEPTION 'Work item not found.' USING ERRCODE = 'P0002'; END IF;
  IF item.execution_state IS DISTINCT FROM 'running'
     OR lower(COALESCE(item.assignee, '')) <> lower(normalized_agent) THEN
    RAISE EXCEPTION 'Only the active worker % can renew this claim.', COALESCE(item.assignee, '(none)')
      USING ERRCODE = '23514';
  END IF;

  UPDATE api.work_items
  SET claim_heartbeat_at = now(), updated_at = now()
  WHERE id = item.id
  RETURNING * INTO item;
  RETURN NEXT item;
END $$;

CREATE OR REPLACE FUNCTION api.get_work_item_claim_status(target_work_item_id uuid)
RETURNS TABLE(
  work_item_id uuid,
  owner text,
  active_worker text,
  execution_state text,
  claim_started_at timestamptz,
  last_heartbeat_at timestamptz,
  idle_seconds integer,
  timeout_seconds integer,
  takeover_eligible boolean
)
LANGUAGE sql STABLE AS $$
  SELECT
    item.id,
    item.owner,
    item.assignee,
    item.execution_state,
    item.claim_started_at,
    item.claim_heartbeat_at,
    GREATEST(0, extract(epoch FROM now() - COALESCE(item.claim_heartbeat_at, item.claim_started_at, item.updated_at))::integer),
    project.claim_idle_timeout_minutes * 60,
    item.execution_state = 'running'
      AND item.assignee IS NOT NULL
      AND COALESCE(item.claim_heartbeat_at, item.claim_started_at, item.updated_at)
        <= now() - make_interval(mins => project.claim_idle_timeout_minutes)
  FROM api.work_items item
  JOIN api.projects project ON project.id = item.project_id
  WHERE item.id = target_work_item_id;
$$;

CREATE OR REPLACE FUNCTION api.authorize_idle_claim_takeover(
  target_work_item_id uuid,
  new_worker_name text,
  human_name text DEFAULT 'You'
) RETURNS SETOF api.work_items
LANGUAGE plpgsql AS $$
DECLARE
  item api.work_items;
  timeout_minutes integer;
  previous_worker text;
  previous_owner text;
  normalized_worker text := btrim(new_worker_name);
  normalized_human text := btrim(human_name);
BEGIN
  IF normalized_worker = '' OR normalized_worker IS NULL THEN
    RAISE EXCEPTION 'Takeover requires a new worker name.' USING ERRCODE = '23514';
  END IF;
  IF normalized_human = '' OR normalized_human IS NULL THEN
    RAISE EXCEPTION 'Takeover requires an authorizing person.' USING ERRCODE = '23514';
  END IF;

  SELECT * INTO item
  FROM api.work_items
  WHERE id = target_work_item_id
  FOR UPDATE;

  IF item.id IS NULL THEN RAISE EXCEPTION 'Work item not found.' USING ERRCODE = 'P0002'; END IF;
  SELECT claim_idle_timeout_minutes INTO timeout_minutes
  FROM api.projects WHERE id = item.project_id;
  IF item.execution_state IS DISTINCT FROM 'running' OR item.assignee IS NULL THEN
    RAISE EXCEPTION 'Only an actively claimed work item can be taken over.' USING ERRCODE = '23514';
  END IF;
  IF COALESCE(item.claim_heartbeat_at, item.claim_started_at, item.updated_at)
       > now() - make_interval(mins => timeout_minutes) THEN
    RAISE EXCEPTION 'Claim is still active and cannot be taken over.'
      USING ERRCODE = '23514', HINT = 'Wait until the claim is idle or ask the active worker to release it.';
  END IF;

  previous_worker := item.assignee;
  previous_owner := item.owner;
  UPDATE api.work_items
  SET owner = normalized_worker,
      assignee = normalized_worker,
      blocked_reason = NULL,
      updated_at = now()
  WHERE id = item.id
  RETURNING * INTO item;

  INSERT INTO api.activity_events(project_id, work_item_id, event_type, actor_type, actor_name, summary, details)
  VALUES (
    item.project_id, item.id, 'work_item.claim_taken_over', 'human', normalized_human,
    'Transferred idle claim for ' || item.item_key || ' to ' || normalized_worker,
    jsonb_build_object(
      'previous_worker', previous_worker,
      'previous_owner', previous_owner,
      'worker', normalized_worker,
      'owner', normalized_worker,
      'idle_timeout_minutes', timeout_minutes
    )
  );
  RETURN NEXT item;
END $$;

CREATE OR REPLACE FUNCTION api.authorize_idle_claim_release(
  target_work_item_id uuid,
  human_name text DEFAULT 'You'
) RETURNS SETOF api.work_items
LANGUAGE plpgsql AS $$
DECLARE
  item api.work_items;
  timeout_minutes integer;
  previous_worker text;
  normalized_human text := btrim(human_name);
BEGIN
  IF normalized_human = '' OR normalized_human IS NULL THEN
    RAISE EXCEPTION 'Release requires an authorizing person.' USING ERRCODE = '23514';
  END IF;

  SELECT * INTO item
  FROM api.work_items
  WHERE id = target_work_item_id
  FOR UPDATE;

  IF item.id IS NULL THEN RAISE EXCEPTION 'Work item not found.' USING ERRCODE = 'P0002'; END IF;
  SELECT claim_idle_timeout_minutes INTO timeout_minutes
  FROM api.projects WHERE id = item.project_id;
  IF item.execution_state IS DISTINCT FROM 'running' OR item.assignee IS NULL THEN
    RAISE EXCEPTION 'Only an actively claimed work item can be released.' USING ERRCODE = '23514';
  END IF;
  IF COALESCE(item.claim_heartbeat_at, item.claim_started_at, item.updated_at)
       > now() - make_interval(mins => timeout_minutes) THEN
    RAISE EXCEPTION 'Claim is still active and cannot be released by another person.'
      USING ERRCODE = '23514', HINT = 'Wait until the claim is idle or ask the active worker to release it.';
  END IF;

  previous_worker := item.assignee;
  UPDATE api.work_items
  SET execution_state = 'queued',
      assignee = NULL,
      blocked_reason = NULL,
      updated_at = now()
  WHERE id = item.id
  RETURNING * INTO item;

  INSERT INTO api.activity_events(project_id, work_item_id, event_type, actor_type, actor_name, summary, details)
  VALUES (
    item.project_id, item.id, 'work_item.claim_released_by_human', 'human', normalized_human,
    'Released idle claim for ' || item.item_key || ' back to the ready queue',
    jsonb_build_object(
      'previous_worker', previous_worker,
      'owner', item.owner,
      'idle_timeout_minutes', timeout_minutes
    )
  );
  RETURN NEXT item;
END $$;

-- Fence a disconnected worker after a human has transferred its claim. Human
-- board interaction remains authoritative and may use the conventional actor
-- name "You".
CREATE OR REPLACE FUNCTION api.move_work_item(
  target_work_item_id uuid,
  target_stage_slug text,
  actor_name text DEFAULT 'You',
  event_summary text DEFAULT NULL
) RETURNS SETOF api.work_items
LANGUAGE plpgsql AS $$
DECLARE item api.work_items; target_stage api.board_stages; previous_stage text; normalized_actor text := btrim(actor_name);
BEGIN
  SELECT * INTO item FROM api.work_items WHERE id = target_work_item_id FOR UPDATE;
  IF item.id IS NULL THEN RAISE EXCEPTION 'Work item not found'; END IF;
  IF item.execution_state = 'running'
     AND item.assignee IS NOT NULL
     AND lower(COALESCE(normalized_actor, '')) <> 'you'
     AND lower(item.assignee) <> lower(COALESCE(normalized_actor, '')) THEN
    RAISE EXCEPTION 'Only the active worker % can move this claimed item.', item.assignee
      USING ERRCODE = '23514', HINT = 'Refresh the work package; this claim may have been transferred.';
  END IF;
  SELECT slug INTO previous_stage FROM api.board_stages WHERE id = item.stage_id;
  SELECT * INTO target_stage FROM api.board_stages WHERE board_id = item.board_id AND slug = target_stage_slug;
  IF target_stage.id IS NULL THEN RAISE EXCEPTION 'Stage not found'; END IF;
  UPDATE api.work_items SET
    stage_id = target_stage.id,
    position = COALESCE((SELECT max(position) + 1 FROM api.work_items WHERE stage_id = target_stage.id AND id <> item.id), 0),
    progress = CASE WHEN target_stage.slug = 'done' THEN 'completed' WHEN target_stage.slug = 'backlog' THEN 'not_started' ELSE 'in_progress' END,
    execution_state = CASE WHEN target_stage.slug = 'done' THEN 'complete' ELSE execution_state END,
    completed_at = CASE WHEN target_stage.slug = 'done' THEN now() ELSE NULL END,
    claim_heartbeat_at = CASE WHEN target_stage.slug = 'done' THEN NULL ELSE now() END,
    updated_at = now()
  WHERE id = item.id RETURNING * INTO item;
  INSERT INTO api.activity_events(project_id, work_item_id, event_type, actor_type, actor_name, summary, details)
  VALUES (item.project_id, item.id, 'work_item.moved', CASE WHEN normalized_actor = 'You' THEN 'human' ELSE 'agent' END, normalized_actor,
    COALESCE(event_summary, 'Moved ' || item.item_key || ' from ' || previous_stage || ' to ' || target_stage.slug),
    jsonb_build_object('from', previous_stage, 'to', target_stage.slug));
  RETURN NEXT item;
END $$;

GRANT EXECUTE ON FUNCTION api.heartbeat_work_item(uuid, text) TO web_anon;
GRANT EXECUTE ON FUNCTION api.get_work_item_claim_status(uuid) TO web_anon;
GRANT EXECUTE ON FUNCTION api.authorize_idle_claim_takeover(uuid, text, text) TO web_anon;
GRANT EXECUTE ON FUNCTION api.authorize_idle_claim_release(uuid, text) TO web_anon;

NOTIFY pgrst, 'reload schema';

COMMIT;
