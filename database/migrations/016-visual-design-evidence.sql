-- Visual work is explicit, durable project evidence rather than an informal
-- link in a comment. UI stories can opt into a governed design/proof path.

ALTER TABLE api.work_items
  ADD COLUMN IF NOT EXISTS visual_evidence_required boolean NOT NULL DEFAULT false;

CREATE TABLE IF NOT EXISTS api.work_item_assets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id uuid NOT NULL REFERENCES api.projects(id) ON DELETE CASCADE,
  work_item_id uuid NOT NULL REFERENCES api.work_items(id) ON DELETE CASCADE,
  evidence_id uuid REFERENCES api.work_item_evidence(id) ON DELETE SET NULL,
  asset_type text NOT NULL CHECK (asset_type IN (
    'reference', 'mockup', 'wireframe', 'implementation_screenshot',
    'visual_validation', 'visual_diff'
  )),
  source_url text NOT NULL,
  thumbnail_url text,
  mime_type text NOT NULL DEFAULT 'image/png',
  filename text,
  caption text NOT NULL DEFAULT '',
  viewport_width integer CHECK (viewport_width IS NULL OR viewport_width > 0),
  viewport_height integer CHECK (viewport_height IS NULL OR viewport_height > 0),
  revision text,
  is_primary boolean NOT NULL DEFAULT false,
  created_by text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (source_url ~ '^https?://' OR source_url ~ '^data:image/'),
  CHECK (thumbnail_url IS NULL OR thumbnail_url ~ '^https?://' OR thumbnail_url ~ '^data:image/'),
  CHECK (mime_type ~ '^image/')
);

CREATE INDEX IF NOT EXISTS work_item_assets_item_idx
  ON api.work_item_assets(work_item_id, created_at DESC);
