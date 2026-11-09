CREATE TABLE IF NOT EXISTS api.project_artifacts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id uuid NOT NULL REFERENCES api.projects(id) ON DELETE CASCADE,
  artifact_key text NOT NULL,
  artifact_type text NOT NULL,
  title text NOT NULL,
  description text NOT NULL DEFAULT '',
  status text NOT NULL DEFAULT 'current' CHECK (status IN ('draft', 'current', 'superseded')),
  version integer NOT NULL DEFAULT 1 CHECK (version > 0),
  created_by text NOT NULL DEFAULT 'Agent Boards',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (project_id, artifact_key)
);

CREATE INDEX IF NOT EXISTS project_artifacts_project_idx
  ON api.project_artifacts(project_id, updated_at DESC);

GRANT SELECT, INSERT, UPDATE, DELETE ON api.project_artifacts TO web_anon;
NOTIFY pgrst, 'reload schema';
