-- Revision-pinned repository intelligence shared by the UI, REST API and MCP.
-- Deterministic syntax facts are stored separately from agent-authored maps.

CREATE TABLE IF NOT EXISTS api.repository_snapshots (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id uuid NOT NULL REFERENCES api.projects(id) ON DELETE CASCADE,
  repository_id uuid NOT NULL REFERENCES api.project_repositories(id) ON DELETE CASCADE,
  requested_revision text,
  commit_sha text NOT NULL CHECK (commit_sha ~ '^[0-9a-f]{40}$'),
  index_version text NOT NULL,
  precision text NOT NULL DEFAULT 'syntax' CHECK (precision IN ('syntax', 'semantic')),
  status text NOT NULL DEFAULT 'building' CHECK (status IN ('building', 'ready', 'failed')),
  languages jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(languages) = 'object'),
  file_count integer NOT NULL DEFAULT 0 CHECK (file_count >= 0),
  symbol_count integer NOT NULL DEFAULT 0 CHECK (symbol_count >= 0),
  edge_count integer NOT NULL DEFAULT 0 CHECK (edge_count >= 0),
  quality_check_count integer NOT NULL DEFAULT 0 CHECK (quality_check_count >= 0),
  parse_error_count integer NOT NULL DEFAULT 0 CHECK (parse_error_count >= 0),
  error_message text,
  indexed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(repository_id, commit_sha, index_version)
);

CREATE TABLE IF NOT EXISTS api.repository_index_jobs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id uuid NOT NULL REFERENCES api.projects(id) ON DELETE CASCADE,
  repository_id uuid NOT NULL REFERENCES api.project_repositories(id) ON DELETE CASCADE,
  requested_revision text,
  resolved_revision text CHECK (resolved_revision IS NULL OR resolved_revision ~ '^[0-9a-f]{40}$'),
  status text NOT NULL DEFAULT 'queued' CHECK (status IN ('queued', 'running', 'succeeded', 'failed')),
  snapshot_id uuid REFERENCES api.repository_snapshots(id) ON DELETE SET NULL,
  actor_name text NOT NULL,
  error_message text,
  started_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS api.repository_files (
  snapshot_id uuid NOT NULL REFERENCES api.repository_snapshots(id) ON DELETE CASCADE,
  path text NOT NULL,
  blob_sha text NOT NULL CHECK (blob_sha ~ '^[0-9a-f]{40}$'),
  language text NOT NULL,
  size_bytes bigint NOT NULL CHECK (size_bytes >= 0),
  line_count integer CHECK (line_count IS NULL OR line_count >= 0),
  is_generated boolean NOT NULL DEFAULT false,
  PRIMARY KEY (snapshot_id, path)
);

CREATE TABLE IF NOT EXISTS api.repository_symbols (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  snapshot_id uuid NOT NULL REFERENCES api.repository_snapshots(id) ON DELETE CASCADE,
  path text NOT NULL,
  name text NOT NULL,
  symbol_kind text NOT NULL,
  start_line integer NOT NULL CHECK (start_line > 0),
  start_column integer NOT NULL CHECK (start_column > 0),
  end_line integer NOT NULL CHECK (end_line > 0),
  end_column integer NOT NULL CHECK (end_column > 0),
  container_name text,
  signature text NOT NULL DEFAULT '',
  is_exported boolean NOT NULL DEFAULT false,
  precision text NOT NULL DEFAULT 'syntax' CHECK (precision IN ('syntax', 'semantic'))
);

CREATE TABLE IF NOT EXISTS api.repository_edges (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  snapshot_id uuid NOT NULL REFERENCES api.repository_snapshots(id) ON DELETE CASCADE,
  source_path text NOT NULL,
  source_symbol_id uuid REFERENCES api.repository_symbols(id) ON DELETE CASCADE,
  edge_kind text NOT NULL CHECK (edge_kind IN ('import', 'export', 'reference', 'call', 'extends', 'implements')),
  target text NOT NULL,
  target_path text,
  confidence text NOT NULL CHECK (confidence IN ('deterministic_syntax', 'compiler_precise', 'inferred'))
);