CREATE INDEX IF NOT EXISTS work_item_assets_project_idx
  ON api.work_item_assets(project_id, created_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS work_item_assets_one_primary_idx
  ON api.work_item_assets(work_item_id) WHERE is_primary;

CREATE OR REPLACE FUNCTION api.set_visual_evidence_requirement(
  target_work_item_id uuid,
  required boolean,
  actor_name text DEFAULT 'You'
) RETURNS SETOF api.work_items
LANGUAGE plpgsql AS $$
DECLARE item api.work_items; stage api.board_stages;
BEGIN
  SELECT * INTO item FROM api.work_items WHERE id = target_work_item_id FOR UPDATE;
  IF item.id IS NULL THEN RAISE EXCEPTION 'Work item not found.'; END IF;
  IF item.kind <> 'story' THEN
    RAISE EXCEPTION 'Visual evidence requirements can only be set on stories.' USING ERRCODE = '23514';
  END IF;
  SELECT * INTO stage FROM api.board_stages WHERE id = item.stage_id;
  IF stage.slug NOT IN ('backlog', 'analyse', 'plan') THEN
    RAISE EXCEPTION 'The visual evidence requirement cannot change after Build begins.' USING ERRCODE = '23514';
  END IF;
  UPDATE api.work_items SET visual_evidence_required = required
  WHERE id = item.id RETURNING * INTO item;
  INSERT INTO api.activity_events(project_id, work_item_id, event_type, actor_type, actor_name, summary, details)
  VALUES (
    item.project_id, item.id, 'work_item.visual_requirement_changed',
    CASE WHEN actor_name = 'You' THEN 'human' ELSE 'agent' END,
    actor_name,
    CASE WHEN required THEN 'Visual design evidence is required for ' ELSE 'Visual design evidence is no longer required for ' END || item.item_key,
    jsonb_build_object('visual_evidence_required', required)
  );
  RETURN NEXT item;
END $$;

CREATE OR REPLACE FUNCTION api.attach_work_item_asset(
  target_work_item_id uuid,
  target_asset_type text,
  asset_source_url text,
  actor_name text,
  asset_caption text DEFAULT '',
  asset_thumbnail_url text DEFAULT NULL,
  asset_mime_type text DEFAULT 'image/png',
  asset_filename text DEFAULT NULL,
  asset_viewport_width integer DEFAULT NULL,
  asset_viewport_height integer DEFAULT NULL,
  target_revision text DEFAULT NULL,
  target_evidence_id uuid DEFAULT NULL,
  make_primary boolean DEFAULT false
) RETURNS SETOF api.work_item_assets
LANGUAGE plpgsql AS $$
DECLARE item api.work_items; asset api.work_item_assets; should_be_primary boolean;
BEGIN
  SELECT * INTO item FROM api.work_items WHERE id = target_work_item_id;
  IF item.id IS NULL THEN RAISE EXCEPTION 'Work item not found.'; END IF;
  IF target_asset_type NOT IN ('reference','mockup','wireframe','implementation_screenshot','visual_validation','visual_diff') THEN
    RAISE EXCEPTION 'Unsupported visual asset type: %', target_asset_type USING ERRCODE = '23514';
  END IF;
  IF target_asset_type IN ('implementation_screenshot','visual_validation','visual_diff')
     AND btrim(COALESCE(target_revision, '')) = '' THEN
    RAISE EXCEPTION '% requires an exact revision.', target_asset_type USING ERRCODE = '23514';
  END IF;
  IF target_evidence_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM api.work_item_evidence evidence
    WHERE evidence.id = target_evidence_id AND evidence.work_item_id = item.id
  ) THEN
    RAISE EXCEPTION 'Evidence must belong to the same work item.' USING ERRCODE = '23514';
  END IF;
  should_be_primary := make_primary OR NOT EXISTS (
    SELECT 1 FROM api.work_item_assets existing WHERE existing.work_item_id = item.id
  );
  IF should_be_primary THEN
    UPDATE api.work_item_assets SET is_primary = false WHERE work_item_id = item.id;
  END IF;
  INSERT INTO api.work_item_assets(
    project_id, work_item_id, evidence_id, asset_type, source_url, thumbnail_url,
    mime_type, filename, caption, viewport_width, viewport_height, revision,
    is_primary, created_by
  ) VALUES (
    item.project_id, item.id, target_evidence_id, target_asset_type, asset_source_url,
    asset_thumbnail_url, asset_mime_type, asset_filename, COALESCE(asset_caption, ''),
    asset_viewport_width, asset_viewport_height, target_revision, should_be_primary, actor_name
  ) RETURNING * INTO asset;
  INSERT INTO api.activity_events(project_id, work_item_id, event_type, actor_type, actor_name, summary, details)
  VALUES (
    item.project_id, item.id, 'work_item.visual_asset_attached',
    CASE WHEN actor_name = 'You' THEN 'human' ELSE 'agent' END,
    actor_name, 'Attached ' || replace(target_asset_type, '_', ' ') || ' to ' || item.item_key,
    jsonb_build_object('asset_id', asset.id, 'asset_type', asset.asset_type, 'revision', asset.revision)
  );
  RETURN NEXT asset;
END $$;

CREATE OR REPLACE FUNCTION api.set_primary_work_item_asset(
  target_asset_id uuid,
  actor_name text DEFAULT 'You'
) RETURNS SETOF api.work_item_assets
LANGUAGE plpgsql AS $$
DECLARE asset api.work_item_assets; item api.work_items;
BEGIN
  SELECT * INTO asset FROM api.work_item_assets WHERE id = target_asset_id FOR UPDATE;
  IF asset.id IS NULL THEN RAISE EXCEPTION 'Visual asset not found.'; END IF;
  SELECT * INTO item FROM api.work_items WHERE id = asset.work_item_id;
  UPDATE api.work_item_assets SET is_primary = false WHERE work_item_id = asset.work_item_id;
  UPDATE api.work_item_assets SET is_primary = true WHERE id = asset.id RETURNING * INTO asset;
  INSERT INTO api.activity_events(project_id, work_item_id, event_type, actor_type, actor_name, summary, details)
  VALUES (asset.project_id, asset.work_item_id, 'work_item.visual_asset_primary',
    CASE WHEN actor_name = 'You' THEN 'human' ELSE 'agent' END, actor_name,
    'Selected the primary visual for ' || item.item_key, jsonb_build_object('asset_id', asset.id));
  RETURN NEXT asset;
END $$;

