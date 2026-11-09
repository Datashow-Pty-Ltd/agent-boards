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

DO $$
DECLARE sample_project_id uuid;
BEGIN
  SELECT id INTO sample_project_id FROM api.projects WHERE project_key = 'AB' LIMIT 1;
  IF sample_project_id IS NULL THEN RETURN; END IF;

  INSERT INTO api.project_artifacts(project_id, artifact_key, artifact_type, title, description, version, created_by)
  VALUES
    (sample_project_id, 'project-brief', 'brief', 'Project brief', 'Purpose, users and intended outcomes for Agent Boards.', 2, 'Product team'),
    (sample_project_id, 'board-ontology', 'architecture', 'Board ontology', 'Feature, story and task hierarchy with governed dependencies.', 3, 'Architecture agent'),
    (sample_project_id, 'delivery-workflow', 'workflow', 'Delivery workflow', 'Backlog through Done stage policy and transition responsibilities.', 2, 'Planning agent'),
    (sample_project_id, 'visual-design', 'design', 'Visual design', 'Responsive board, backlog and project command-page guidance.', 4, 'UI agent'),
    (sample_project_id, 'api-contract', 'api', 'API and MCP contract', 'Shared PostgREST and MCP operations over the durable delivery record.', 2, 'Platform agent'),
    (sample_project_id, 'validation-evidence', 'evidence', 'Validation evidence', 'Build, browser and interaction evidence retained for review.', 1, 'Validation agent')
  ON CONFLICT (project_id, artifact_key) DO UPDATE SET
    title = EXCLUDED.title,
    description = EXCLUDED.description,
    version = EXCLUDED.version,
    created_by = EXCLUDED.created_by,
    updated_at = now();

  UPDATE api.work_items
  SET execution_state = 'waiting_for_human',
      blocked_reason = 'Confirm the access model for humans, service agents and project-scoped tokens.',
      assignee = 'Product owner'
  WHERE project_id = sample_project_id
    AND item_key = 'AB-6'
    AND progress <> 'completed';
END $$;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.project_artifacts TO web_anon;
NOTIFY pgrst, 'reload schema';
