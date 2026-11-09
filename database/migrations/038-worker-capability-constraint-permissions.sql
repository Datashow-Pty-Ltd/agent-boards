-- Keep the normalizer private while allowing ordinary API writes to satisfy
-- capability constraints without requiring EXECUTE on a PostgREST-visible RPC.

BEGIN;

ALTER TABLE api.agent_workers
  DROP CONSTRAINT IF EXISTS agent_workers_capabilities_valid;
ALTER TABLE api.agent_workers
  ADD CONSTRAINT agent_workers_capabilities_valid
  CHECK (
    jsonb_typeof(capabilities) = 'array'
    AND capabilities <@ '["code_execution", "git", "browser_automation", "screenshot_capture", "screen_recording", "image_generation", "visual_comparison"]'::jsonb
  );

ALTER TABLE api.work_items
  DROP CONSTRAINT IF EXISTS work_items_required_worker_capabilities_valid;
ALTER TABLE api.work_items
  ADD CONSTRAINT work_items_required_worker_capabilities_valid
  CHECK (
    jsonb_typeof(required_worker_capabilities) = 'array'
    AND required_worker_capabilities <@ '["code_execution", "git", "browser_automation", "screenshot_capture", "screen_recording", "image_generation", "visual_comparison"]'::jsonb
  );

ALTER FUNCTION api.set_work_item_required_capabilities(uuid, jsonb, text) SECURITY DEFINER;
ALTER FUNCTION api.set_work_item_required_capabilities(uuid, jsonb, text) SET search_path = api, public;
ALTER FUNCTION api.authorize_idle_claim_takeover(uuid, uuid, text) SECURITY DEFINER;
ALTER FUNCTION api.authorize_idle_claim_takeover(uuid, uuid, text) SET search_path = api, public;

NOTIFY pgrst, 'reload schema';

COMMIT;
