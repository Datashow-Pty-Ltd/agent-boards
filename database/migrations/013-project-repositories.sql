-- A repository shown on a project is a durable association, not display text.
-- The same record is exposed through PostgREST and MCP for people and agents.

CREATE TABLE IF NOT EXISTS api.project_repositories (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id uuid NOT NULL UNIQUE REFERENCES api.projects(id) ON DELETE CASCADE,
  provider text NOT NULL CHECK (provider IN ('github', 'gitlab', 'bitbucket', 'other')),
  repository_url text NOT NULL,
  full_name text NOT NULL,
  default_branch text NOT NULL DEFAULT 'main',
  created_by text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (repository_url ~* '^https://[^/]+/[^/]+/[^/]+(?:\.git)?/?$'),
  CHECK (btrim(full_name) <> ''),
  CHECK (btrim(default_branch) <> '')
);

DROP TRIGGER IF EXISTS project_repositories_updated_at ON api.project_repositories;
CREATE TRIGGER project_repositories_updated_at
  BEFORE UPDATE ON api.project_repositories
  FOR EACH ROW EXECUTE FUNCTION api.set_updated_at();

CREATE OR REPLACE FUNCTION api.set_project_repository(
  target_project_id uuid,
  target_repository_url text,
  target_default_branch text DEFAULT 'main',
  actor_name text DEFAULT 'You'
) RETURNS SETOF api.project_repositories
LANGUAGE plpgsql AS $$
DECLARE
  normalized_url text;
  repository_name text;
  repository_host text;
  repository_provider text;
  repository_record api.project_repositories;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM api.projects WHERE id = target_project_id) THEN
    RAISE EXCEPTION 'Project not found.' USING ERRCODE = '23503';
  END IF;

  normalized_url := regexp_replace(btrim(COALESCE(target_repository_url, '')), '/+$', '');
  normalized_url := regexp_replace(normalized_url, '\.git$', '', 'i');
  IF normalized_url !~* '^https://[^/]+/[^/]+/[^/]+$' THEN
    RAISE EXCEPTION 'Repository URL must be an HTTPS URL containing an owner and repository.'
      USING ERRCODE = '23514';
  END IF;
  IF btrim(COALESCE(target_default_branch, '')) = '' THEN
    RAISE EXCEPTION 'Default branch is required.' USING ERRCODE = '23514';
  END IF;

  repository_host := lower(substring(normalized_url FROM '^https://([^/]+)'));
  repository_name := regexp_replace(normalized_url, '^https://[^/]+/', '', 'i');
  repository_provider := CASE repository_host
    WHEN 'github.com' THEN 'github'
    WHEN 'gitlab.com' THEN 'gitlab'
    WHEN 'bitbucket.org' THEN 'bitbucket'
    ELSE 'other'
  END;

  INSERT INTO api.project_repositories(
    project_id, provider, repository_url, full_name, default_branch, created_by
  ) VALUES (
    target_project_id, repository_provider, normalized_url, repository_name,
    btrim(target_default_branch), actor_name
  )
  ON CONFLICT (project_id) DO UPDATE SET
    provider = EXCLUDED.provider,
    repository_url = EXCLUDED.repository_url,
    full_name = EXCLUDED.full_name,
    default_branch = EXCLUDED.default_branch,
    created_by = EXCLUDED.created_by
  RETURNING * INTO repository_record;

  INSERT INTO api.activity_events(
    project_id, event_type, actor_type, actor_name, summary, details
  ) VALUES (
    target_project_id,
    'project.repository_linked',
    CASE WHEN actor_name = 'You' THEN 'human' ELSE 'agent' END,
    actor_name,
    'Linked source repository ' || repository_record.full_name,
    jsonb_build_object(
      'repository_id', repository_record.id,
      'provider', repository_record.provider,
      'repository_url', repository_record.repository_url,
      'default_branch', repository_record.default_branch
    )
  );

  RETURN NEXT repository_record;
END $$;

CREATE OR REPLACE FUNCTION api.remove_project_repository(
  target_project_id uuid,
  actor_name text DEFAULT 'You'
) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE repository_name text;
BEGIN
  DELETE FROM api.project_repositories
  WHERE project_id = target_project_id
  RETURNING full_name INTO repository_name;

  IF repository_name IS NOT NULL THEN
    INSERT INTO api.activity_events(
      project_id, event_type, actor_type, actor_name, summary
    ) VALUES (
      target_project_id,
      'project.repository_unlinked',
      CASE WHEN actor_name = 'You' THEN 'human' ELSE 'agent' END,
      actor_name,
      'Unlinked source repository ' || repository_name
    );
  END IF;
END $$;

CREATE OR REPLACE FUNCTION api.create_project_with_repository(
  project_name text,
  project_key text,
  project_description text,
  project_owner text,
  repository_url text,
  repository_default_branch text DEFAULT 'main',
  actor_name text DEFAULT 'You'
) RETURNS SETOF api.projects
LANGUAGE plpgsql AS $$
DECLARE project_record api.projects;
BEGIN
  SELECT * INTO project_record
  FROM api.create_project(project_name, project_key, project_description, project_owner);

  PERFORM api.set_project_repository(
    project_record.id,
    repository_url,
    repository_default_branch,
    actor_name
  );

  RETURN NEXT project_record;
END $$;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.project_repositories TO web_anon;
GRANT EXECUTE ON FUNCTION api.set_project_repository(uuid, text, text, text) TO web_anon;
GRANT EXECUTE ON FUNCTION api.remove_project_repository(uuid, text) TO web_anon;
GRANT EXECUTE ON FUNCTION api.create_project_with_repository(text, text, text, text, text, text, text) TO web_anon;
