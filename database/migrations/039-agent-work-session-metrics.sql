-- Measure agent time from database-owned claim sessions. Usage remains an
-- explicit client report because MCP cannot observe model token accounting.

BEGIN;

ALTER TABLE api.projects
  ADD COLUMN IF NOT EXISTS agent_metrics_tracking_started_at timestamptz NOT NULL DEFAULT now();

CREATE TABLE IF NOT EXISTS api.agent_work_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id uuid NOT NULL REFERENCES api.projects(id) ON DELETE CASCADE,
  work_item_id uuid NOT NULL REFERENCES api.work_items(id) ON DELETE CASCADE,
  worker_id uuid REFERENCES api.agent_workers(id) ON DELETE SET NULL,
  worker_handle text NOT NULL,
  started_at timestamptz NOT NULL,
  last_heartbeat_at timestamptz NOT NULL,
  ended_at timestamptz,
  end_reason text CHECK (end_reason IS NULL OR end_reason IN (
    'completed', 'blocked', 'failed', 'released', 'takeover', 'idle_timeout', 'cancelled', 'ended'
  )),
  input_tokens bigint CHECK (input_tokens IS NULL OR input_tokens >= 0),
  output_tokens bigint CHECK (output_tokens IS NULL OR output_tokens >= 0),
  estimated_cost_usd numeric(14,6) CHECK (estimated_cost_usd IS NULL OR estimated_cost_usd >= 0),
  provider text,
  model text,
  usage_reported_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (ended_at IS NULL OR ended_at >= started_at)
);

CREATE UNIQUE INDEX IF NOT EXISTS agent_work_sessions_one_open_claim
  ON api.agent_work_sessions(work_item_id)
  WHERE ended_at IS NULL;
CREATE INDEX IF NOT EXISTS agent_work_sessions_project_started
  ON api.agent_work_sessions(project_id, started_at DESC);
CREATE INDEX IF NOT EXISTS agent_work_sessions_worker_started
  ON api.agent_work_sessions(worker_id, started_at DESC)
  WHERE worker_id IS NOT NULL;

CREATE OR REPLACE FUNCTION api.track_agent_work_session() RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, public
AS $$
DECLARE
  session api.agent_work_sessions;
  timeout_minutes integer;
  observed_heartbeat timestamptz;
  session_start timestamptz;
  close_at timestamptz;
  close_reason text;
  identity_changed boolean;
BEGIN
  SELECT claim_idle_timeout_minutes INTO timeout_minutes
  FROM api.projects WHERE id = NEW.project_id;
  observed_heartbeat := COALESCE(NEW.claim_heartbeat_at, NEW.claim_started_at, NEW.updated_at, now());
  session_start := COALESCE(NEW.claim_started_at, observed_heartbeat);

  SELECT * INTO session
  FROM api.agent_work_sessions
  WHERE work_item_id = NEW.id AND ended_at IS NULL
  FOR UPDATE;

  IF NEW.execution_state = 'running'
     AND NULLIF(btrim(NEW.assignee), '') IS NOT NULL
     AND NEW.assignee_worker_id IS NOT NULL THEN
    identity_changed := session.id IS NOT NULL
      AND (
        (session.worker_id IS NOT NULL AND NEW.assignee_worker_id IS NOT NULL AND session.worker_id <> NEW.assignee_worker_id)
        OR lower(session.worker_handle) <> lower(NEW.assignee)
      );

    IF session.id IS NOT NULL AND identity_changed THEN
      close_at := LEAST(now(), session.last_heartbeat_at + make_interval(mins => timeout_minutes));
      UPDATE api.agent_work_sessions
      SET ended_at = GREATEST(started_at, close_at), end_reason = 'takeover', updated_at = now()
      WHERE id = session.id;
      session.id := NULL;
      session_start := observed_heartbeat;
    ELSIF session.id IS NOT NULL
      AND observed_heartbeat > session.last_heartbeat_at + make_interval(mins => timeout_minutes) THEN
      close_at := session.last_heartbeat_at + make_interval(mins => timeout_minutes);
      UPDATE api.agent_work_sessions
      SET ended_at = GREATEST(started_at, close_at), end_reason = 'idle_timeout', updated_at = now()
      WHERE id = session.id;
      session.id := NULL;
      session_start := observed_heartbeat;
    END IF;

    IF session.id IS NULL THEN
      INSERT INTO api.agent_work_sessions(
        project_id, work_item_id, worker_id, worker_handle, started_at, last_heartbeat_at
      ) VALUES (
        NEW.project_id,
        NEW.id,
        NEW.assignee_worker_id,
        NEW.assignee,
        session_start,
        observed_heartbeat
      );
    ELSE
      UPDATE api.agent_work_sessions
      SET worker_id = COALESCE(NEW.assignee_worker_id, worker_id),
          worker_handle = NEW.assignee,
          last_heartbeat_at = GREATEST(last_heartbeat_at, observed_heartbeat),
          updated_at = now()
      WHERE id = session.id;
    END IF;
  ELSIF session.id IS NOT NULL THEN
    close_reason := CASE
      WHEN NEW.completed_at IS NOT NULL OR NEW.progress = 'completed' OR NEW.execution_state = 'complete' THEN 'completed'
      WHEN NEW.execution_state = 'blocked' OR NEW.execution_state = 'waiting_for_human' THEN 'blocked'
      WHEN NEW.execution_state = 'failed' THEN 'failed'
      WHEN NEW.execution_state = 'cancelled' THEN 'cancelled'
      WHEN NEW.execution_state = 'queued' THEN 'released'
      ELSE 'ended'
    END;
    close_at := LEAST(now(), session.last_heartbeat_at + make_interval(mins => timeout_minutes));
    UPDATE api.agent_work_sessions
    SET ended_at = GREATEST(started_at, close_at), end_reason = close_reason, updated_at = now()
    WHERE id = session.id;
  END IF;

  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS track_agent_work_session_insert ON api.work_items;
