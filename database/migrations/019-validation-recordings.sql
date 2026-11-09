-- Validation recordings are durable proof media linked to the exact revision
-- and, when available, the delivery evidence record they demonstrate.

ALTER TABLE api.work_item_assets
  DROP CONSTRAINT IF EXISTS work_item_assets_asset_type_check,
  DROP CONSTRAINT IF EXISTS work_item_assets_source_url_check,
  DROP CONSTRAINT IF EXISTS work_item_assets_thumbnail_url_check,
  DROP CONSTRAINT IF EXISTS work_item_assets_mime_type_check;

ALTER TABLE api.work_item_assets
  ADD CONSTRAINT work_item_assets_asset_type_check CHECK (asset_type IN (
    'reference', 'mockup', 'wireframe', 'implementation_screenshot',
    'visual_validation', 'visual_diff', 'validation_recording'
  )),
  ADD CONSTRAINT work_item_assets_source_url_check CHECK (
    source_url ~ '^https?://' OR source_url ~ '^data:(image|video)/' OR source_url ~ '^/uploads/[A-Za-z0-9._-]+$'
  ),
  ADD CONSTRAINT work_item_assets_thumbnail_url_check CHECK (
    thumbnail_url IS NULL OR thumbnail_url ~ '^https?://' OR thumbnail_url ~ '^data:image/' OR thumbnail_url ~ '^/uploads/[A-Za-z0-9._-]+$'
  ),
  ADD CONSTRAINT work_item_assets_mime_type_check CHECK (mime_type ~ '^(image|video)/');

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
  IF target_asset_type NOT IN ('reference','mockup','wireframe','implementation_screenshot','visual_validation','visual_diff','validation_recording') THEN
    RAISE EXCEPTION 'Unsupported work-item asset type: %', target_asset_type USING ERRCODE = '23514';
  END IF;
  IF target_asset_type IN ('implementation_screenshot','visual_validation','visual_diff','validation_recording')
     AND btrim(COALESCE(target_revision, '')) = '' THEN
    RAISE EXCEPTION '% requires an exact revision.', target_asset_type USING ERRCODE = '23514';
  END IF;
  IF target_asset_type = 'validation_recording' AND asset_mime_type !~ '^video/' THEN
    RAISE EXCEPTION 'Validation recordings require a video MIME type.' USING ERRCODE = '23514';
  END IF;
  IF target_asset_type <> 'validation_recording' AND asset_mime_type !~ '^image/' THEN
    RAISE EXCEPTION 'Visual assets other than validation recordings require an image MIME type.' USING ERRCODE = '23514';
  END IF;
  IF target_evidence_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM api.work_item_evidence evidence
    WHERE evidence.id = target_evidence_id AND evidence.work_item_id = item.id
  ) THEN
    RAISE EXCEPTION 'Evidence must belong to the same work item.' USING ERRCODE = '23514';
  END IF;
  should_be_primary := target_asset_type <> 'validation_recording' AND (
    make_primary OR NOT EXISTS (
      SELECT 1 FROM api.work_item_assets existing
      WHERE existing.work_item_id = item.id AND existing.asset_type <> 'validation_recording'
    )
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
    item.project_id, item.id,
    CASE WHEN target_asset_type = 'validation_recording' THEN 'work_item.validation_recording_attached' ELSE 'work_item.visual_asset_attached' END,
    CASE WHEN actor_name = 'You' THEN 'human' ELSE 'agent' END,
    actor_name, 'Attached ' || replace(target_asset_type, '_', ' ') || ' to ' || item.item_key,
    jsonb_build_object('asset_id', asset.id, 'asset_type', asset.asset_type, 'revision', asset.revision, 'evidence_id', asset.evidence_id)
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
  IF asset.asset_type = 'validation_recording' THEN
    RAISE EXCEPTION 'A validation recording cannot be the board-card image.' USING ERRCODE = '23514';
  END IF;
  SELECT * INTO item FROM api.work_items WHERE id = asset.work_item_id;
  UPDATE api.work_item_assets SET is_primary = false WHERE work_item_id = asset.work_item_id;
  UPDATE api.work_item_assets SET is_primary = true WHERE id = asset.id RETURNING * INTO asset;
  INSERT INTO api.activity_events(project_id, work_item_id, event_type, actor_type, actor_name, summary, details)
  VALUES (asset.project_id, asset.work_item_id, 'work_item.visual_asset_primary',
    CASE WHEN actor_name = 'You' THEN 'human' ELSE 'agent' END, actor_name,
    'Selected the primary visual for ' || item.item_key, jsonb_build_object('asset_id', asset.id));
  RETURN NEXT asset;
END $$;

GRANT EXECUTE ON FUNCTION api.attach_work_item_asset(uuid, text, text, text, text, text, text, text, integer, integer, text, uuid, boolean) TO web_anon;
GRANT EXECUTE ON FUNCTION api.set_primary_work_item_asset(uuid, text) TO web_anon;
