ALTER TABLE api.project_artifacts
  ADD COLUMN IF NOT EXISTS content text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS metadata jsonb NOT NULL DEFAULT '{}'::jsonb;

CREATE INDEX IF NOT EXISTS project_artifacts_type_idx
  ON api.project_artifacts(project_id, artifact_type, updated_at DESC);

DROP TRIGGER IF EXISTS project_artifacts_updated_at ON api.project_artifacts;
CREATE TRIGGER project_artifacts_updated_at
  BEFORE UPDATE ON api.project_artifacts
  FOR EACH ROW EXECUTE FUNCTION api.set_updated_at();

CREATE OR REPLACE FUNCTION api.seed_project_records() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO api.project_artifacts(
    project_id, artifact_key, artifact_type, title, description, content, created_by
  ) VALUES
    (NEW.id, 'project-brief', 'brief', 'Project brief',
      'AI summary of the supplied project brief, its purpose, audience and intended outcomes.',
      NEW.description, 'Agent Boards'),
    (NEW.id, 'prd', 'prd', 'Product requirements document',
      'Goals, users, requirements and accepted outcomes for the project.',
      '', 'Product agent'),
    (NEW.id, 'architecture', 'architecture', 'Architecture document',
      'System shape, components, data contracts and integration boundaries.',
      '', 'Architecture agent'),
    (NEW.id, 'risk-register', 'risk_register', 'Risk register',
      'Threats to delivery currently tracked by people and agents.',
      E'| ID | Risk | Likelihood | Impact | Mitigation | Owner | Status |\n| --- | --- | --- | --- | --- | --- | --- |', 'Delivery agent'),
    (NEW.id, 'issue-register', 'issue_register', 'Issue register',
      'Open problems awaiting resolution or human authority.',
      E'| ID | Issue | Priority | Owner | Status | Resolution |\n| --- | --- | --- | --- | --- | --- |', 'Delivery agent')
  ON CONFLICT (project_id, artifact_key) DO NOTHING;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS projects_seed_project_records ON api.projects;
CREATE TRIGGER projects_seed_project_records
  AFTER INSERT ON api.projects
  FOR EACH ROW EXECUTE FUNCTION api.seed_project_records();

INSERT INTO api.project_artifacts(
  project_id, artifact_key, artifact_type, title, description, content, created_by
)
SELECT
  project.id,
  definition.artifact_key,
  definition.artifact_type,
  definition.title,
  definition.description,
  CASE WHEN definition.artifact_key = 'project-brief' THEN project.description ELSE '' END,
  definition.created_by
FROM api.projects project
CROSS JOIN (VALUES
  ('project-brief', 'brief', 'Project brief',
    'AI summary of the supplied project brief, its purpose, audience and intended outcomes.', 'Agent Boards'),
  ('prd', 'prd', 'Product requirements document',
    'Goals, users, requirements and accepted outcomes for the project.', 'Product agent'),
  ('architecture', 'architecture', 'Architecture document',
    'System shape, components, data contracts and integration boundaries.', 'Architecture agent'),
  ('risk-register', 'risk_register', 'Risk register',
    'Threats to delivery currently tracked by people and agents.', 'Delivery agent'),
  ('issue-register', 'issue_register', 'Issue register',
    'Open problems awaiting resolution or human authority.', 'Delivery agent')
) AS definition(artifact_key, artifact_type, title, description, created_by)
ON CONFLICT (project_id, artifact_key) DO UPDATE SET
  artifact_type = EXCLUDED.artifact_type,
  title = EXCLUDED.title,
  description = EXCLUDED.description,
  content = CASE
    WHEN api.project_artifacts.content = '' THEN EXCLUDED.content
    ELSE api.project_artifacts.content
  END,
  created_by = EXCLUDED.created_by;

CREATE OR REPLACE FUNCTION api.upsert_project_artifact(
  target_project_id uuid,
  target_artifact_key text,
  target_artifact_type text,
  artifact_title text,
  artifact_description text DEFAULT '',
  artifact_content text DEFAULT '',
  artifact_status text DEFAULT 'current',
  actor_name text DEFAULT 'AI agent',
  artifact_metadata jsonb DEFAULT '{}'::jsonb
) RETURNS SETOF api.project_artifacts
LANGUAGE plpgsql AS $$
DECLARE record api.project_artifacts;
BEGIN
  IF artifact_status NOT IN ('draft', 'current', 'superseded') THEN
    RAISE EXCEPTION 'Invalid project record status: %', artifact_status USING ERRCODE = '23514';
  END IF;

  INSERT INTO api.project_artifacts(
    project_id, artifact_key, artifact_type, title, description, content,
    status, version, created_by, metadata
  ) VALUES (
    target_project_id, target_artifact_key, target_artifact_type, artifact_title,
    artifact_description, artifact_content, artifact_status, 1, actor_name,
    artifact_metadata
  )
  ON CONFLICT (project_id, artifact_key) DO UPDATE SET
    artifact_type = EXCLUDED.artifact_type,
    title = EXCLUDED.title,
    description = EXCLUDED.description,
    content = EXCLUDED.content,
    status = EXCLUDED.status,
    version = api.project_artifacts.version + 1,
    created_by = EXCLUDED.created_by,
    metadata = EXCLUDED.metadata
  RETURNING * INTO record;

  INSERT INTO api.activity_events(
    project_id, event_type, actor_type, actor_name, summary, details
  ) VALUES (
    target_project_id,
    'project_artifact.updated',
    CASE WHEN actor_name = 'You' THEN 'human' ELSE 'agent' END,
    actor_name,
    'Updated project record ''' || artifact_title || '''',
    jsonb_build_object('artifact_id', record.id, 'artifact_key', record.artifact_key, 'version', record.version)
  );

  RETURN NEXT record;
END $$;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.project_artifacts TO web_anon;
GRANT EXECUTE ON FUNCTION api.upsert_project_artifact(uuid, text, text, text, text, text, text, text, jsonb) TO web_anon;
NOTIFY pgrst, 'reload schema';