CREATE TABLE IF NOT EXISTS api.repository_quality_checks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  snapshot_id uuid NOT NULL REFERENCES api.repository_snapshots(id) ON DELETE CASCADE,
  check_key text NOT NULL,
  check_kind text NOT NULL CHECK (check_kind IN ('static_analysis', 'test', 'build', 'security', 'duplication', 'complexity')),
  command text NOT NULL,
  source_path text NOT NULL,
  configuration jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(configuration) = 'object'),
  UNIQUE(snapshot_id, check_key)
);

CREATE TABLE IF NOT EXISTS api.repository_maps (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id uuid NOT NULL REFERENCES api.projects(id) ON DELETE CASCADE,
  snapshot_id uuid NOT NULL REFERENCES api.repository_snapshots(id) ON DELETE CASCADE,
  map_key text NOT NULL CHECK (map_key ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
  map_type text NOT NULL CHECK (map_type IN ('architecture', 'domain', 'dependency', 'quality', 'change_impact')),
  title text NOT NULL,
  content jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(content) = 'object'),
  citations jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(citations) = 'array'),
  created_by text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(project_id, snapshot_id, map_key)
);

CREATE INDEX IF NOT EXISTS repository_snapshots_project_idx
  ON api.repository_snapshots(project_id, indexed_at DESC NULLS LAST, created_at DESC);
CREATE INDEX IF NOT EXISTS repository_index_jobs_status_idx
  ON api.repository_index_jobs(status, created_at);
CREATE INDEX IF NOT EXISTS repository_files_language_idx
  ON api.repository_files(snapshot_id, language, path);
CREATE INDEX IF NOT EXISTS repository_symbols_name_idx
  ON api.repository_symbols(snapshot_id, lower(name));
CREATE INDEX IF NOT EXISTS repository_symbols_path_idx
  ON api.repository_symbols(snapshot_id, path, start_line);
CREATE INDEX IF NOT EXISTS repository_edges_source_idx
  ON api.repository_edges(snapshot_id, source_path);
CREATE INDEX IF NOT EXISTS repository_edges_target_idx
  ON api.repository_edges(snapshot_id, target);

DROP TRIGGER IF EXISTS repository_maps_updated_at ON api.repository_maps;
CREATE TRIGGER repository_maps_updated_at
  BEFORE UPDATE ON api.repository_maps
  FOR EACH ROW EXECUTE FUNCTION api.set_updated_at();

CREATE OR REPLACE FUNCTION api.enqueue_repository_index(
  target_project_id uuid,
  target_revision text DEFAULT NULL,
  actor_name text DEFAULT 'AI agent'
) RETURNS SETOF api.repository_index_jobs
LANGUAGE plpgsql AS $$
DECLARE
  repository_record api.project_repositories;
  existing_job api.repository_index_jobs;
  created_job api.repository_index_jobs;
  normalized_revision text := NULLIF(btrim(COALESCE(target_revision, '')), '');
BEGIN
  SELECT * INTO repository_record
  FROM api.project_repositories
  WHERE project_id = target_project_id;
  IF repository_record.id IS NULL THEN
    RAISE EXCEPTION 'The project does not have a linked repository.' USING ERRCODE = '23514';
  END IF;

  SELECT * INTO existing_job
  FROM api.repository_index_jobs job
  WHERE job.project_id = target_project_id
    AND job.status IN ('queued', 'running')
    AND COALESCE(job.requested_revision, '') = COALESCE(normalized_revision, '')
  ORDER BY job.created_at DESC
  LIMIT 1;
  IF existing_job.id IS NOT NULL THEN
    RETURN NEXT existing_job;
    RETURN;
  END IF;

  INSERT INTO api.repository_index_jobs(
    project_id, repository_id, requested_revision, actor_name
  ) VALUES (
    target_project_id, repository_record.id, normalized_revision, actor_name
  ) RETURNING * INTO created_job;

  INSERT INTO api.activity_events(
    project_id, event_type, actor_type, actor_name, summary, details
  ) VALUES (
    target_project_id,
    'repository.index_requested',
    CASE WHEN actor_name = 'You' THEN 'human' ELSE 'agent' END,
    actor_name,
    'Requested repository intelligence index',
    jsonb_build_object('job_id', created_job.id, 'requested_revision', normalized_revision)
  );

  RETURN NEXT created_job;
