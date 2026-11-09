-- Route ready work only to registered workers that advertise every capability
-- required by the story, its parent feature, and its child tasks.

BEGIN;

ALTER TABLE api.agent_workers
  ADD COLUMN IF NOT EXISTS capabilities jsonb NOT NULL DEFAULT '[]'::jsonb;

ALTER TABLE api.work_items
  ADD COLUMN IF NOT EXISTS required_worker_capabilities jsonb NOT NULL DEFAULT '[]'::jsonb;

CREATE OR REPLACE FUNCTION api.normalize_worker_capabilities(value jsonb)
RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE normalized jsonb;
BEGIN
  IF jsonb_typeof(COALESCE(value, '[]'::jsonb)) <> 'array' THEN
    RAISE EXCEPTION 'Worker capabilities must be a JSON array.' USING ERRCODE = '23514';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements_text(COALESCE(value, '[]'::jsonb)) AS entries(capability)
    WHERE capability <> lower(btrim(capability))
       OR capability NOT IN (
         'code_execution', 'git', 'browser_automation', 'screenshot_capture',
         'screen_recording', 'image_generation', 'visual_comparison'
       )
  ) THEN
    RAISE EXCEPTION 'Unknown worker capability. Use code_execution, git, browser_automation, screenshot_capture, screen_recording, image_generation, or visual_comparison.'
      USING ERRCODE = '23514';
  END IF;
  SELECT COALESCE(jsonb_agg(capability ORDER BY capability), '[]'::jsonb)
  INTO normalized
  FROM (
    SELECT DISTINCT capability
    FROM jsonb_array_elements_text(COALESCE(value, '[]'::jsonb)) AS entries(capability)
  ) capabilities;
  RETURN normalized;
END $$;

ALTER TABLE api.agent_workers
  DROP CONSTRAINT IF EXISTS agent_workers_capabilities_valid;
ALTER TABLE api.agent_workers
  ADD CONSTRAINT agent_workers_capabilities_valid
  CHECK (
    jsonb_typeof(capabilities) = 'array'
    AND capabilities <@ '["code_execution", "git", "browser_automation", "screenshot_capture", "screen_recording", "image_generation", "visual_comparison"]'::jsonb
  );

ALTER TABLE api.work_items
  DROP CONSTRAINT IF EXISTS work_items_required_worker_capabilities_valid;
ALTER TABLE api.work_items
  ADD CONSTRAINT work_items_required_worker_capabilities_valid
  CHECK (
    jsonb_typeof(required_worker_capabilities) = 'array'
    AND required_worker_capabilities <@ '["code_execution", "git", "browser_automation", "screenshot_capture", "screen_recording", "image_generation", "visual_comparison"]'::jsonb
  );