CREATE OR REPLACE FUNCTION api.delete_work_item_asset(
  target_asset_id uuid,
  actor_name text DEFAULT 'You'
) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE asset api.work_item_assets; item api.work_items;
BEGIN
  SELECT * INTO asset FROM api.work_item_assets WHERE id = target_asset_id FOR UPDATE;
  IF asset.id IS NULL THEN RAISE EXCEPTION 'Visual asset not found.'; END IF;
  SELECT * INTO item FROM api.work_items WHERE id = asset.work_item_id;
  DELETE FROM api.work_item_assets WHERE id = asset.id;
  IF asset.is_primary THEN
    UPDATE api.work_item_assets SET is_primary = true WHERE id = (
      SELECT id FROM api.work_item_assets WHERE work_item_id = asset.work_item_id ORDER BY created_at DESC LIMIT 1
    );
  END IF;
  INSERT INTO api.activity_events(project_id, work_item_id, event_type, actor_type, actor_name, summary, details)
  VALUES (asset.project_id, asset.work_item_id, 'work_item.visual_asset_removed',
    CASE WHEN actor_name = 'You' THEN 'human' ELSE 'agent' END, actor_name,
    'Removed ' || replace(asset.asset_type, '_', ' ') || ' from ' || item.item_key,
    jsonb_build_object('asset_id', asset.id, 'asset_type', asset.asset_type));
END $$;

CREATE OR REPLACE FUNCTION api.enforce_visual_evidence_stage_transition() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE previous_stage api.board_stages; next_stage api.board_stages; implementation_revision text; accepted_revision text;
BEGIN
  IF NEW.stage_id = OLD.stage_id OR OLD.kind <> 'story' OR NOT OLD.visual_evidence_required THEN RETURN NEW; END IF;
  SELECT * INTO previous_stage FROM api.board_stages WHERE id = OLD.stage_id;
  SELECT * INTO next_stage FROM api.board_stages WHERE id = NEW.stage_id;
  IF next_stage.slug = 'build' AND previous_stage.slug = 'plan' AND NOT EXISTS (
    SELECT 1 FROM api.work_item_assets asset WHERE asset.work_item_id = OLD.id AND asset.asset_type IN ('mockup','wireframe')
  ) THEN
    RAISE EXCEPTION 'Visual story cannot enter Build without an attached mockup or wireframe.' USING ERRCODE = '23514';
  END IF;
  IF next_stage.slug = 'validate' THEN
    SELECT evidence.revision INTO implementation_revision FROM api.work_item_evidence evidence
    WHERE evidence.work_item_id = OLD.id AND evidence.evidence_type = 'implementation'
      AND evidence.outcome IN ('recorded','passed') AND evidence.revision IS NOT NULL
    ORDER BY evidence.created_at DESC LIMIT 1;
    IF implementation_revision IS NULL OR NOT EXISTS (
      SELECT 1 FROM api.work_item_assets asset WHERE asset.work_item_id = OLD.id
        AND asset.asset_type = 'implementation_screenshot' AND asset.revision = implementation_revision
    ) THEN
      RAISE EXCEPTION 'Visual story cannot enter Validate without an implementation screenshot for the exact implementation revision.' USING ERRCODE = '23514';
    END IF;
  END IF;
  IF next_stage.slug = 'review' THEN
    SELECT criterion->>'revision' INTO accepted_revision FROM jsonb_array_elements(OLD.acceptance_criteria) criterion LIMIT 1;
    IF accepted_revision IS NULL OR NOT EXISTS (
      SELECT 1 FROM api.work_item_assets asset WHERE asset.work_item_id = OLD.id
        AND asset.asset_type IN ('visual_validation','visual_diff') AND asset.revision = accepted_revision
    ) THEN
      RAISE EXCEPTION 'Visual story cannot enter Review without visual validation for the accepted revision.' USING ERRCODE = '23514';
    END IF;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS enforce_visual_evidence_stage_transition ON api.work_items;
CREATE TRIGGER enforce_visual_evidence_stage_transition
  BEFORE UPDATE OF stage_id ON api.work_items
  FOR EACH ROW EXECUTE FUNCTION api.enforce_visual_evidence_stage_transition();

