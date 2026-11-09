CREATE EXTENSION IF NOT EXISTS pgcrypto;

DO $$ BEGIN
  CREATE ROLE web_anon NOLOGIN;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
DO $$ BEGIN
  CREATE ROLE authenticator LOGIN PASSWORD 'postgrest' NOINHERIT;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
GRANT web_anon TO authenticator;

CREATE SCHEMA IF NOT EXISTS api;
GRANT USAGE ON SCHEMA api TO web_anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA api GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO web_anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA api GRANT USAGE, SELECT ON SEQUENCES TO web_anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA api GRANT EXECUTE ON FUNCTIONS TO web_anon;

CREATE OR REPLACE FUNCTION api.set_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$ BEGIN NEW.updated_at = now(); RETURN NEW; END $$;

CREATE TABLE IF NOT EXISTS api.projects (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_key text NOT NULL UNIQUE CHECK (project_key ~ '^[A-Z][A-Z0-9-]{1,11}$'),
  name text NOT NULL,
  description text NOT NULL DEFAULT '',
  owner text NOT NULL DEFAULT 'Unassigned',
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('draft','active','paused','completed','archived')),
  start_date date NOT NULL DEFAULT current_date,
  target_date date,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS api.boards (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id uuid NOT NULL UNIQUE REFERENCES api.projects(id) ON DELETE CASCADE,
  name text NOT NULL,
  description text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS api.board_stages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  board_id uuid NOT NULL REFERENCES api.boards(id) ON DELETE CASCADE,
  slug text NOT NULL,
  title text NOT NULL,
  position integer NOT NULL,
  purpose text NOT NULL DEFAULT '',
  responsible_actor text NOT NULL DEFAULT 'Team',
  wip_limit integer,
  entry_criteria jsonb NOT NULL DEFAULT '[]'::jsonb,
  exit_criteria jsonb NOT NULL DEFAULT '[]'::jsonb,
  allowed_transitions jsonb NOT NULL DEFAULT '[]'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(board_id, slug),
  UNIQUE(board_id, position)
);