CREATE OR REPLACE FUNCTION api.effective_required_worker_capabilities(target_work_item_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  WITH target AS (
    SELECT id, parent_id FROM api.work_items WHERE id = target_work_item_id
  ), capability_values AS (
    SELECT jsonb_array_elements_text(source.required_worker_capabilities) AS capability
    FROM api.work_items source
    CROSS JOIN target
    WHERE source.id = target.id
       OR source.id = target.parent_id
       OR source.parent_id = target.id
  )
  SELECT COALESCE(jsonb_agg(capability ORDER BY capability), '[]'::jsonb)
  FROM (SELECT DISTINCT capability FROM capability_values) capabilities;
$$;

CREATE OR REPLACE FUNCTION api.worker_can_claim_item(
  target_worker_id uuid,
  target_work_item_id uuid
) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT NOT EXISTS (
    SELECT 1
    FROM jsonb_array_elements_text(api.effective_required_worker_capabilities(target_work_item_id)) AS requirements(requirement)
    WHERE NOT worker.capabilities ? requirement
  )
  FROM api.agent_workers worker
  WHERE worker.id = target_worker_id AND worker.status = 'active';
$$;

DROP VIEW IF EXISTS api.project_agent_workers;
CREATE VIEW api.project_agent_workers AS
SELECT
  worker.id AS worker_id,
  worker.project_id,
  worker.handle,
  worker.display_name,
  worker.client_type,
  worker.capabilities,
  worker.status,
  worker.last_seen_at,
  worker.created_at,
  count(item.id) FILTER (
    WHERE item.execution_state = 'running' AND item.assignee_worker_id = worker.id
  )::integer AS active_claims
FROM api.agent_workers worker
LEFT JOIN api.work_items item ON item.assignee_worker_id = worker.id
GROUP BY worker.id;

DROP FUNCTION IF EXISTS api.register_agent_worker(uuid, text, text, text);
CREATE FUNCTION api.register_agent_worker(
  target_project_id uuid,
  requested_handle text,
  requested_display_name text,
  requested_client_type text,
  requested_capabilities jsonb DEFAULT '[]'::jsonb
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
  normalized_capabilities jsonb := api.normalize_worker_capabilities(requested_capabilities);
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
    INSERT INTO api.agent_workers(project_id, handle, display_name, client_type, capabilities, token_hash)
    VALUES (
      target_project_id, normalized_handle, normalized_display_name,
      normalized_client_type, normalized_capabilities,
      encode(digest(token, 'sha256'), 'hex')
    )
    RETURNING * INTO worker;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'Worker handle @% is already registered for this project. Resume it with its worker ID and token.', normalized_handle
      USING ERRCODE = '23505';
  END;

  INSERT INTO api.activity_events(project_id, event_type, actor_type, actor_name, summary, details)
  VALUES (
    target_project_id, 'agent_worker.registered', 'agent', normalized_handle,
    'Registered ' || normalized_display_name || ' as @' || normalized_handle,
    jsonb_build_object(
      'worker_id', worker.id, 'handle', worker.handle,
      'client_type', worker.client_type, 'capabilities', worker.capabilities
    )
  );

  RETURN jsonb_build_object(
    'worker_id', worker.id,
    'project_id', worker.project_id,
    'handle', worker.handle,
    'display_name', worker.display_name,
    'client_type', worker.client_type,
    'capabilities', worker.capabilities,
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
    'capabilities', worker.capabilities,
    'status', worker.status,
    'last_seen_at', worker.last_seen_at
  );
END $$;

CREATE OR REPLACE FUNCTION api.update_agent_worker_capabilities(
  target_worker_id uuid,
  resume_token text,
  requested_capabilities jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, public
AS $$
DECLARE
  worker api.agent_workers;
  normalized_capabilities jsonb := api.normalize_worker_capabilities(requested_capabilities);
BEGIN
  worker := api.require_agent_worker(target_worker_id, resume_token, NULL);
  IF EXISTS (
    SELECT 1
    FROM api.work_items item
    WHERE item.assignee_worker_id = worker.id
      AND item.execution_state = 'running'
      AND EXISTS (
        SELECT 1
        FROM jsonb_array_elements_text(api.effective_required_worker_capabilities(item.id)) AS requirements(requirement)
        WHERE NOT normalized_capabilities ? requirement
      )
  ) THEN
    RAISE EXCEPTION 'Capabilities required by an active claim cannot be removed.' USING ERRCODE = '23514';
  END IF;
  UPDATE api.agent_workers
  SET capabilities = normalized_capabilities, last_seen_at = now(), updated_at = now()
  WHERE id = worker.id RETURNING * INTO worker;
  INSERT INTO api.activity_events(project_id, event_type, actor_type, actor_name, summary, details)
  VALUES (
    worker.project_id, 'agent_worker.capabilities_updated', 'agent', worker.handle,
    'Updated capabilities for @' || worker.handle,
    jsonb_build_object('worker_id', worker.id, 'capabilities', worker.capabilities)
  );
  RETURN jsonb_build_object(
    'worker_id', worker.id, 'project_id', worker.project_id,
    'handle', worker.handle, 'capabilities', worker.capabilities,
    'last_seen_at', worker.last_seen_at
  );
END $$;

CREATE OR REPLACE FUNCTION api.set_work_item_required_capabilities(
  target_work_item_id uuid,
  requested_capabilities jsonb,
  actor_name text DEFAULT 'You'
) RETURNS SETOF api.work_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, public
AS $$
DECLARE
  item api.work_items;
  governed_item api.work_items;
  stage api.board_stages;
  normalized_capabilities jsonb := api.normalize_worker_capabilities(requested_capabilities);
BEGIN
  SELECT * INTO item FROM api.work_items WHERE id = target_work_item_id FOR UPDATE;
  IF item.id IS NULL THEN RAISE EXCEPTION 'Work item not found.' USING ERRCODE = 'P0002'; END IF;
  governed_item := item;
  IF item.kind = 'task' THEN
    SELECT * INTO governed_item FROM api.work_items WHERE id = item.parent_id;
  END IF;
  SELECT * INTO stage FROM api.board_stages WHERE id = governed_item.stage_id;
  IF stage.slug NOT IN ('backlog', 'analyse', 'plan') OR governed_item.execution_state = 'running' THEN
    RAISE EXCEPTION 'Required worker capabilities cannot change after work is claimed or Build begins.' USING ERRCODE = '23514';
  END IF;
  IF item.kind = 'feature' AND EXISTS (
    SELECT 1 FROM api.work_items child
    JOIN api.board_stages child_stage ON child_stage.id = child.stage_id
    WHERE child.parent_id = item.id
      AND child.kind = 'story'
      AND (child_stage.slug NOT IN ('backlog', 'analyse', 'plan') OR child.execution_state = 'running')
  ) THEN
    RAISE EXCEPTION 'Feature capabilities cannot change after a child story is claimed or enters Build.' USING ERRCODE = '23514';
  END IF;
  UPDATE api.work_items
  SET required_worker_capabilities = normalized_capabilities, updated_at = now()
  WHERE id = item.id RETURNING * INTO item;
  INSERT INTO api.activity_events(project_id, work_item_id, event_type, actor_type, actor_name, summary, details)
  VALUES (
    item.project_id, item.id, 'work_item.capabilities_defined',
    CASE WHEN actor_name = 'You' THEN 'human' ELSE 'agent' END,
    actor_name, 'Defined required worker capabilities for ' || item.item_key,
    jsonb_build_object('required_worker_capabilities', item.required_worker_capabilities)
  );
  RETURN NEXT item;
END $$;

CREATE OR REPLACE FUNCTION api.claim_next_capable_work_item(
  target_project_id uuid,
  target_worker_id uuid
) RETURNS SETOF api.work_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, public
AS $$
DECLARE worker api.agent_workers; item api.work_items;
BEGIN
  SELECT * INTO worker FROM api.agent_workers
  WHERE id = target_worker_id AND project_id = target_project_id AND status = 'active';
  IF worker.id IS NULL THEN RAISE EXCEPTION 'Active registered worker not found.' USING ERRCODE = 'P0002'; END IF;

  SELECT w.* INTO item
  FROM api.work_items w
  WHERE w.project_id = target_project_id
    AND w.kind = 'story'
    AND w.archived_at IS NULL
    AND w.completed_at IS NULL
    AND w.progress <> 'completed'
    AND COALESCE(w.execution_state, 'queued') = 'queued'
    AND api.acceptance_criteria_are_deterministic(w.acceptance_criteria)
    AND api.worker_can_claim_item(worker.id, w.id)
    AND NOT EXISTS (
      SELECT 1 FROM api.work_item_dependencies dependency
      JOIN api.work_items prerequisite ON prerequisite.id = dependency.depends_on_work_item_id
      WHERE (dependency.work_item_id = w.id OR (w.parent_id IS NOT NULL AND dependency.work_item_id = w.parent_id))
        AND prerequisite.completed_at IS NULL
        AND prerequisite.progress <> 'completed'
    )
  ORDER BY
    CASE
      WHEN lower(COALESCE(w.owner, '')) = lower(worker.handle) THEN 0
      WHEN w.owner IS NULL THEN 1 ELSE 2
    END,
    CASE w.priority
      WHEN 'urgent' THEN 0 WHEN 'high' THEN 1 WHEN 'medium' THEN 2 WHEN 'low' THEN 3 ELSE 4
    END,
    w.created_at,
    w.id
  LIMIT 1
  FOR UPDATE OF w SKIP LOCKED;

  IF item.id IS NULL THEN RETURN; END IF;
  UPDATE api.work_items
  SET owner = COALESCE(owner, worker.handle),
      assignee = worker.handle,
      assignee_worker_id = worker.id,
      execution_state = 'running',
      blocked_reason = NULL,
      updated_at = now()
  WHERE id = item.id RETURNING * INTO item;
  INSERT INTO api.activity_events(project_id, work_item_id, event_type, actor_type, actor_name, summary, details)
  VALUES (
    item.project_id, item.id, 'work_item.claimed', 'agent', worker.handle,
    'Claimed next compatible work item ' || item.item_key,
    jsonb_build_object(
      'owner', item.owner, 'worker', worker.handle, 'worker_id', worker.id,
      'worker_capabilities', worker.capabilities,
      'required_worker_capabilities', api.effective_required_worker_capabilities(item.id)
    )
  );
  RETURN NEXT item;
END $$;

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
  item api.work_items;
  incompatible_work jsonb;
  context jsonb;
BEGIN
  worker := api.require_agent_worker(target_worker_id, resume_token, target_project_id);
  SELECT * INTO item FROM api.claim_next_capable_work_item(target_project_id, worker.id);
  IF item.id IS NULL THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'work_item_id', candidate.id,
      'item_key', candidate.item_key,
      'title', candidate.title,
      'required_worker_capabilities', api.effective_required_worker_capabilities(candidate.id)
    ) ORDER BY candidate.created_at), '[]'::jsonb)
    INTO incompatible_work
    FROM api.work_items candidate
    WHERE candidate.project_id = target_project_id
      AND candidate.kind = 'story'
      AND candidate.archived_at IS NULL
      AND candidate.completed_at IS NULL
      AND candidate.progress <> 'completed'
      AND COALESCE(candidate.execution_state, 'queued') = 'queued'
      AND api.acceptance_criteria_are_deterministic(candidate.acceptance_criteria)
      AND NOT api.worker_can_claim_item(worker.id, candidate.id)
      AND NOT EXISTS (
        SELECT 1 FROM api.work_item_dependencies dependency
        JOIN api.work_items prerequisite ON prerequisite.id = dependency.depends_on_work_item_id
        WHERE (dependency.work_item_id = candidate.id OR (candidate.parent_id IS NOT NULL AND dependency.work_item_id = candidate.parent_id))
          AND prerequisite.completed_at IS NULL
          AND prerequisite.progress <> 'completed'
      );
    RETURN jsonb_build_object(
      'outcome', CASE WHEN jsonb_array_length(incompatible_work) > 0 THEN 'no_compatible_work' ELSE 'no_ready_work' END,
      'work_package', NULL,
      'worker', jsonb_build_object(
        'worker_id', worker.id, 'handle', worker.handle,
        'client_type', worker.client_type, 'capabilities', worker.capabilities
      ),
      'incompatible_work', incompatible_work
    );
  END IF;
  context := api.get_governed_work_item_context(item.id)
    || jsonb_build_object('required_worker_capabilities', api.effective_required_worker_capabilities(item.id));
  RETURN jsonb_build_object(
    'outcome', 'claimed',
    'work_package', context,
    'worker', jsonb_build_object(
      'worker_id', worker.id, 'handle', worker.handle,
      'client_type', worker.client_type, 'capabilities', worker.capabilities
    )
  );
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
DECLARE worker api.agent_workers; item api.work_items; required jsonb;
BEGIN
  SELECT * INTO item FROM api.work_items WHERE id = target_work_item_id;
  IF item.id IS NULL THEN RAISE EXCEPTION 'Work item not found.' USING ERRCODE = 'P0002'; END IF;
  worker := api.require_agent_worker(target_worker_id, resume_token, item.project_id);
  required := api.effective_required_worker_capabilities(item.id);
  IF NOT api.worker_can_claim_item(worker.id, item.id) THEN
    RAISE EXCEPTION 'Worker @% does not provide every required capability: %.', worker.handle, required
      USING ERRCODE = '23514';
  END IF;
  SELECT * INTO item FROM api.claim_work_item(target_work_item_id, worker.handle);
  UPDATE api.work_items SET assignee_worker_id = worker.id WHERE id = item.id RETURNING * INTO item;
  UPDATE api.activity_events
  SET details = details || jsonb_build_object(
    'worker_id', worker.id,
    'worker_handle', worker.handle,
    'worker_capabilities', worker.capabilities,
    'required_worker_capabilities', required
  )
  WHERE id = (
    SELECT id FROM api.activity_events
    WHERE work_item_id = item.id AND event_type = 'work_item.claimed'
    ORDER BY created_at DESC, id DESC LIMIT 1
  );
  RETURN NEXT item;
