-- Media attached from the Agent Boards web UI or MCP server is stored by the
-- application and addressed through its internal /uploads route.

ALTER TABLE api.work_item_assets
  DROP CONSTRAINT IF EXISTS work_item_assets_source_url_check,
  DROP CONSTRAINT IF EXISTS work_item_assets_thumbnail_url_check;

ALTER TABLE api.work_item_assets
  ADD CONSTRAINT work_item_assets_source_url_check CHECK (
    source_url ~ '^https?://' OR source_url ~ '^data:(image|video)/' OR source_url ~ '^/uploads/[A-Za-z0-9._-]+$'
  ),
  ADD CONSTRAINT work_item_assets_thumbnail_url_check CHECK (
    thumbnail_url IS NULL OR thumbnail_url ~ '^https?://' OR thumbnail_url ~ '^data:image/' OR thumbnail_url ~ '^/uploads/[A-Za-z0-9._-]+$'
  );