CREATE TRIGGER track_agent_work_session_insert
  AFTER INSERT ON api.work_items
  FOR EACH ROW EXECUTE FUNCTION api.track_agent_work_session();

DROP TRIGGER IF EXISTS track_agent_work_session_update ON api.work_items;
CREATE TRIGGER track_agent_work_session_update
  AFTER UPDATE OF execution_state, assignee, assignee_worker_id, claim_started_at, claim_heartbeat_at, progress, completed_at
  ON api.work_items
  FOR EACH ROW EXECUTE FUNCTION api.track_agent_work_session();

INSERT INTO api.agent_work_sessions(
  project_id, work_item_id, worker_id, worker_handle, started_at, last_heartbeat_at
)
SELECT
  item.project_id,
  item.id,
  item.assignee_worker_id,
  item.assignee,
  GREATEST(COALESCE(item.claim_started_at, item.updated_at), project.agent_metrics_tracking_started_at),
  GREATEST(COALESCE(item.claim_heartbeat_at, item.claim_started_at, item.updated_at), project.agent_metrics_tracking_started_at)
FROM api.work_items item
JOIN api.projects project ON project.id = item.project_id
WHERE item.execution_state = 'running'
  AND NULLIF(btrim(item.assignee), '') IS NOT NULL
  AND item.assignee_worker_id IS NOT NULL
  AND COALESCE(item.claim_heartbeat_at, item.claim_started_at, item.updated_at)
    > now() - make_interval(mins => project.claim_idle_timeout_minutes)
  AND NOT EXISTS (
    SELECT 1 FROM api.agent_work_sessions session WHERE session.work_item_id = item.id
  );

CREATE OR REPLACE FUNCTION api.report_work_session_usage(
  target_work_item_id uuid,
  target_worker_id uuid,
  resume_token text,
  reported_input_tokens bigint DEFAULT NULL,
  reported_output_tokens bigint DEFAULT NULL,
  reported_cost_usd numeric DEFAULT NULL,
  reported_provider text DEFAULT NULL,
  reported_model text DEFAULT NULL
) RETURNS SETOF api.agent_work_sessions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, public
AS $$
DECLARE
  worker api.agent_workers;
  session api.agent_work_sessions;
