-- Agents could attach visuals as inline data: URLs, which stored whole images
-- and videos in work_item_assets rows and made every board load download them.
-- Media now lives in the managed uploads volume under a content-addressed name
-- (/uploads/<sha256>.<ext>). PostgreSQL cannot write that volume, so the MCP
-- service decodes existing rows, writes the files, and then calls
-- externalise_inline_work_item_asset_media, which only accepts the URL derived
-- from the row's own bytes. Asset ids, approval and review state, revisions
-- and every other column are left untouched.

CREATE OR REPLACE FUNCTION api.inline_media_upload_url(data_url text) RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  comma integer;
  extension text;
  payload text;
BEGIN
  IF data_url IS NULL OR substr(data_url, 1, 5) <> 'data:' THEN RETURN NULL; END IF;
  comma := strpos(data_url, ',');
  IF comma = 0 THEN RETURN NULL; END IF;
  extension := CASE lower(substr(data_url, 6, comma - 6))
    WHEN 'image/png;base64' THEN 'png'
    WHEN 'image/jpeg;base64' THEN 'jpg'
    WHEN 'image/webp;base64' THEN 'webp'
    WHEN 'video/webm;base64' THEN 'webm'
    WHEN 'video/mp4;base64' THEN 'mp4'
    WHEN 'video/quicktime;base64' THEN 'mov'
  END;
  IF extension IS NULL THEN RETURN NULL; END IF;
  payload := substr(data_url, comma + 1);
  IF payload = '' OR length(payload) % 4 <> 0 OR payload !~ '^[A-Za-z0-9+/]*={0,2}$' THEN RETURN NULL; END IF;
  RETURN '/uploads/' || encode(sha256(decode(payload, 'base64')), 'hex') || '.' || extension;
END $$;

-- expected_* is the upload URL the caller has already written for that field,
-- or NULL to leave the field alone. Re-running after success is a no-op.
CREATE OR REPLACE FUNCTION api.externalise_inline_work_item_asset_media(
  target_asset_id uuid,
  expected_source_url text,
  expected_thumbnail_url text
) RETURNS SETOF api.work_item_assets
LANGUAGE plpgsql AS $$
DECLARE
  asset api.work_item_assets;
  next_source text;
  next_thumbnail text;
BEGIN
  SELECT * INTO asset FROM api.work_item_assets WHERE id = target_asset_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Work item asset % was not found.', target_asset_id USING ERRCODE = 'P0002'; END IF;
  next_source := asset.source_url;
  next_thumbnail := asset.thumbnail_url;

  IF expected_source_url IS NOT NULL AND asset.source_url IS DISTINCT FROM expected_source_url THEN
    IF api.inline_media_upload_url(asset.source_url) IS DISTINCT FROM expected_source_url THEN
      RAISE EXCEPTION 'The source media of asset % does not match %.', target_asset_id, expected_source_url USING ERRCODE = '22023';
    END IF;
    next_source := expected_source_url;
  END IF;
  IF expected_thumbnail_url IS NOT NULL AND asset.thumbnail_url IS DISTINCT FROM expected_thumbnail_url THEN
    IF api.inline_media_upload_url(asset.thumbnail_url) IS DISTINCT FROM expected_thumbnail_url THEN
      RAISE EXCEPTION 'The thumbnail of asset % does not match %.', target_asset_id, expected_thumbnail_url USING ERRCODE = '22023';
    END IF;
    next_thumbnail := expected_thumbnail_url;
  END IF;

  IF next_source IS DISTINCT FROM asset.source_url OR next_thumbnail IS DISTINCT FROM asset.thumbnail_url THEN
    UPDATE api.work_item_assets
    SET source_url = next_source, thumbnail_url = next_thumbnail
    WHERE id = asset.id
    RETURNING * INTO asset;
  END IF;
  RETURN NEXT asset;
END $$;

-- PostgREST computed field for board cards: an image URL that is never an
-- inline data: URL, so the board can render without selecting source_url.
-- substr() lets PostgreSQL read only the start of a large TOASTed value.
CREATE OR REPLACE FUNCTION api.card_image_url(asset api.work_item_assets) RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT CASE
    WHEN asset.thumbnail_url IS NOT NULL AND substr(asset.thumbnail_url, 1, 5) <> 'data:' THEN asset.thumbnail_url
    WHEN substr(asset.source_url, 1, 5) <> 'data:' THEN asset.source_url
  END
$$;

GRANT EXECUTE ON FUNCTION api.inline_media_upload_url(text) TO web_anon;
GRANT EXECUTE ON FUNCTION api.externalise_inline_work_item_asset_media(uuid, text, text) TO web_anon;
GRANT EXECUTE ON FUNCTION api.card_image_url(api.work_item_assets) TO web_anon;