CREATE TABLE IF NOT EXISTS api.work_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id uuid NOT NULL REFERENCES api.projects(id) ON DELETE CASCADE,
  board_id uuid NOT NULL REFERENCES api.boards(id) ON DELETE CASCADE,
  parent_id uuid REFERENCES api.work_items(id) ON DELETE SET NULL,
  stage_id uuid NOT NULL REFERENCES api.board_stages(id) ON DELETE RESTRICT,
  item_key text NOT NULL UNIQUE,
  kind text NOT NULL DEFAULT 'story' CHECK (kind IN ('feature','story','task')),
  title text NOT NULL,
  description text NOT NULL DEFAULT '',
  acceptance_criteria jsonb NOT NULL DEFAULT '[]'::jsonb,
  checklist jsonb NOT NULL DEFAULT '[]'::jsonb,
  priority text NOT NULL DEFAULT 'medium' CHECK (priority IN ('urgent','high','medium','low')),
  progress text NOT NULL DEFAULT 'not_started' CHECK (progress IN ('not_started','in_progress','completed')),
  execution_state text CHECK (execution_state IS NULL OR execution_state IN ('queued','running','waiting_for_human','blocked','failed','complete','cancelled')),
  blocked_reason text,
  assignee text,
  due_date date,
  start_date date,
  estimate_points integer NOT NULL DEFAULT 1 CHECK (estimate_points BETWEEN 1 AND 100),
  labels jsonb NOT NULL DEFAULT '[]'::jsonb,
  position integer NOT NULL DEFAULT 0,
  completed_at timestamptz,
  archived_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS api.work_item_dependencies (
  work_item_id uuid NOT NULL REFERENCES api.work_items(id) ON DELETE CASCADE,
  depends_on_work_item_id uuid NOT NULL REFERENCES api.work_items(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (work_item_id, depends_on_work_item_id),
  CHECK (work_item_id <> depends_on_work_item_id)
);

CREATE TABLE IF NOT EXISTS api.work_item_comments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  work_item_id uuid NOT NULL REFERENCES api.work_items(id) ON DELETE CASCADE,
  actor_type text NOT NULL DEFAULT 'human' CHECK (actor_type IN ('human','agent','system')),
  actor_name text NOT NULL,
  body text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS api.activity_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id uuid NOT NULL REFERENCES api.projects(id) ON DELETE CASCADE,
  work_item_id uuid REFERENCES api.work_items(id) ON DELETE CASCADE,
  event_type text NOT NULL,
  actor_type text NOT NULL DEFAULT 'system' CHECK (actor_type IN ('human','agent','system')),
  actor_name text NOT NULL,
  summary text NOT NULL,
  details jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS api.telemetry_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id uuid NOT NULL REFERENCES api.projects(id) ON DELETE CASCADE,
  work_item_id uuid REFERENCES api.work_items(id) ON DELETE SET NULL,
  agent_name text NOT NULL,
  provider text,
  model text,
  status text NOT NULL CHECK (status IN ('running','completed','failed','cancelled')),
  duration_ms bigint NOT NULL DEFAULT 0 CHECK (duration_ms >= 0),
  input_tokens bigint NOT NULL DEFAULT 0 CHECK (input_tokens >= 0),
  output_tokens bigint NOT NULL DEFAULT 0 CHECK (output_tokens >= 0),
  estimated_cost_usd numeric(14,6) NOT NULL DEFAULT 0 CHECK (estimated_cost_usd >= 0),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS work_items_board_stage_idx ON api.work_items(board_id, stage_id, position);
CREATE INDEX IF NOT EXISTS work_items_project_idx ON api.work_items(project_id, updated_at DESC);
CREATE INDEX IF NOT EXISTS activity_project_idx ON api.activity_events(project_id, created_at DESC);
CREATE INDEX IF NOT EXISTS telemetry_project_idx ON api.telemetry_events(project_id, created_at DESC);

DROP TRIGGER IF EXISTS projects_updated_at ON api.projects;
CREATE TRIGGER projects_updated_at BEFORE UPDATE ON api.projects FOR EACH ROW EXECUTE FUNCTION api.set_updated_at();
DROP TRIGGER IF EXISTS boards_updated_at ON api.boards;
CREATE TRIGGER boards_updated_at BEFORE UPDATE ON api.boards FOR EACH ROW EXECUTE FUNCTION api.set_updated_at();
DROP TRIGGER IF EXISTS stages_updated_at ON api.board_stages;
CREATE TRIGGER stages_updated_at BEFORE UPDATE ON api.board_stages FOR EACH ROW EXECUTE FUNCTION api.set_updated_at();
DROP TRIGGER IF EXISTS work_items_updated_at ON api.work_items;
CREATE TRIGGER work_items_updated_at BEFORE UPDATE ON api.work_items FOR EACH ROW EXECUTE FUNCTION api.set_updated_at();

CREATE OR REPLACE FUNCTION api.allocate_item_key(target_project_id uuid) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE project_prefix text; next_number integer;
BEGIN
  SELECT project_key INTO project_prefix FROM api.projects WHERE id = target_project_id;
  IF project_prefix IS NULL THEN RAISE EXCEPTION 'Project not found'; END IF;
  SELECT COALESCE(MAX(NULLIF(regexp_replace(item_key, '^.*-', ''), '')::integer), 0) + 1
    INTO next_number FROM api.work_items WHERE project_id = target_project_id;
  RETURN project_prefix || '-' || next_number;
END $$;

CREATE OR REPLACE FUNCTION api.create_project(
  project_name text,
  project_key text,
  project_description text DEFAULT '',
  project_owner text DEFAULT 'Unassigned'
) RETURNS SETOF api.projects
LANGUAGE plpgsql AS $$
DECLARE p api.projects; b api.boards;
BEGIN
  INSERT INTO api.projects(name, project_key, description, owner)
  VALUES (project_name, upper(project_key), project_description, project_owner) RETURNING * INTO p;
  INSERT INTO api.boards(project_id, name, description)
  VALUES (p.id, 'Delivery board', 'Backlog → Analyse → Plan → Build → Validate → Review → Merge → Post-merge verification → Done') RETURNING * INTO b;
  INSERT INTO api.board_stages(board_id, slug, title, position, purpose, responsible_actor, wip_limit, entry_criteria, exit_criteria, allowed_transitions) VALUES
    (b.id, 'backlog', 'Backlog', 0, 'Keep ordered product work ready for refinement.', 'Product owner', null, '["Desired outcome recorded"]', '["Priority and outcome are clear"]', '["analyse"]'),
    (b.id, 'analyse', 'Analyse', 1, 'Understand context, constraints, risks and alternatives.', 'Analysis agent', 4, '["Work is authorized"]', '["Acceptance criteria are measurable","Dependencies are known"]', '["backlog","plan"]'),
    (b.id, 'plan', 'Plan', 2, 'Define a bounded implementation and verification strategy.', 'Planning agent', 4, '["Analysis is complete"]', '["Implementation and test approach are clear"]', '["analyse","build"]'),
    (b.id, 'build', 'Build', 3, 'Implement the change in an isolated workspace.', 'Delivery agent', 5, '["Plan is ready"]', '["Implementation is complete","Local checks pass"]', '["plan","validate"]'),
    (b.id, 'validate', 'Validate', 4, 'Independently verify the exact implementation revision.', 'Validation agent', 3, '["Build is complete"]', '["Every deterministic acceptance criterion passes for the same revision"]', '["build","review"]'),
    (b.id, 'review', 'Review', 5, 'Review the exact validated revision and resolve every review finding.', 'Reviewer', 3, '["Validation passed for an exact revision"]', '["The validated revision is approved","No review findings remain unresolved"]', '["validate","merge"]'),
    (b.id, 'merge', 'Merge', 6, 'Integrate the exact approved revision into the target branch.', 'Maintainer', 2, '["The validated revision is approved in review"]', '["The approved revision is merged successfully"]', '["review","post_merge"]'),
    (b.id, 'post_merge', 'Post-merge verification', 7, 'Verify the merged revision on the target branch.', 'Validation agent', 3, '["The approved revision is merged"]', '["Target-branch checks pass or have an explicit waiver"]', '["merge","done"]'),
    (b.id, 'done', 'Done', 8, 'Show increments whose accepted, reviewed, merged and verified revisions reconcile.', 'Product team', null, '["Post-merge verification passed"]', '[]', '[]');
  INSERT INTO api.activity_events(project_id, event_type, actor_type, actor_name, summary)
  VALUES (p.id, 'project.created', 'system', 'Agent Boards', 'Project and delivery board created');
  RETURN NEXT p;
END $$;

CREATE OR REPLACE FUNCTION api.create_backlog_item(
  target_project_id uuid,
  item_title text,
  item_description text DEFAULT '',
  item_kind text DEFAULT 'story',
  item_priority text DEFAULT 'medium',
  parent_work_item_id uuid DEFAULT NULL,
  item_assignee text DEFAULT NULL,
  item_acceptance_criteria jsonb DEFAULT '[]'::jsonb,
  actor_name text DEFAULT 'You'
) RETURNS SETOF api.work_items
LANGUAGE plpgsql AS $$
DECLARE item api.work_items; target_board uuid; backlog_stage uuid;
BEGIN
  SELECT id INTO target_board FROM api.boards WHERE project_id = target_project_id;
  SELECT id INTO backlog_stage FROM api.board_stages WHERE board_id = target_board AND slug = 'backlog';
  INSERT INTO api.work_items(project_id, board_id, parent_id, stage_id, item_key, kind, title, description, priority, assignee, acceptance_criteria, position)
  VALUES (target_project_id, target_board, parent_work_item_id, backlog_stage, api.allocate_item_key(target_project_id), item_kind, item_title, item_description, item_priority, item_assignee, item_acceptance_criteria,
    COALESCE((SELECT max(position) + 1 FROM api.work_items WHERE stage_id = backlog_stage), 0)) RETURNING * INTO item;
  INSERT INTO api.activity_events(project_id, work_item_id, event_type, actor_type, actor_name, summary, details)
  VALUES (target_project_id, item.id, 'work_item.created', CASE WHEN actor_name = 'You' THEN 'human' ELSE 'agent' END, actor_name, 'Created ' || item.item_key || ' in Backlog', jsonb_build_object('kind', item.kind));
  RETURN NEXT item;
END $$;

CREATE OR REPLACE FUNCTION api.move_work_item(
  target_work_item_id uuid,
  target_stage_slug text,
  actor_name text DEFAULT 'You',
  event_summary text DEFAULT NULL
) RETURNS SETOF api.work_items
LANGUAGE plpgsql AS $$
DECLARE item api.work_items; target_stage api.board_stages; previous_stage text;
BEGIN
  SELECT * INTO item FROM api.work_items WHERE id = target_work_item_id FOR UPDATE;
  IF item.id IS NULL THEN RAISE EXCEPTION 'Work item not found'; END IF;
  SELECT slug INTO previous_stage FROM api.board_stages WHERE id = item.stage_id;
  SELECT * INTO target_stage FROM api.board_stages WHERE board_id = item.board_id AND slug = target_stage_slug;
  IF target_stage.id IS NULL THEN RAISE EXCEPTION 'Stage not found'; END IF;
  UPDATE api.work_items SET
    stage_id = target_stage.id,
    position = COALESCE((SELECT max(position) + 1 FROM api.work_items WHERE stage_id = target_stage.id AND id <> item.id), 0),
    progress = CASE WHEN target_stage.slug = 'done' THEN 'completed' WHEN target_stage.slug = 'backlog' THEN 'not_started' ELSE 'in_progress' END,
    execution_state = CASE WHEN target_stage.slug = 'done' THEN 'complete' ELSE execution_state END,
    completed_at = CASE WHEN target_stage.slug = 'done' THEN now() ELSE NULL END
  WHERE id = item.id RETURNING * INTO item;
  INSERT INTO api.activity_events(project_id, work_item_id, event_type, actor_type, actor_name, summary, details)
  VALUES (item.project_id, item.id, 'work_item.moved', CASE WHEN actor_name = 'You' THEN 'human' ELSE 'agent' END, actor_name,
    COALESCE(event_summary, 'Moved ' || item.item_key || ' from ' || previous_stage || ' to ' || target_stage.slug),
    jsonb_build_object('from', previous_stage, 'to', target_stage.slug));
  RETURN NEXT item;
END $$;

-- Stage order is a database invariant, not a UI convention. This trigger also
-- protects direct PostgREST updates, so people and agents cannot bypass the
-- governed path by patching stage_id instead of calling move_work_item.
CREATE OR REPLACE FUNCTION api.enforce_work_item_stage_transition() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  previous_stage api.board_stages;
  next_stage api.board_stages;
BEGIN
  IF NEW.stage_id = OLD.stage_id THEN RETURN NEW; END IF;
  SELECT * INTO previous_stage FROM api.board_stages WHERE id = OLD.stage_id;
  SELECT * INTO next_stage FROM api.board_stages WHERE id = NEW.stage_id;
  IF next_stage.id IS NULL OR next_stage.board_id <> OLD.board_id THEN
    RAISE EXCEPTION 'Target stage does not belong to this board.' USING ERRCODE = '23514';
  END IF;
  IF NOT (previous_stage.allowed_transitions ? next_stage.slug) THEN
    RAISE EXCEPTION 'Cannot move from % to %. Allowed next stages: %',
      previous_stage.title,
      next_stage.title,
      COALESCE((SELECT string_agg(value, ', ') FROM jsonb_array_elements_text(previous_stage.allowed_transitions)), 'none')
      USING ERRCODE = '23514',
            HINT = 'Move the card through each governed stage; completed work in Done is terminal.';
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS enforce_work_item_stage_transition ON api.work_items;
CREATE TRIGGER enforce_work_item_stage_transition
  BEFORE UPDATE OF stage_id ON api.work_items
  FOR EACH ROW EXECUTE FUNCTION api.enforce_work_item_stage_transition();

CREATE OR REPLACE VIEW api.project_summary AS
SELECT p.id AS project_id, p.project_key, p.name, p.description, p.owner, p.status, p.start_date, p.target_date,
  count(w.id) FILTER (WHERE w.archived_at IS NULL) AS total_items,
  count(w.id) FILTER (WHERE w.completed_at IS NOT NULL AND w.archived_at IS NULL) AS completed_items,
  count(w.id) FILTER (WHERE w.execution_state = 'running' AND w.archived_at IS NULL) AS running_items,
  count(w.id) FILTER (WHERE w.execution_state IN ('blocked','failed','waiting_for_human') AND w.archived_at IS NULL) AS blocked_items,
  COALESCE(sum(w.estimate_points) FILTER (WHERE w.archived_at IS NULL), 0) AS total_points,
  COALESCE(sum(w.estimate_points) FILTER (WHERE w.completed_at IS NOT NULL AND w.archived_at IS NULL), 0) AS completed_points,
  COALESCE((SELECT sum(t.input_tokens + t.output_tokens) FROM api.telemetry_events t WHERE t.project_id = p.id), 0) AS tokens,
  COALESCE((SELECT sum(t.estimated_cost_usd) FROM api.telemetry_events t WHERE t.project_id = p.id), 0) AS estimated_cost_usd,
  p.updated_at
FROM api.projects p LEFT JOIN api.work_items w ON w.project_id = p.id
GROUP BY p.id;

CREATE OR REPLACE VIEW api.burnup_daily AS
WITH days AS (
  SELECT p.id AS project_id, generate_series(p.start_date::timestamptz, greatest(current_date, coalesce(p.target_date, current_date))::timestamptz, interval '1 day')::date AS day
  FROM api.projects p
)
SELECT d.project_id, d.day,
  COALESCE((SELECT sum(w.estimate_points) FROM api.work_items w WHERE w.project_id = d.project_id AND w.created_at::date <= d.day AND w.archived_at IS NULL), 0) AS scope_points,
  COALESCE((SELECT sum(w.estimate_points) FROM api.work_items w WHERE w.project_id = d.project_id AND w.completed_at::date <= d.day AND w.archived_at IS NULL), 0) AS completed_points
FROM days d;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA api TO web_anon;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA api TO web_anon;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA api TO web_anon;

DO $$
DECLARE p api.projects; b uuid; feature uuid; build_stage uuid; analyse_stage uuid; plan_stage uuid; validate_stage uuid; done_stage uuid;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM api.projects WHERE project_key = 'AB') THEN
    SELECT * INTO p FROM api.create_project('Agent Boards', 'AB', 'A shared delivery system for people and AI agents.', 'Product team');
    UPDATE api.projects SET target_date = current_date + 21 WHERE id = p.id;
    SELECT id INTO b FROM api.boards WHERE project_id = p.id;
    SELECT id INTO analyse_stage FROM api.board_stages WHERE board_id = b AND slug = 'analyse';
    SELECT id INTO plan_stage FROM api.board_stages WHERE board_id = b AND slug = 'plan';
    SELECT id INTO build_stage FROM api.board_stages WHERE board_id = b AND slug = 'build';
    SELECT id INTO validate_stage FROM api.board_stages WHERE board_id = b AND slug = 'validate';
    SELECT id INTO done_stage FROM api.board_stages WHERE board_id = b AND slug = 'done';
    INSERT INTO api.work_items(project_id, board_id, stage_id, item_key, kind, title, description, priority, estimate_points, labels, position)
      VALUES (p.id, b, build_stage, 'AB-1', 'feature', 'Shared project delivery board', 'Give humans and agents one visible source of truth for delivery.', 'urgent', 13, '["foundation"]', 0) RETURNING id INTO feature;
    INSERT INTO api.work_items(project_id, board_id, parent_id, stage_id, item_key, kind, title, description, priority, execution_state, assignee, estimate_points, acceptance_criteria, position) VALUES
      (p.id, b, feature, done_stage, 'AB-2', 'story', 'Define the board ontology', 'Model projects, stages, features, stories, tasks, activity and telemetry.', 'high', 'complete', 'Architecture agent', 3, '["Schema supports feature/story/task hierarchy","Board stages are governed records"]', 0),
      (p.id, b, feature, build_stage, 'AB-3', 'story', 'Build the visual kanban board', 'Present the delivery hierarchy with drag and drop.', 'urgent', 'running', 'UI agent', 5, '["Cards can be moved between stages","Board remains usable on a narrow screen"]', 0),
      (p.id, b, feature, validate_stage, 'AB-4', 'story', 'Expose agent tools over MCP', 'Let agents create, inspect, update and complete work.', 'high', 'running', 'Platform agent', 3, '["MCP tools operate on the same records as the UI"]', 0),
      (p.id, b, feature, plan_stage, 'AB-5', 'story', 'Add burn-up and telemetry views', 'Show scope, completion, agent usage and delivery health.', 'medium', 'queued', 'Data agent', 2, '["Burn-up reflects point-in-time scope and completion"]', 0),
      (p.id, b, feature, analyse_stage, 'AB-6', 'story', 'Design human and agent permissions', 'Define authentication, tenancy and scoped agent access.', 'medium', NULL, NULL, 3, '["Access model covers humans, service agents and project-scoped tokens"]', 0);
    UPDATE api.work_items SET progress = 'completed', completed_at = now() - interval '2 days' WHERE item_key = 'AB-2';
    INSERT INTO api.telemetry_events(project_id, work_item_id, agent_name, provider, model, status, duration_ms, input_tokens, output_tokens, estimated_cost_usd)
    SELECT p.id, id, 'Architecture agent', 'openai', 'gpt-5', 'completed', 842000, 18240, 6140, 0.78 FROM api.work_items WHERE item_key = 'AB-2';
    INSERT INTO api.telemetry_events(project_id, work_item_id, agent_name, provider, model, status, duration_ms, input_tokens, output_tokens, estimated_cost_usd)
    SELECT p.id, id, 'UI agent', 'openai', 'gpt-5', 'running', 415000, 12800, 4380, 0.51 FROM api.work_items WHERE item_key = 'AB-3';
    INSERT INTO api.activity_events(project_id, work_item_id, event_type, actor_type, actor_name, summary)
    SELECT p.id, id, 'work_item.completed', 'agent', 'Architecture agent', 'Completed AB-2 with schema evidence' FROM api.work_items WHERE item_key = 'AB-2';
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';
