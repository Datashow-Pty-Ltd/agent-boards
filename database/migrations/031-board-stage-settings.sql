ALTER TABLE api.board_stages
  ADD COLUMN IF NOT EXISTS bucket_key text,
  ADD COLUMN IF NOT EXISTS bucket_title text;

UPDATE api.board_stages
SET
  bucket_key = CASE
    WHEN slug = 'backlog' THEN 'backlog'
    WHEN slug IN ('analyse', 'plan') THEN 'define'
    WHEN slug IN ('build', 'validate') THEN 'deliver'
    WHEN slug IN ('review', 'merge', 'post_merge') THEN 'integrate'
    WHEN slug = 'done' THEN 'done'
    ELSE 'other'
  END,
  bucket_title = CASE
    WHEN slug = 'backlog' THEN 'Backlog'
    WHEN slug IN ('analyse', 'plan') THEN 'Define'
    WHEN slug IN ('build', 'validate') THEN 'Deliver'
    WHEN slug IN ('review', 'merge', 'post_merge') THEN 'Integrate'
    WHEN slug = 'done' THEN 'Done'
    ELSE 'Other'
  END
WHERE bucket_key IS NULL OR bucket_title IS NULL;

CREATE OR REPLACE FUNCTION api.set_default_stage_bucket() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.bucket_key IS NULL OR btrim(NEW.bucket_key) = '' THEN
    NEW.bucket_key := CASE
      WHEN NEW.slug = 'backlog' THEN 'backlog'
      WHEN NEW.slug IN ('analyse', 'plan') THEN 'define'
      WHEN NEW.slug IN ('build', 'validate') THEN 'deliver'
      WHEN NEW.slug IN ('review', 'merge', 'post_merge') THEN 'integrate'
      WHEN NEW.slug = 'done' THEN 'done'
      ELSE 'other'
    END;
  END IF;
  IF NEW.bucket_title IS NULL OR btrim(NEW.bucket_title) = '' THEN
    NEW.bucket_title := initcap(replace(NEW.bucket_key, '_', ' '));
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS set_default_stage_bucket ON api.board_stages;
CREATE TRIGGER set_default_stage_bucket
  BEFORE INSERT ON api.board_stages
  FOR EACH ROW EXECUTE FUNCTION api.set_default_stage_bucket();

ALTER TABLE api.board_stages
  ALTER COLUMN bucket_key SET NOT NULL,
  ALTER COLUMN bucket_title SET NOT NULL;

CREATE OR REPLACE FUNCTION api.update_board_stage_settings(
  target_stage_id uuid,
  stage_bucket_title text,
  stage_purpose text,
  stage_responsible_actor text,
  stage_wip_limit integer,
  stage_exit_criteria jsonb,
  actor_name text DEFAULT 'You'
) RETURNS SETOF api.board_stages
LANGUAGE plpgsql AS $$
DECLARE
  stage_record api.board_stages;
  target_project api.projects;
  normalized_bucket_key text;
BEGIN
  SELECT stage.* INTO stage_record
  FROM api.board_stages stage
  WHERE stage.id = target_stage_id
  FOR UPDATE;
  IF stage_record.id IS NULL THEN
    RAISE EXCEPTION 'Board stage not found.' USING ERRCODE = 'P0002';
  END IF;

  SELECT project.* INTO target_project
  FROM api.projects project
  JOIN api.boards board ON board.project_id = project.id
  WHERE board.id = stage_record.board_id;
  IF target_project.status = 'archived' THEN
    RAISE EXCEPTION 'Archived project settings are read-only.' USING ERRCODE = '23514';
  END IF;

  IF btrim(COALESCE(stage_bucket_title, '')) = '' OR length(stage_bucket_title) > 60 THEN
    RAISE EXCEPTION 'Bucket title must contain 1 to 60 characters.' USING ERRCODE = '23514';
  END IF;
  IF length(COALESCE(stage_purpose, '')) > 1000 THEN
    RAISE EXCEPTION 'Stage purpose cannot exceed 1000 characters.' USING ERRCODE = '23514';
  END IF;
  IF btrim(COALESCE(stage_responsible_actor, '')) = '' OR length(stage_responsible_actor) > 120 THEN
    RAISE EXCEPTION 'Responsible actor must contain 1 to 120 characters.' USING ERRCODE = '23514';
  END IF;
  IF stage_wip_limit IS NOT NULL AND (stage_wip_limit < 1 OR stage_wip_limit > 100) THEN
    RAISE EXCEPTION 'WIP limit must be between 1 and 100, or empty.' USING ERRCODE = '23514';
  END IF;
  IF jsonb_typeof(stage_exit_criteria) <> 'array' OR jsonb_array_length(stage_exit_criteria) > 30 THEN
    RAISE EXCEPTION 'Exit criteria must be an array containing at most 30 entries.' USING ERRCODE = '23514';
  END IF;
  IF stage_record.slug <> 'done' AND jsonb_array_length(stage_exit_criteria) = 0 THEN
    RAISE EXCEPTION 'Every active workflow stage must retain at least one exit criterion.' USING ERRCODE = '23514';
  END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(stage_exit_criteria) criterion
    WHERE jsonb_typeof(criterion) <> 'string'
      OR btrim(criterion #>> '{}') = ''
      OR length(criterion #>> '{}') > 500
  ) THEN
    RAISE EXCEPTION 'Each exit criterion must contain 1 to 500 characters.' USING ERRCODE = '23514';
  END IF;

  normalized_bucket_key := trim(both '-' FROM regexp_replace(lower(stage_bucket_title), '[^a-z0-9]+', '-', 'g'));
  IF normalized_bucket_key = '' THEN
    RAISE EXCEPTION 'Bucket title must contain a letter or number.' USING ERRCODE = '23514';
  END IF;

  UPDATE api.board_stages SET
    bucket_key = normalized_bucket_key,
    bucket_title = btrim(stage_bucket_title),
    purpose = btrim(COALESCE(stage_purpose, '')),
    responsible_actor = btrim(stage_responsible_actor),
    wip_limit = stage_wip_limit,
    exit_criteria = stage_exit_criteria
  WHERE id = stage_record.id
  RETURNING * INTO stage_record;

  INSERT INTO api.activity_events(project_id, event_type, actor_type, actor_name, summary, details)
  VALUES (
    target_project.id,
    'board.stage_settings_updated',
    CASE WHEN actor_name = 'You' THEN 'human' ELSE 'agent' END,
    actor_name,
    'Updated workflow settings for ' || stage_record.title,
    jsonb_build_object(
      'stage_id', stage_record.id,
      'stage_slug', stage_record.slug,
      'bucket_key', stage_record.bucket_key,
      'bucket_title', stage_record.bucket_title,
      'wip_limit', stage_record.wip_limit,
      'exit_criteria', stage_record.exit_criteria
    )
  );

  RETURN NEXT stage_record;
END $$;

GRANT EXECUTE ON FUNCTION api.update_board_stage_settings(uuid, text, text, text, integer, jsonb, text) TO web_anon;

NOTIFY pgrst, 'reload schema';