END $$;

CREATE OR REPLACE FUNCTION api.upsert_repository_map(
  target_project_id uuid,
  target_snapshot_id uuid,
  target_map_key text,
  target_map_type text,
  map_title text,
  map_content jsonb,
  map_citations jsonb,
  actor_name text DEFAULT 'AI agent'
) RETURNS SETOF api.repository_maps
LANGUAGE plpgsql AS $$
DECLARE
  snapshot_record api.repository_snapshots;
  map_record api.repository_maps;
BEGIN
  SELECT * INTO snapshot_record FROM api.repository_snapshots
  WHERE id = target_snapshot_id AND project_id = target_project_id AND status = 'ready';
  IF snapshot_record.id IS NULL THEN
    RAISE EXCEPTION 'A ready repository snapshot for the project is required.' USING ERRCODE = '23514';
  END IF;
  IF jsonb_typeof(COALESCE(map_content, 'null'::jsonb)) <> 'object' THEN
    RAISE EXCEPTION 'Repository map content must be a JSON object.' USING ERRCODE = '23514';
  END IF;
  IF jsonb_typeof(COALESCE(map_citations, 'null'::jsonb)) <> 'array' THEN
    RAISE EXCEPTION 'Repository map citations must be a JSON array.' USING ERRCODE = '23514';
  END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(map_citations) citation
    WHERE jsonb_typeof(citation) <> 'object'
      OR btrim(COALESCE(citation->>'path', '')) = ''
  ) THEN
    RAISE EXCEPTION 'Every repository map citation requires a source path.' USING ERRCODE = '23514';
  END IF;

  INSERT INTO api.repository_maps(
    project_id, snapshot_id, map_key, map_type, title, content, citations, created_by
  ) VALUES (
    target_project_id, target_snapshot_id, target_map_key, target_map_type,
    map_title, map_content, map_citations, actor_name
  ) ON CONFLICT (project_id, snapshot_id, map_key) DO UPDATE SET
    map_type = EXCLUDED.map_type,
    title = EXCLUDED.title,
    content = EXCLUDED.content,
    citations = EXCLUDED.citations,
    created_by = EXCLUDED.created_by
  RETURNING * INTO map_record;

  INSERT INTO api.activity_events(
    project_id, event_type, actor_type, actor_name, summary, details
  ) VALUES (
    target_project_id,
    'repository.map_updated',
    CASE WHEN actor_name = 'You' THEN 'human' ELSE 'agent' END,
    actor_name,
    'Updated repository map ' || map_record.title,
    jsonb_build_object(
      'map_id', map_record.id,
      'map_key', map_record.map_key,
      'map_type', map_record.map_type,
      'snapshot_id', map_record.snapshot_id,
      'commit_sha', snapshot_record.commit_sha,
      'citation_count', jsonb_array_length(map_record.citations)
    )
  );

  RETURN NEXT map_record;
END $$;

COMMENT ON TABLE api.repository_snapshots IS
  'Immutable revision-pinned repository intelligence indexes; precision discloses syntax versus compiler-semantic facts.';
COMMENT ON TABLE api.repository_maps IS
  'Agent-authored repository interpretations tied to an exact snapshot and durable source citations.';

GRANT SELECT, INSERT, UPDATE, DELETE ON api.repository_snapshots TO web_anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON api.repository_index_jobs TO web_anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON api.repository_files TO web_anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON api.repository_symbols TO web_anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON api.repository_edges TO web_anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON api.repository_quality_checks TO web_anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON api.repository_maps TO web_anon;
GRANT EXECUTE ON FUNCTION api.enqueue_repository_index(uuid, text, text) TO web_anon;
GRANT EXECUTE ON FUNCTION api.upsert_repository_map(uuid, uuid, text, text, text, jsonb, jsonb, text) TO web_anon;

NOTIFY pgrst, 'reload schema';