END $$;

CREATE OR REPLACE FUNCTION api.authorize_idle_claim_takeover(
  target_work_item_id uuid,
  new_worker_id uuid,
  human_name text DEFAULT 'You'
) RETURNS SETOF api.work_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, public
AS $$
DECLARE
  item api.work_items;
  worker api.agent_workers;
  timeout_minutes integer;
  previous_worker text;
  previous_worker_id uuid;
  previous_owner text;
  required jsonb;
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
  required := api.effective_required_worker_capabilities(item.id);
  IF NOT api.worker_can_claim_item(worker.id, item.id) THEN
    RAISE EXCEPTION 'Takeover target @% does not provide every required capability: %.', worker.handle, required
      USING ERRCODE = '23514';
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
  WHERE id = item.id RETURNING * INTO item;
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
      'required_worker_capabilities', required,
      'idle_timeout_minutes', timeout_minutes
    )
  );
  RETURN NEXT item;
END $$;

REVOKE ALL ON FUNCTION api.normalize_worker_capabilities(jsonb) FROM PUBLIC, web_anon;
REVOKE ALL ON FUNCTION api.worker_can_claim_item(uuid, uuid) FROM PUBLIC, web_anon;
REVOKE ALL ON FUNCTION api.claim_next_capable_work_item(uuid, uuid) FROM PUBLIC, web_anon;
GRANT SELECT ON api.project_agent_workers TO web_anon;
GRANT EXECUTE ON FUNCTION api.register_agent_worker(uuid, text, text, text, jsonb) TO web_anon;
GRANT EXECUTE ON FUNCTION api.resume_agent_worker(uuid, text) TO web_anon;
GRANT EXECUTE ON FUNCTION api.update_agent_worker_capabilities(uuid, text, jsonb) TO web_anon;
GRANT EXECUTE ON FUNCTION api.set_work_item_required_capabilities(uuid, jsonb, text) TO web_anon;
GRANT EXECUTE ON FUNCTION api.effective_required_worker_capabilities(uuid) TO web_anon;
GRANT EXECUTE ON FUNCTION api.claim_next_work_package_as_worker(uuid, uuid, text) TO web_anon;
GRANT EXECUTE ON FUNCTION api.claim_work_item_as_worker(uuid, uuid, text) TO web_anon;
GRANT EXECUTE ON FUNCTION api.authorize_idle_claim_takeover(uuid, uuid, text) TO web_anon;

NOTIFY pgrst, 'reload schema';

COMMIT;
