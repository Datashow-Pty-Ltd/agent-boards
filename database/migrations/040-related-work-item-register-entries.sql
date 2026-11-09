CREATE TABLE IF NOT EXISTS api.work_item_register_entries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id uuid NOT NULL REFERENCES api.projects(id) ON DELETE CASCADE,
  work_item_id uuid NOT NULL REFERENCES api.work_items(id) ON DELETE CASCADE,
  entry_type text NOT NULL CHECK (entry_type IN ('decision','issue','risk')),
  title text NOT NULL CHECK (length(trim(title)) > 0),
  description text NOT NULL DEFAULT '',
  status text NOT NULL DEFAULT 'open' CHECK (length(trim(status)) > 0),
  owner text,
  created_by text NOT NULL DEFAULT 'Agent Boards',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS work_item_register_entries_item_idx
  ON api.work_item_register_entries(work_item_id, entry_type, created_at);

DROP TRIGGER IF EXISTS work_item_register_entries_updated_at ON api.work_item_register_entries;
CREATE TRIGGER work_item_register_entries_updated_at
  BEFORE UPDATE ON api.work_item_register_entries
  FOR EACH ROW EXECUTE FUNCTION api.set_updated_at();

CREATE OR REPLACE FUNCTION api.upsert_work_item_register_entry(
  target_work_item_id uuid,
  target_entry_type text,
  entry_title text,
  entry_description text DEFAULT '',
  entry_status text DEFAULT 'open',
  entry_owner text DEFAULT NULL,
  actor_name text DEFAULT 'AI agent',
  target_entry_id uuid DEFAULT NULL
) RETURNS SETOF api.work_item_register_entries
LANGUAGE plpgsql AS $$
DECLARE
  item api.work_items;
  register_entry api.work_item_register_entries;
BEGIN
  SELECT * INTO item FROM api.work_items WHERE id = target_work_item_id;
  IF item.id IS NULL THEN RAISE EXCEPTION 'Work item not found' USING ERRCODE = 'P0002'; END IF;
  IF item.kind NOT IN ('feature', 'story') THEN
    RAISE EXCEPTION 'Decisions, issues and risks can only be linked to a feature or story.' USING ERRCODE = '23514';
  END IF;
  IF target_entry_type NOT IN ('decision', 'issue', 'risk') THEN
    RAISE EXCEPTION 'Register entry type must be decision, issue or risk.' USING ERRCODE = '23514';
  END IF;
  IF length(trim(entry_title)) = 0 OR length(trim(entry_status)) = 0 THEN
    RAISE EXCEPTION 'Register entry title and status are required.' USING ERRCODE = '23514';
  END IF;

  IF target_entry_id IS NULL THEN
    INSERT INTO api.work_item_register_entries(
      project_id, work_item_id, entry_type, title, description, status, owner, created_by
    ) VALUES (
      item.project_id, item.id, target_entry_type, trim(entry_title), entry_description,
      trim(entry_status), NULLIF(trim(entry_owner), ''), actor_name
    ) RETURNING * INTO register_entry;
  ELSE
    UPDATE api.work_item_register_entries SET
      entry_type = target_entry_type,
      title = trim(entry_title),
      description = entry_description,
      status = trim(entry_status),
      owner = NULLIF(trim(entry_owner), ''),
      created_by = actor_name
    WHERE id = target_entry_id AND work_item_id = item.id
    RETURNING * INTO register_entry;
    IF register_entry.id IS NULL THEN
      RAISE EXCEPTION 'Related register entry not found' USING ERRCODE = 'P0002';
    END IF;
  END IF;

  INSERT INTO api.activity_events(
    project_id, work_item_id, event_type, actor_type, actor_name, summary, details
  ) VALUES (
    item.project_id, item.id, 'work_item.register_entry_recorded',
    CASE WHEN actor_name = 'You' THEN 'human' ELSE 'agent' END,
    actor_name,
    CASE WHEN target_entry_id IS NULL THEN 'Recorded ' ELSE 'Updated ' END || target_entry_type || ' ''' || register_entry.title || '''',
    jsonb_build_object('entry_id', register_entry.id, 'entry_type', register_entry.entry_type, 'status', register_entry.status)
  );

  RETURN NEXT register_entry;
END $$;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.work_item_register_entries TO web_anon;
GRANT EXECUTE ON FUNCTION api.upsert_work_item_register_entry(uuid, text, text, text, text, text, text, uuid) TO web_anon;

NOTIFY pgrst, 'reload schema';
