-- Register durable agent identities. Handles are unique per project; callers
-- authenticate claim-sensitive work with an immutable worker ID and a one-time
-- resume token whose digest is the only value stored by Agent Boards.

BEGIN;

CREATE TABLE IF NOT EXISTS api.agent_workers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id uuid NOT NULL REFERENCES api.projects(id) ON DELETE CASCADE,
  handle text NOT NULL,
  display_name text NOT NULL,
  client_type text NOT NULL CHECK (client_type IN ('codex', 'claude', 'other')),
  token_hash text NOT NULL,
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'revoked')),
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (handle ~ '^[a-z0-9][a-z0-9._-]{2,63}$'),
  CHECK (length(btrim(display_name)) BETWEEN 1 AND 120)
);

CREATE UNIQUE INDEX IF NOT EXISTS agent_workers_project_handle_unique
  ON api.agent_workers(project_id, lower(handle));

ALTER TABLE api.work_items
  ADD COLUMN IF NOT EXISTS assignee_worker_id uuid REFERENCES api.agent_workers(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS work_items_assignee_worker_idx
  ON api.work_items(assignee_worker_id)
  WHERE assignee_worker_id IS NOT NULL;

CREATE OR REPLACE FUNCTION api.require_agent_worker(
  target_worker_id uuid,
  resume_token text,
  expected_project_id uuid DEFAULT NULL
) RETURNS api.agent_workers
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, public
AS $$
DECLARE worker api.agent_workers;
BEGIN
  SELECT * INTO worker
  FROM api.agent_workers
  WHERE id = target_worker_id
  FOR UPDATE;

  IF worker.id IS NULL THEN
    RAISE EXCEPTION 'Registered worker not found.' USING ERRCODE = 'P0002';
  END IF;
  IF worker.status <> 'active' THEN
    RAISE EXCEPTION 'Worker @% has been revoked.', worker.handle USING ERRCODE = '28000';
  END IF;
  IF expected_project_id IS NOT NULL AND worker.project_id <> expected_project_id THEN
    RAISE EXCEPTION 'Worker @% is not registered for this project.', worker.handle USING ERRCODE = '28000';
  END IF;
  IF btrim(COALESCE(resume_token, '')) = ''
     OR worker.token_hash <> encode(digest(resume_token, 'sha256'), 'hex') THEN
    RAISE EXCEPTION 'Worker credentials are invalid.' USING ERRCODE = '28000';
  END IF;

  UPDATE api.agent_workers
  SET last_seen_at = now(), updated_at = now()
  WHERE id = worker.id
  RETURNING * INTO worker;
  RETURN worker;
END $$;

REVOKE ALL ON FUNCTION api.require_agent_worker(uuid, text, uuid) FROM PUBLIC, web_anon;

CREATE OR REPLACE FUNCTION api.register_agent_worker(
  target_project_id uuid,
  requested_handle text,
  requested_display_name text,
  requested_client_type text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, public
AS $$
DECLARE
  worker api.agent_workers;
  normalized_handle text := lower(btrim(requested_handle));
  normalized_display_name text := COALESCE(NULLIF(btrim(requested_display_name), ''), normalized_handle);
  normalized_client_type text := lower(btrim(requested_client_type));
  token text := encode(gen_random_bytes(32), 'hex');
BEGIN
  IF NOT EXISTS (SELECT 1 FROM api.projects WHERE id = target_project_id AND status <> 'archived') THEN
    RAISE EXCEPTION 'Active project not found.' USING ERRCODE = 'P0002';
  END IF;
  IF normalized_handle !~ '^[a-z0-9][a-z0-9._-]{2,63}$' THEN
    RAISE EXCEPTION 'Worker handle must be 3-64 lowercase letters, numbers, dots, underscores or hyphens.'
      USING ERRCODE = '23514';
  END IF;
  IF normalized_client_type NOT IN ('codex', 'claude', 'other') THEN
    RAISE EXCEPTION 'Worker client type must be codex, claude or other.' USING ERRCODE = '23514';
  END IF;

  BEGIN
    INSERT INTO api.agent_workers(project_id, handle, display_name, client_type, token_hash)
    VALUES (
      target_project_id,
      normalized_handle,
      normalized_display_name,
      normalized_client_type,
      encode(digest(token, 'sha256'), 'hex')
    )
    RETURNING * INTO worker;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'Worker handle @% is already registered for this project. Resume it with its worker ID and token.', normalized_handle
      USING ERRCODE = '23505';
  END;

  INSERT INTO api.activity_events(project_id, event_type, actor_type, actor_name, summary, details)
  VALUES (
    target_project_id,
    'agent_worker.registered',
    'agent',
    normalized_handle,
    'Registered ' || normalized_display_name || ' as @' || normalized_handle,
    jsonb_build_object('worker_id', worker.id, 'handle', worker.handle, 'client_type', worker.client_type)
  );

  RETURN jsonb_build_object(
    'worker_id', worker.id,
    'project_id', worker.project_id,
    'handle', worker.handle,
    'display_name', worker.display_name,
    'client_type', worker.client_type,
    'resume_token', token,
    'registered_at', worker.created_at,
    'instruction', 'Keep resume_token private. Pass worker_id and resume_token to every claim-sensitive MCP tool.'
  );
END $$;

CREATE OR REPLACE FUNCTION api.resume_agent_worker(
  target_worker_id uuid,
  resume_token text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, public
AS $$
DECLARE worker api.agent_workers;
BEGIN
  worker := api.require_agent_worker(target_worker_id, resume_token, NULL);
  RETURN jsonb_build_object(
    'worker_id', worker.id,
    'project_id', worker.project_id,
    'handle', worker.handle,
    'display_name', worker.display_name,
    'client_type', worker.client_type,
    'status', worker.status,
    'last_seen_at', worker.last_seen_at
  );
END $$;

CREATE OR REPLACE VIEW api.project_agent_workers AS
SELECT
  worker.id AS worker_id,
  worker.project_id,
  worker.handle,
  worker.display_name,
  worker.client_type,
  worker.status,
  worker.last_seen_at,
  worker.created_at,
  count(item.id) FILTER (
    WHERE item.execution_state = 'running' AND item.assignee_worker_id = worker.id
  )::integer AS active_claims
FROM api.agent_workers worker
LEFT JOIN api.work_items item ON item.assignee_worker_id = worker.id
GROUP BY worker.id;

CREATE OR REPLACE FUNCTION api.claim_next_work_package_as_worker(
  target_project_id uuid,
  target_worker_id uuid,
  resume_token text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, public
AS $$
DECLARE
  worker api.agent_workers;
  payload jsonb;
  claimed_item_id uuid;
BEGIN
  worker := api.require_agent_worker(target_worker_id, resume_token, target_project_id);
  payload := api.claim_next_work_package(target_project_id, worker.handle);
  claimed_item_id := NULLIF(payload #>> '{work_package,story,id}', '')::uuid;
  IF claimed_item_id IS NOT NULL THEN
    UPDATE api.work_items SET assignee_worker_id = worker.id WHERE id = claimed_item_id;
    UPDATE api.activity_events
    SET details = details || jsonb_build_object('worker_id', worker.id, 'worker_handle', worker.handle)
    WHERE id = (
      SELECT id FROM api.activity_events
      WHERE work_item_id = claimed_item_id AND event_type = 'work_item.claimed'
      ORDER BY created_at DESC, id DESC LIMIT 1
    );
    payload := jsonb_set(payload, '{work_package,story,assignee_worker_id}', to_jsonb(worker.id), true);
  END IF;
  RETURN payload || jsonb_build_object('worker', jsonb_build_object(
    'worker_id', worker.id, 'handle', worker.handle, 'client_type', worker.client_type
  ));
END $$;

CREATE OR REPLACE FUNCTION api.claim_work_item_as_worker(
  target_work_item_id uuid,
  target_worker_id uuid,
  resume_token text
) RETURNS SETOF api.work_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, public
AS $$
DECLARE worker api.agent_workers; item api.work_items;
BEGIN
  SELECT * INTO item FROM api.work_items WHERE id = target_work_item_id;
  IF item.id IS NULL THEN RAISE EXCEPTION 'Work item not found.' USING ERRCODE = 'P0002'; END IF;
  worker := api.require_agent_worker(target_worker_id, resume_token, item.project_id);
  SELECT * INTO item FROM api.claim_work_item(target_work_item_id, worker.handle);
  UPDATE api.work_items SET assignee_worker_id = worker.id WHERE id = item.id RETURNING * INTO item;
  UPDATE api.activity_events
  SET details = details || jsonb_build_object('worker_id', worker.id, 'worker_handle', worker.handle)
  WHERE id = (
    SELECT id FROM api.activity_events
    WHERE work_item_id = item.id AND event_type = 'work_item.claimed'
    ORDER BY created_at DESC, id DESC LIMIT 1
  );
  RETURN NEXT item;
END $$;

CREATE OR REPLACE FUNCTION api.heartbeat_work_item_as_worker(
  target_work_item_id uuid,
  target_worker_id uuid,
  resume_token text
) RETURNS SETOF api.work_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, public
AS $$
DECLARE worker api.agent_workers; item api.work_items;
BEGIN
  SELECT * INTO item FROM api.work_items WHERE id = target_work_item_id;
  IF item.id IS NULL THEN RAISE EXCEPTION 'Work item not found.' USING ERRCODE = 'P0002'; END IF;
  worker := api.require_agent_worker(target_worker_id, resume_token, item.project_id);
  IF item.assignee_worker_id IS DISTINCT FROM worker.id THEN
    RAISE EXCEPTION 'This claim belongs to a different registered worker.' USING ERRCODE = '28000';
  END IF;
  SELECT * INTO item FROM api.heartbeat_work_item(item.id, worker.handle);
  RETURN NEXT item;
END $$;

CREATE OR REPLACE FUNCTION api.block_work_item_as_worker(
  target_work_item_id uuid,
  target_worker_id uuid,
  resume_token text,
  reason text
) RETURNS SETOF api.work_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, public
AS $$
DECLARE worker api.agent_workers; item api.work_items;
BEGIN
  SELECT * INTO item FROM api.work_items WHERE id = target_work_item_id;
  IF item.id IS NULL THEN RAISE EXCEPTION 'Work item not found.' USING ERRCODE = 'P0002'; END IF;
  worker := api.require_agent_worker(target_worker_id, resume_token, item.project_id);
  IF item.assignee_worker_id IS DISTINCT FROM worker.id THEN
    RAISE EXCEPTION 'This claim belongs to a different registered worker.' USING ERRCODE = '28000';
  END IF;
  SELECT * INTO item FROM api.block_work_item(item.id, worker.handle, reason);
  RETURN NEXT item;
END $$;

CREATE OR REPLACE FUNCTION api.release_work_item_as_worker(
  target_work_item_id uuid,
  target_worker_id uuid,
  resume_token text,
  reason text DEFAULT NULL
) RETURNS SETOF api.work_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, public
AS $$
DECLARE worker api.agent_workers; item api.work_items;
BEGIN
  SELECT * INTO item FROM api.work_items WHERE id = target_work_item_id;
  IF item.id IS NULL THEN RAISE EXCEPTION 'Work item not found.' USING ERRCODE = 'P0002'; END IF;
  worker := api.require_agent_worker(target_worker_id, resume_token, item.project_id);
  IF item.assignee_worker_id IS DISTINCT FROM worker.id THEN
    RAISE EXCEPTION 'This claim belongs to a different registered worker.' USING ERRCODE = '28000';
  END IF;
  SELECT * INTO item FROM api.release_work_item(item.id, worker.handle, reason);
  RETURN NEXT item;
END $$;

CREATE OR REPLACE FUNCTION api.move_work_item_as_worker(
  target_work_item_id uuid,
  target_stage_slug text,
  target_worker_id uuid,
  resume_token text,
  event_summary text DEFAULT NULL
) RETURNS SETOF api.work_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, public
AS $$
DECLARE worker api.agent_workers; item api.work_items;
BEGIN
  SELECT * INTO item FROM api.work_items WHERE id = target_work_item_id;
  IF item.id IS NULL THEN RAISE EXCEPTION 'Work item not found.' USING ERRCODE = 'P0002'; END IF;
  worker := api.require_agent_worker(target_worker_id, resume_token, item.project_id);
  IF item.assignee_worker_id IS DISTINCT FROM worker.id THEN
    RAISE EXCEPTION 'This claim belongs to a different registered worker.' USING ERRCODE = '28000';
  END IF;
  SELECT * INTO item FROM api.move_work_item(item.id, target_stage_slug, worker.handle, event_summary);
  RETURN NEXT item;
END $$;

CREATE OR REPLACE FUNCTION api.maintain_work_item_claim_lease() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.execution_state = 'running' AND NULLIF(btrim(NEW.assignee), '') IS NOT NULL THEN
    IF OLD.execution_state IS DISTINCT FROM 'running'
       OR OLD.assignee IS DISTINCT FROM NEW.assignee
       OR OLD.assignee_worker_id IS DISTINCT FROM NEW.assignee_worker_id
       OR OLD.claim_started_at IS NULL THEN
      NEW.claim_started_at := now();
      NEW.claim_heartbeat_at := now();
    END IF;
  ELSE
    NEW.assignee_worker_id := NULL;
    NEW.claim_started_at := NULL;
    NEW.claim_heartbeat_at := NULL;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS maintain_work_item_claim_lease ON api.work_items;
CREATE TRIGGER maintain_work_item_claim_lease
  BEFORE UPDATE OF execution_state, assignee, assignee_worker_id, progress, completed_at ON api.work_items
  FOR EACH ROW EXECUTE FUNCTION api.maintain_work_item_claim_lease();

DROP FUNCTION IF EXISTS api.get_work_item_claim_status(uuid);
CREATE FUNCTION api.get_work_item_claim_status(target_work_item_id uuid)
RETURNS TABLE(
  work_item_id uuid,
  owner text,
  active_worker text,
  active_worker_id uuid,
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
    item.assignee_worker_id,
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

DROP FUNCTION IF EXISTS api.authorize_idle_claim_takeover(uuid, text, text);
CREATE FUNCTION api.authorize_idle_claim_takeover(
  target_work_item_id uuid,
  new_worker_id uuid,
  human_name text DEFAULT 'You'
) RETURNS SETOF api.work_items
LANGUAGE plpgsql AS $$
DECLARE
  item api.work_items;
  worker api.agent_workers;
  timeout_minutes integer;
  previous_worker text;
  previous_worker_id uuid;
  previous_owner text;
  normalized_human text := btrim(human_name);
BEGIN
  IF normalized_human = '' OR normalized_human IS NULL THEN
    RAISE EXCEPTION 'Takeover requires an authorizing person.' USING ERRCODE = '23514';
  END IF;
  SELECT * INTO item FROM api.work_items WHERE id = target_work_item_id FOR UPDATE;
  IF item.id IS NULL THEN RAISE EXCEPTION 'Work item not found.' USING ERRCODE = 'P0002'; END IF;
  SELECT * INTO worker FROM api.agent_workers
  WHERE id = new_worker_id AND project_id = item.project_id AND status = 'active';
  IF worker.id IS NULL THEN
    RAISE EXCEPTION 'Takeover target must be an active worker registered for this project.' USING ERRCODE = '23514';
  END IF;
  SELECT claim_idle_timeout_minutes INTO timeout_minutes FROM api.projects WHERE id = item.project_id;
  IF item.execution_state IS DISTINCT FROM 'running' OR item.assignee IS NULL THEN
    RAISE EXCEPTION 'Only an actively claimed work item can be taken over.' USING ERRCODE = '23514';
  END IF;
  IF COALESCE(item.claim_heartbeat_at, item.claim_started_at, item.updated_at)
       > now() - make_interval(mins => timeout_minutes) THEN
    RAISE EXCEPTION 'Claim is still active and cannot be taken over.'
      USING ERRCODE = '23514', HINT = 'Wait until the claim is idle or ask the active worker to release it.';
  END IF;

  previous_worker := item.assignee;
  previous_worker_id := item.assignee_worker_id;
  previous_owner := item.owner;
  UPDATE api.work_items
  SET owner = worker.handle,
      assignee = worker.handle,
      assignee_worker_id = worker.id,
      blocked_reason = NULL,
      updated_at = now()
  WHERE id = item.id
  RETURNING * INTO item;

  INSERT INTO api.activity_events(project_id, work_item_id, event_type, actor_type, actor_name, summary, details)
  VALUES (
    item.project_id, item.id, 'work_item.claim_taken_over', 'human', normalized_human,
    'Transferred idle claim for ' || item.item_key || ' to @' || worker.handle,
    jsonb_build_object(
      'previous_worker', previous_worker,
      'previous_worker_id', previous_worker_id,
      'previous_owner', previous_owner,
      'worker', worker.handle,
      'worker_id', worker.id,
      'owner', worker.handle,
      'idle_timeout_minutes', timeout_minutes
    )
  );
  RETURN NEXT item;
END $$;

GRANT SELECT ON api.project_agent_workers TO web_anon;
GRANT EXECUTE ON FUNCTION api.register_agent_worker(uuid, text, text, text) TO web_anon;
GRANT EXECUTE ON FUNCTION api.resume_agent_worker(uuid, text) TO web_anon;
GRANT EXECUTE ON FUNCTION api.claim_next_work_package_as_worker(uuid, uuid, text) TO web_anon;
GRANT EXECUTE ON FUNCTION api.claim_work_item_as_worker(uuid, uuid, text) TO web_anon;
GRANT EXECUTE ON FUNCTION api.heartbeat_work_item_as_worker(uuid, uuid, text) TO web_anon;
GRANT EXECUTE ON FUNCTION api.block_work_item_as_worker(uuid, uuid, text, text) TO web_anon;
GRANT EXECUTE ON FUNCTION api.release_work_item_as_worker(uuid, uuid, text, text) TO web_anon;
GRANT EXECUTE ON FUNCTION api.move_work_item_as_worker(uuid, text, uuid, text, text) TO web_anon;
GRANT EXECUTE ON FUNCTION api.authorize_idle_claim_takeover(uuid, uuid, text) TO web_anon;

-- Agents must use the authenticated worker wrappers. The underlying functions
-- remain callable by their SECURITY DEFINER wrappers, but not by anonymous REST
-- or MCP callers with a free-form display name.
REVOKE EXECUTE ON FUNCTION api.claim_next_work_package(uuid, text) FROM PUBLIC, web_anon;
REVOKE EXECUTE ON FUNCTION api.claim_next_ready_work_item(uuid, text) FROM PUBLIC, web_anon;
REVOKE EXECUTE ON FUNCTION api.claim_work_item(uuid, text) FROM PUBLIC, web_anon;
REVOKE EXECUTE ON FUNCTION api.heartbeat_work_item(uuid, text) FROM PUBLIC, web_anon;
REVOKE EXECUTE ON FUNCTION api.block_work_item(uuid, text, text) FROM PUBLIC, web_anon;
REVOKE EXECUTE ON FUNCTION api.release_work_item(uuid, text, text) FROM PUBLIC, web_anon;

NOTIFY pgrst, 'reload schema';

COMMIT;