CREATE OR REPLACE FUNCTION api.get_work_item_context_with_visuals(target_work_item_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  item api.work_items;
  context jsonb;
  assets jsonb;
  requirements jsonb;
  current_stage_slug text;
  implementation_revision text;
  accepted_revision text;
BEGIN
  SELECT * INTO item FROM api.work_items WHERE id = target_work_item_id;
  IF item.id IS NULL THEN RAISE EXCEPTION 'Work item not found.'; END IF;
  context := api.get_work_item_context(target_work_item_id);
  SELECT COALESCE(jsonb_agg(to_jsonb(asset) ORDER BY asset.is_primary DESC, asset.created_at DESC), '[]'::jsonb)
  INTO assets FROM api.work_item_assets asset WHERE asset.work_item_id = item.id;
  context := context || jsonb_build_object('visual_assets', assets);
  IF NOT item.visual_evidence_required THEN RETURN context; END IF;

  current_stage_slug := context #>> '{promotion,current_stage,slug}';
  requirements := COALESCE(context #> '{promotion,acceptance_criteria}', '[]'::jsonb);
  SELECT evidence.revision INTO implementation_revision FROM api.work_item_evidence evidence
  WHERE evidence.work_item_id = item.id AND evidence.evidence_type = 'implementation'
    AND evidence.outcome IN ('recorded','passed') AND evidence.revision IS NOT NULL
  ORDER BY evidence.created_at DESC LIMIT 1;
  IF api.acceptance_criteria_passed_for_one_revision(item.acceptance_criteria) THEN
    SELECT criterion->>'revision' INTO accepted_revision FROM jsonb_array_elements(item.acceptance_criteria) criterion LIMIT 1;
  END IF;

  requirements := requirements || CASE current_stage_slug
    WHEN 'plan' THEN jsonb_build_array(jsonb_build_object(
      'requirement', 'A visual mockup or wireframe is attached before implementation begins',
      'satisfied', EXISTS (SELECT 1 FROM api.work_item_assets asset WHERE asset.work_item_id = item.id AND asset.asset_type IN ('mockup','wireframe')),
      'blocking', true
    ))
    WHEN 'build' THEN jsonb_build_array(jsonb_build_object(
      'requirement', 'An implementation screenshot is attached for the exact revision being validated',
      'satisfied', implementation_revision IS NOT NULL AND EXISTS (
        SELECT 1 FROM api.work_item_assets asset WHERE asset.work_item_id = item.id
          AND asset.asset_type = 'implementation_screenshot' AND asset.revision = implementation_revision
      ),
      'revision', implementation_revision, 'blocking', true
    ))
    WHEN 'validate' THEN jsonb_build_array(jsonb_build_object(
      'requirement', 'Visual validation or a visual diff is attached for the accepted revision',
      'satisfied', accepted_revision IS NOT NULL AND EXISTS (
        SELECT 1 FROM api.work_item_assets asset WHERE asset.work_item_id = item.id
          AND asset.asset_type IN ('visual_validation','visual_diff') AND asset.revision = accepted_revision
      ),
      'revision', accepted_revision, 'blocking', true
    ))
    ELSE '[]'::jsonb
  END;
  context := jsonb_set(context, '{promotion,acceptance_criteria}', requirements, true);
  context := jsonb_set(context, '{promotion,ready}', to_jsonb(NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(requirements) requirement
    WHERE COALESCE((requirement->>'blocking')::boolean, true)
      AND NOT COALESCE((requirement->>'satisfied')::boolean, false)
  )), true);
  RETURN context;
END $$;

CREATE OR REPLACE FUNCTION api.claim_next_work_package(
  target_project_id uuid,
  agent_name text
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE item api.work_items;
BEGIN
  SELECT * INTO item FROM api.claim_next_ready_work_item(target_project_id, agent_name);
  IF item.id IS NULL THEN
    RETURN jsonb_build_object('outcome', 'no_ready_work', 'work_package', NULL);
  END IF;
  RETURN jsonb_build_object('outcome', 'claimed', 'work_package', api.get_work_item_context_with_visuals(item.id));
END $$;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.work_item_assets TO web_anon;
GRANT EXECUTE ON FUNCTION api.set_visual_evidence_requirement(uuid, boolean, text) TO web_anon;
GRANT EXECUTE ON FUNCTION api.attach_work_item_asset(uuid, text, text, text, text, text, text, text, integer, integer, text, uuid, boolean) TO web_anon;
GRANT EXECUTE ON FUNCTION api.set_primary_work_item_asset(uuid, text) TO web_anon;
GRANT EXECUTE ON FUNCTION api.delete_work_item_asset(uuid, text) TO web_anon;
GRANT EXECUTE ON FUNCTION api.get_work_item_context_with_visuals(uuid) TO web_anon;
GRANT EXECUTE ON FUNCTION api.claim_next_work_package(uuid, text) TO web_anon;

NOTIFY pgrst, 'reload schema';