BEGIN
  worker := api.require_agent_worker(target_worker_id, resume_token, NULL);
  IF reported_input_tokens IS NULL AND reported_output_tokens IS NULL AND reported_cost_usd IS NULL THEN
    RAISE EXCEPTION 'Report exact token or cost usage; omit the report when the host does not expose it.'
      USING ERRCODE = '23514';
  END IF;
  IF COALESCE(reported_input_tokens, 0) < 0
     OR COALESCE(reported_output_tokens, 0) < 0
     OR COALESCE(reported_cost_usd, 0) < 0 THEN
    RAISE EXCEPTION 'Reported usage cannot be negative.' USING ERRCODE = '23514';
  END IF;

  SELECT * INTO session
  FROM api.agent_work_sessions
  WHERE work_item_id = target_work_item_id
    AND worker_id = worker.id
  ORDER BY started_at DESC
  LIMIT 1
  FOR UPDATE;
  IF session.id IS NULL THEN
    RAISE EXCEPTION 'No claim session exists for this worker and work item.' USING ERRCODE = 'P0002';
  END IF;

  UPDATE api.agent_work_sessions
  SET input_tokens = COALESCE(reported_input_tokens, input_tokens),
      output_tokens = COALESCE(reported_output_tokens, output_tokens),
      estimated_cost_usd = COALESCE(reported_cost_usd, estimated_cost_usd),
      provider = COALESCE(NULLIF(btrim(reported_provider), ''), provider),
      model = COALESCE(NULLIF(btrim(reported_model), ''), model),
      usage_reported_at = now(),
      updated_at = now()
  WHERE id = session.id
  RETURNING * INTO session;

  INSERT INTO api.activity_events(project_id, work_item_id, event_type, actor_type, actor_name, summary, details)
  VALUES (
    session.project_id,
    session.work_item_id,
    'agent_worker.usage_reported',
    'agent',
    worker.handle,
    'Reported exact host usage for a claim session',
    jsonb_build_object(
      'session_id', session.id,
      'input_tokens', session.input_tokens,
      'output_tokens', session.output_tokens,
      'estimated_cost_usd', session.estimated_cost_usd,
      'provider', session.provider,
      'model', session.model
    )
  );
  RETURN NEXT session;
END $$;

CREATE OR REPLACE VIEW api.project_agent_metrics AS
SELECT
  project.id AS project_id,
  project.agent_metrics_tracking_started_at AS tracking_started_at,
  count(session.id)::integer AS claim_session_count,
  count(session.id) FILTER (WHERE session.ended_at IS NULL)::integer AS open_claim_session_count,
  count(session.id) FILTER (WHERE session.ended_at IS NOT NULL)::integer AS closed_claim_session_count,
  COALESCE(sum(
    GREATEST(0, extract(epoch FROM (
      COALESCE(
        session.ended_at,
        LEAST(now(), session.last_heartbeat_at + make_interval(mins => project.claim_idle_timeout_minutes))
      ) - session.started_at
    )) * 1000)
  ) FILTER (WHERE session.id IS NOT NULL), 0)::bigint AS claimed_duration_ms,
  COALESCE(sum(session.input_tokens), 0)::bigint AS input_tokens,
  COALESCE(sum(session.output_tokens), 0)::bigint AS output_tokens,
  COALESCE(sum(session.estimated_cost_usd), 0)::numeric(14,6) AS estimated_cost_usd,
  count(session.id) FILTER (WHERE session.usage_reported_at IS NOT NULL)::integer AS usage_reported_sessions,
  count(session.id) FILTER (WHERE session.input_tokens IS NOT NULL OR session.output_tokens IS NOT NULL)::integer AS token_reported_sessions,
  count(session.id) FILTER (WHERE session.estimated_cost_usd IS NOT NULL)::integer AS cost_reported_sessions
FROM api.projects project
LEFT JOIN api.agent_work_sessions session ON session.project_id = project.id
GROUP BY project.id;

CREATE OR REPLACE VIEW api.project_summary AS
SELECT p.id AS project_id, p.project_key, p.name, p.description, p.owner, p.status, p.start_date, p.target_date,
  count(w.id) FILTER (WHERE w.archived_at IS NULL) AS total_items,
  count(w.id) FILTER (
    WHERE w.completed_at IS NOT NULL AND w.archived_at IS NULL
      AND (
        w.kind <> 'story'
        OR NOT api.work_item_requires_visual_evidence(w.id)
        OR COALESCE((api.get_visual_story_compliance(w.id)->>'compliant')::boolean, false)
      )
  ) AS completed_items,
  count(w.id) FILTER (
    WHERE w.execution_state = 'running'
      AND w.archived_at IS NULL
      AND NULLIF(btrim(w.assignee), '') IS NOT NULL
      AND w.assignee_worker_id IS NOT NULL
      AND COALESCE(w.claim_heartbeat_at, w.claim_started_at, w.updated_at)
        > now() - make_interval(mins => p.claim_idle_timeout_minutes)
  ) AS running_items,
  count(w.id) FILTER (WHERE w.execution_state IN ('blocked','failed','waiting_for_human') AND w.archived_at IS NULL) AS blocked_items,
  COALESCE(sum(w.estimate_points) FILTER (WHERE w.archived_at IS NULL), 0) AS total_points,
  COALESCE(sum(w.estimate_points) FILTER (
    WHERE w.completed_at IS NOT NULL AND w.archived_at IS NULL
      AND (
        w.kind <> 'story'
        OR NOT api.work_item_requires_visual_evidence(w.id)
        OR COALESCE((api.get_visual_story_compliance(w.id)->>'compliant')::boolean, false)
      )
  ), 0) AS completed_points,
  COALESCE((SELECT (metrics.input_tokens + metrics.output_tokens)::numeric FROM api.project_agent_metrics metrics WHERE metrics.project_id = p.id), 0::numeric) AS tokens,
  COALESCE((SELECT metrics.estimated_cost_usd FROM api.project_agent_metrics metrics WHERE metrics.project_id = p.id), 0) AS estimated_cost_usd,
  p.updated_at,
  count(w.id) FILTER (WHERE w.completed_at IS NOT NULL AND w.archived_at IS NULL) AS raw_completed_items,
  count(w.id) FILTER (
    WHERE w.completed_at IS NOT NULL AND w.archived_at IS NULL
      AND w.kind = 'story' AND api.work_item_requires_visual_evidence(w.id)
      AND NOT COALESCE((api.get_visual_story_compliance(w.id)->>'compliant')::boolean, false)
  ) AS noncompliant_visual_story_count,
  NOT EXISTS (
    SELECT 1 FROM api.work_items visual_item
    WHERE visual_item.project_id = p.id
      AND visual_item.archived_at IS NULL
      AND visual_item.completed_at IS NOT NULL
      AND visual_item.kind = 'story'
      AND api.work_item_requires_visual_evidence(visual_item.id)
      AND NOT COALESCE((api.get_visual_story_compliance(visual_item.id)->>'compliant')::boolean, false)
  ) AS visual_compliance_ready
FROM api.projects p LEFT JOIN api.work_items w ON w.project_id = p.id
GROUP BY p.id;

CREATE OR REPLACE VIEW api.project_owner_summary AS
SELECT
  item.project_id,
  item.owner,
  count(*) FILTER (WHERE item.archived_at IS NULL)::integer AS owned_items,
  count(*) FILTER (
    WHERE item.archived_at IS NULL
      AND item.execution_state = 'running'
      AND NULLIF(btrim(item.assignee), '') IS NOT NULL
      AND item.assignee_worker_id IS NOT NULL
      AND COALESCE(item.claim_heartbeat_at, item.claim_started_at, item.updated_at)
        > now() - make_interval(mins => project.claim_idle_timeout_minutes)
  )::integer AS running_items,
  count(*) FILTER (
    WHERE item.archived_at IS NULL
      AND item.execution_state IN ('blocked', 'failed', 'waiting_for_human')
  )::integer AS blocked_items,
  count(*) FILTER (
    WHERE item.archived_at IS NULL AND item.progress = 'completed'
  )::integer AS completed_items
FROM api.work_items item
JOIN api.projects project ON project.id = item.project_id
WHERE item.owner IS NOT NULL
GROUP BY item.project_id, item.owner;

CREATE OR REPLACE VIEW api.project_agent_workers AS
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
    WHERE item.execution_state = 'running'
      AND item.assignee_worker_id = worker.id
      AND COALESCE(item.claim_heartbeat_at, item.claim_started_at, item.updated_at)
        > now() - make_interval(mins => project.claim_idle_timeout_minutes)
  )::integer AS active_claims
FROM api.agent_workers worker
JOIN api.projects project ON project.id = worker.project_id
LEFT JOIN api.work_items item ON item.assignee_worker_id = worker.id
GROUP BY worker.id;

REVOKE ALL ON api.agent_work_sessions FROM PUBLIC, web_anon;
GRANT SELECT ON api.agent_work_sessions TO web_anon;
GRANT SELECT ON api.project_agent_metrics, api.project_summary, api.project_owner_summary, api.project_agent_workers TO web_anon;
GRANT EXECUTE ON FUNCTION api.report_work_session_usage(uuid, uuid, text, bigint, bigint, numeric, text, text) TO web_anon;
REVOKE ALL ON FUNCTION api.track_agent_work_session() FROM PUBLIC, web_anon;

NOTIFY pgrst, 'reload schema';

COMMIT;
